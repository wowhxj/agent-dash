#!/usr/bin/env python3
"""Codex native session backup. All operations require explicit paths and IDs."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import zipfile

from agent_dash_backup_paths import absolute_source, codex_destination

LIMIT = 8 * 1024 * 1024 * 1024
TOTAL = 64 * 1024 * 1024 * 1024
LINE_LIMIT = 64 * 1024 * 1024
MANIFEST_LIMIT = 64 * 1024 * 1024
TABLES = ('thread_dynamic_tools', 'thread_attachments', 'thread_read_receipts', 'guardian_review_feedback')
UUID = r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
ID = re.compile(UUID)
FORK_ROLLOUT = re.compile(r'(?P<base>rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-(?P<sid>' + UUID + r'))_' + UUID + r'\.jsonl')


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def pack(row):
    return {k: {'$blob': base64.b64encode(v).decode()} if isinstance(v, bytes) else v for k, v in dict(row).items()}


def unpack(row):
    return {k: base64.b64decode(v['$blob'], validate=True) if isinstance(v, dict) and set(v) == {'$blob'} else v for k, v in row.items()}


def connection(home, readonly=True):
    db = home / 'state_5.sqlite'
    if not db.is_file() or db.is_symlink():
        raise ValueError('Codex state_5.sqlite 不存在或是符号链接')
    con = sqlite3.connect(db.as_uri() + ('?mode=ro' if readonly else '?mode=rw'), uri=True, timeout=3)
    con.row_factory = sqlite3.Row
    con.execute('PRAGMA foreign_keys=ON')
    return con


def tables(con):
    return {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}


def safe_path(home, relative):
    if not isinstance(relative, str) or '\\' in relative:
        raise ValueError('无效 rollout 路径')
    p = PurePosixPath(relative)
    if p.is_absolute() or len(p.parts) < 2 or p.parts[0] not in ('sessions', 'archived_sessions') or any(x in ('.', '..') for x in p.parts) or not (relative.endswith('.jsonl') or relative.endswith('.jsonl.zst')):
        raise ValueError('无效 rollout 路径')
    current = home
    for part in p.parts:
        current = current / part
        if current.is_symlink():
            raise ValueError('rollout 路径含符号链接')
    return current


def relative_path(home, path):
    p = Path(path)
    try:
        relative = p.relative_to(home).as_posix() if p.is_absolute() else p.as_posix()
    except ValueError:
        raise ValueError('rollout 不在 Codex home 下')
    safe_path(home, relative)
    return relative


def import_path(home, relative, sid):
    path = safe_path(home, relative)
    name = path.name.removesuffix('.zst')
    fork = FORK_ROLLOUT.fullmatch(name)
    if fork:
        if fork['sid'] != sid:
            raise ValueError('rollout 文件名与会话 ID 不匹配')
        name = fork['base'] + '.jsonl'
    elif not name.endswith(sid + '.jsonl') or re.findall(UUID, name) != [sid]:
        raise ValueError('rollout 文件名与会话 ID 不匹配')
    return safe_path(home, path.with_name(name).relative_to(home).as_posix())


def fetch(con, sid):
    row = con.execute('SELECT * FROM threads WHERE id=?', (sid,)).fetchone()
    if row is None:
        return None
    result = {'thread': pack(row), 'related': {}, 'references': {}}
    available = tables(con)
    for field, table in (('project_id', 'projects'), ('thread_section_id', 'thread_sections')):
        value = result['thread'].get(field)
        if value and table in available:
            ref = con.execute('SELECT * FROM ' + table + ' WHERE id=?', (value,)).fetchone()
            if ref is None:
                raise ValueError('会话引用的元数据不存在: ' + table)
            result['references'][table] = [pack(ref)]
            if table == 'projects' and 'project_roots' in available:
                result['references']['project_roots'] = [pack(r) for r in con.execute('SELECT * FROM project_roots WHERE project_id=? ORDER BY position', (value,))]
    for table in TABLES:
        if table in available:
            result['related'][table] = [pack(r) for r in con.execute('SELECT * FROM ' + table + ' WHERE thread_id=? ORDER BY rowid', (sid,))]
    return result


def file_hash(path):
    if not path.is_file() or path.is_symlink():
        raise ValueError('rollout 不存在或不是普通文件: ' + str(path))
    h = hashlib.sha256()
    size = 0
    with path.open('rb') as f:
        while chunk := f.read(1024 * 1024):
            size += len(chunk)
            if size > LIMIT:
                raise ValueError('rollout 超过大小限制')
            h.update(chunk)
    return h.hexdigest()


def copy_limited(source, dest, limit=LIMIT):
    h = hashlib.sha256()
    size = 0
    while chunk := source.read(1024 * 1024):
        size += len(chunk)
        if size > limit:
            raise ValueError('rollout 超过大小限制')
        h.update(chunk)
        dest.write(chunk)
    return size, h.hexdigest()


def physical_path(home, relative):
    path = safe_path(home, relative)
    if not path.exists() and relative.endswith('.jsonl'):
        sibling = safe_path(home, relative + '.zst')
        if sibling.exists():
            return sibling
    return path


def stage_rollout(path, dest):
    if not path.is_file() or path.is_symlink() or path.stat().st_size > LIMIT:
        raise ValueError('rollout 不存在或超过大小限制')
    with dest.open('wb') as out:
        if not str(path).endswith('.zst'):
            with path.open('rb') as source:
                return copy_limited(source, out)
        with path.open('rb') as source, tempfile.TemporaryFile() as errors:
            proc = subprocess.Popen(['zstd', '-q', '-d', '-c'], stdin=source, stdout=subprocess.PIPE, stderr=errors)
            try:
                result = copy_limited(proc.stdout, out)
                if proc.wait() != 0:
                    raise ValueError('zstd rollout 解压失败')
                return result
            finally:
                proc.stdout.close()
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()


def do_export(a):
    home = Path(a.home).expanduser().resolve()
    if not a.id or len(set(a.id)) != len(a.id) or any(not ID.fullmatch(x) for x in a.id):
        raise ValueError('需要不重复的 UUID 会话 ID')
    out = Path(a.output).expanduser().absolute()
    if out.exists():
        raise ValueError('输出文件已存在')
    out.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.agent-dash-', dir=out.parent)
    count = 0
    try:
        with tempfile.TemporaryDirectory() as tmp, os.fdopen(fd, 'w+b') as f:
            src = connection(home)
            snap = sqlite3.connect(str(Path(tmp) / 'state.sqlite'))
            try:
                src.backup(snap)
            finally:
                src.close()
            snap.row_factory = sqlite3.Row
            total = 0
            try:
                with zipfile.ZipFile(f, 'w', compression=zipfile.ZIP_STORED, allowZip64=True) as z:
                    manifest = {'format': 'agent-dash-codex', 'version': 1, 'sessions': []}
                    for sid in a.id:
                        row = fetch(snap, sid)
                        if row is None:
                            raise ValueError('未找到会话: ' + sid)
                        rel = relative_path(home, row['thread']['rollout_path'])
                        path = physical_path(home, rel)
                        before = path.stat()
                        staged = Path(tmp) / 'rollout'
                        size, sha = stage_rollout(path, staged)
                        total += size
                        if total > TOTAL:
                            raise ValueError('归档超过大小限制')
                        mapped_rollout(staged, sid, [])
                        rel = import_path(home, rel, sid).relative_to(home).as_posix()
                        after = path.stat()
                        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                            raise ValueError('导出时 rollout 发生变化')
                        member = 'rollouts/' + sid + '.jsonl'
                        manifest['sessions'].append({'id': sid, 'path': rel, 'metadata': row, 'member': member, 'sha256': sha, 'size': size})
                        z.write(staged, member)
                        count += 1
                    manifest_data = canonical(manifest)
                    if len(manifest_data) > MANIFEST_LIMIT:
                        raise ValueError('归档清单超过大小限制')
                    z.writestr('manifest.json', manifest_data)
            finally:
                snap.close()
            f.flush()
            os.fsync(f.fileno())
        os.link(name, out)
    finally:
        os.unlink(name)
    return {'output': str(out), 'count': count}


def archive(path, tmp):
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        names = [i.filename for i in infos]
        if len(infos) > 10001 or len(set(names)) != len(names) or 'manifest.json' not in names:
            raise ValueError('无效归档目录')
        if any(i.is_dir() or i.flag_bits & 1 or i.file_size > LIMIT or i.compress_size == 0 and i.file_size or i.file_size > 1000 * max(i.compress_size, 1) for i in infos) or sum(i.file_size for i in infos) > TOTAL:
            raise ValueError('归档超过安全限制')
        if z.getinfo('manifest.json').file_size > MANIFEST_LIMIT:
            raise ValueError('归档清单超过大小限制')
        manifest = json.loads(z.read('manifest.json'))
        if manifest.get('format') != 'agent-dash-codex' or manifest.get('version') != 1 or not isinstance(manifest.get('sessions'), list):
            raise ValueError('不支持的归档格式')
        result, used = [], {'manifest.json'}
        ids = set()
        for item in manifest['sessions']:
            sid = item['id']
            if not isinstance(sid, str) or not ID.fullmatch(sid) or sid in ids:
                raise ValueError('无效或重复会话 ID')
            ids.add(sid)
            member = 'rollouts/' + sid + '.jsonl'
            if item['member'] != member or member not in names or member in used:
                raise ValueError('无效归档成员')
            used.add(member)
            data = Path(tmp) / sid
            with z.open(member) as source, data.open('wb') as dest:
                size, sha = copy_limited(source, dest)
            if size != item['size'] or sha != item['sha256']:
                raise ValueError('rollout 校验失败')
            meta = item['metadata']
            if meta['thread']['id'] != sid or not isinstance(meta['related'], dict) or set(meta['related']) - set(TABLES) or not isinstance(meta.get('references'), dict) or set(meta['references']) - {'projects', 'project_roots', 'thread_sections'}:
                raise ValueError('元数据无效')
            for table, field in (('projects', 'project_id'), ('thread_sections', 'thread_section_id')):
                rows = meta['references'].get(table, [])
                if not isinstance(rows, list) or len(rows) > 1 or any(r.get('id') != meta['thread'].get(field) for r in rows):
                    raise ValueError('引用元数据无效')
            roots = meta['references'].get('project_roots', [])
            if not isinstance(roots, list) or any(r.get('project_id') != meta['thread'].get('project_id') for r in roots) or (roots and not meta['references'].get('projects')):
                raise ValueError('项目根目录元数据无效')
            for rows in meta['related'].values():
                if not isinstance(rows, list) or any(r.get('thread_id') != sid for r in rows):
                    raise ValueError('关联元数据无效')
            result.append((item, data))
        if used != set(names):
            raise ValueError('归档含未知成员')
        return result


def project_dirs(path):
    with tempfile.TemporaryDirectory() as tmp:
        for item, rollout in archive(path, tmp):
            meta = item['metadata']
            yield meta['thread'].get('cwd')
            for row in meta['references'].get('project_roots', []):
                yield row.get('path')
            directories = set()
            mapped_rollout(rollout, item['id'], [], directories=directories)
            yield from directories


def mapped_rollout(path, sid, mappings, output=None, directories=None):
    def update(settings):
        if directories is not None:
            if isinstance(settings.get('cwd'), str):
                directories.add(settings['cwd'])
            roots = settings.get('runtime_workspace_roots')
            if isinstance(roots, list):
                directories.update(root for root in roots if isinstance(root, str))
        changed = False
        if mappings:
            cwd = settings.get('cwd')
            destination = codex_destination(cwd, mappings)
            if destination != cwd:
                settings['cwd'] = destination
                changed = True
            roots = settings.get('runtime_workspace_roots')
            if isinstance(roots, list):
                destinations = [codex_destination(root, mappings) for root in roots]
                if destinations != roots:
                    settings['runtime_workspace_roots'] = destinations
                    changed = True
        return changed

    h = hashlib.sha256()
    with path.open('rb') as source:
        index = 0
        while True:
            line = source.readline(LINE_LIMIT + 1)
            if not line:
                break
            if len(line) > LINE_LIMIT:
                raise ValueError('rollout 单行超过大小限制')
            if index == 0 or mappings or directories is not None:
                event = json.loads(line)
                if not isinstance(event, dict):
                    raise ValueError('rollout 事件无效')
                payload = event.get('payload')
                if index == 0:
                    if not isinstance(payload, dict) or event.get('type') != 'session_meta' or payload.get('id') != sid:
                        raise ValueError('rollout session_meta 身份不匹配')
                    changed = update(payload)
                else:
                    settings = payload.get('thread_settings', {}) if isinstance(payload, dict) else {}
                    changed = event.get('type') == 'event_msg' and isinstance(payload, dict) and payload.get('type') == 'thread_settings_applied' and isinstance(settings, dict) and update(settings)
                if changed:
                    line = canonical(event) + (b'\n' if line.endswith(b'\n') else b'')
            h.update(line)
            if output is not None:
                output.write(line)
            index += 1
        if not index:
            raise ValueError('空 rollout')
    return h.hexdigest()


def plan(a, con, entries):
    home = Path(a.home).expanduser().resolve()
    active = sorted(set(a.active_id or []))
    mappings = a.map or []
    if any(not ID.fullmatch(x) for x in active) or len({x[0] for x in mappings}) != len(mappings) or any(not absolute_source(old) or not os.path.isabs(new) for old, new in mappings):
        raise ValueError('无效 active-id 或重复映射')
    actions = []
    targets = set()
    available = tables(con)
    for item, data in entries:
        sid = item['id']
        target = import_path(home, item['path'], sid)
        rel = target.relative_to(home).as_posix()
        mapped_hash = mapped_rollout(data, sid, mappings)
        if rel in targets:
            raise ValueError('多个会话使用同一路径')
        targets.add(rel)
        meta = json.loads(json.dumps(item['metadata']))
        thread = meta['thread']
        for table, rows in [('threads', [thread]), *meta['related'].items(), *meta['references'].items()]:
            if table not in available:
                raise ValueError('目标数据库缺少表: ' + table)
            cols = {r[1] for r in con.execute('PRAGMA table_info(' + table + ')')}
            if any(set(row) - cols for row in rows):
                raise ValueError('目标数据库版本缺少字段: ' + table)
        thread['rollout_path'] = str(target)
        if 'cwd' in thread:
            thread['cwd'] = codex_destination(thread['cwd'], mappings)
        for row in meta['references'].get('project_roots', []):
            if 'path' in row:
                row['path'] = codex_destination(row['path'], mappings)
        for table in ('projects', 'thread_sections'):
            refs = meta['references'].get(table, [])
            if refs:
                existing_ref = con.execute('SELECT * FROM ' + table + ' WHERE id=?', (refs[0]['id'],)).fetchone()
                if existing_ref is not None:
                    meta['references'][table] = [pack(existing_ref)]
                    if table == 'projects' and 'project_roots' in available:
                        meta['references']['project_roots'] = [pack(r) for r in con.execute('SELECT * FROM project_roots WHERE project_id=? ORDER BY position', (refs[0]['id'],))]
        old = fetch(con, sid)
        old_path = physical_path(home, relative_path(home, old['thread']['rollout_path'])) if old else target
        for directory in ('sessions', 'archived_sessions'):
            root = home / directory
            if root.is_symlink():
                raise ValueError('rollout 根目录是符号链接')
            if root.exists():
                for pattern in (f'*{sid}.jsonl*', f'*{sid}_*.jsonl*'):
                    for found in root.rglob(pattern):
                        name = found.name.removesuffix('.zst')
                        if not name.endswith('.jsonl'):
                            continue
                        if found not in (target, old_path):
                            raise ValueError('发现同 ID 的额外 rollout，需先人工处理: ' + str(found))
        if old_path != target and old_path.exists() and target.exists():
            raise ValueError('同 ID 同时存在新旧 rollout，需先人工处理: ' + sid)
        old_hash = file_hash(old_path) if old_path.exists() else None
        existing = file_hash(target) if target.exists() else None
        same = old == meta and existing == mapped_hash
        collision = con.execute('SELECT id FROM threads WHERE rollout_path=? AND id<>?', (str(target), sid)).fetchone()
        if collision:
            raise ValueError('rollout 路径属于其他会话')
        if set(meta['related']) - available:
            raise ValueError('目标数据库缺少关联表')
        action = 'skip' if same else 'overwrite' if old or existing is not None else 'create'
        if action != 'skip' and (sid in active or open_check(target) or (old_path != target and open_check(old_path))):
            action = 'busy'
        actions.append({'id': sid, 'action': action, 'path': str(target), 'old_path': str(old_path), 'old': old, 'old_sha256': old_hash, 'target_sha256': existing, 'metadata': meta})
    token = digest(canonical({'home': str(home), 'entries': [{'item': item, 'sha256': item['sha256']} for item, data in entries], 'actions': actions, 'active': active, 'map': mappings}))
    return actions, token


def public_plan(actions, token):
    return {'preview_token': token, 'sessions': [{k: a[k] for k in ('id', 'action', 'path', 'old_path')} for a in actions]}


def open_check(path):
    if not path.exists():
        return False
    proc = subprocess.run(['lsof', '-t', '--', str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode == 0 or proc.stdout:
        return True
    if proc.returncode != 1 or proc.stderr:
        raise ValueError('无法确认 rollout 是否正在使用')
    return False


def insert_row(con, table, row):
    row = unpack(row)
    cols = {r[1] for r in con.execute('PRAGMA table_info(' + table + ')')}
    if set(row) - cols:
        raise ValueError('目标数据库版本缺少字段: ' + table)
    keys = list(row)
    if not keys or any(k not in cols for k in keys):
        raise ValueError('无效字段')
    con.execute('INSERT INTO ' + table + ' (' + ','.join('"' + k.replace('"', '""') + '"' for k in keys) + ') VALUES (' + ','.join('?' for _ in keys) + ')', [row[k] for k in keys])


def do_import(a, entries):
    home = Path(a.home).expanduser().resolve()
    con = connection(home, False)
    snapshot = None
    changed = []
    committed = False
    try:
        con.execute('BEGIN IMMEDIATE')
        actions, token = plan(a, con, entries)
        if token != a.preview_token:
            raise ValueError('预览已失效，请重新预览')
        changes = [x for x in actions if x['action'] not in ('skip', 'busy')]
        for item in changes:
            if open_check(Path(item['path'])) or open_check(Path(item['old_path'])):
                raise ValueError('会话状态已变化，请重新预览: ' + item['id'])
        if not changes:
            con.rollback()
            return {**public_plan(actions, token), 'rollback_path': None, 'rollback_archive_path': None}
        root = home / 'agent-dash-backups'
        if root.is_symlink():
            raise ValueError('快照目录是符号链接')
        root.mkdir(mode=0o700, exist_ok=True)
        for previous in root.glob('import-*'):
            if previous.is_symlink() or (previous.is_dir() and not (previous / 'committed').is_file() and not (previous / 'rolledback').is_file()):
                raise ValueError('存在未完成的回滚快照，请先人工恢复: ' + str(previous))
        snapshot = Path(tempfile.mkdtemp(prefix='import-', dir=root))
        # SQLite backup cannot run from the same connection holding a write transaction.
        src = connection(home)
        dest = sqlite3.connect(str(snapshot / 'state_5.sqlite'))
        try:
            src.backup(dest)
        finally:
            dest.close()
            src.close()
        rollback_archive = None
        old_ids = [item['id'] for item in changes if item['old']]
        if old_ids:
            try:
                rollback_archive = str(snapshot / 'rollback.zip')
                do_export(argparse.Namespace(home=str(home), output=rollback_archive, id=old_ids))
            except (ValueError, OSError, sqlite3.Error):
                rollback_archive = None
        file_paths = list(dict.fromkeys(p for item in changes for p in (item['path'], item['old_path'])))
        journal = {'status': 'prepared', 'files': []}
        for index, name in enumerate(file_paths):
            p = Path(name)
            backup = str(index) + '.jsonl' if p.exists() else None
            if backup:
                with p.open('rb') as source, (snapshot / backup).open('wb') as dest:
                    copy_limited(source, dest)
            journal['files'].append({'path': name, 'backup': backup})
        (snapshot / 'manifest.json').write_bytes(canonical(journal))
        for p in snapshot.iterdir():
            with p.open('rb') as f:
                os.fsync(f.fileno())
        dfd = os.open(snapshot, os.O_RDONLY)
        os.fsync(dfd)
        os.close(dfd)
        dfd = os.open(root, os.O_RDONLY)
        os.fsync(dfd)
        os.close(dfd)
        by_id = {x['id']: data for x, data in entries}
        for item in changes:
            target = Path(item['path'])
            safe_path(home, str(target.relative_to(home)))
            if open_check(target) or open_check(Path(item['old_path'])):
                raise ValueError('会话状态已变化，请重新预览: ' + item['id'])
            target.parent.mkdir(parents=True, exist_ok=True)
            fd, stage = tempfile.mkstemp(prefix='.agent-dash-', dir=target.parent)
            try:
                with os.fdopen(fd, 'wb') as f:
                    mapped_rollout(by_id[item['id']], item['id'], a.map or [], f)
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(stage, target)
                changed.append(str(target))
                old_path = Path(item['old_path'])
                if old_path != target and old_path.exists():
                    if open_check(old_path):
                        raise ValueError('会话状态已变化，请重新预览: ' + item['id'])
                    old_path.unlink()
                    changed.append(str(old_path))
                    old_dfd = os.open(old_path.parent, os.O_RDONLY)
                    os.fsync(old_dfd)
                    os.close(old_dfd)
                target_dfd = os.open(target.parent, os.O_RDONLY)
                os.fsync(target_dfd)
                os.close(target_dfd)
            finally:
                if os.path.exists(stage):
                    os.unlink(stage)
            for table in ('projects', 'thread_sections', 'project_roots'):
                for row in item['metadata']['references'].get(table, []):
                    if table == 'project_roots':
                        exists = con.execute('SELECT 1 FROM project_roots WHERE project_id=? AND position=?', (row['project_id'], row['position'])).fetchone()
                    else:
                        exists = con.execute('SELECT 1 FROM ' + table + ' WHERE id=?', (row['id'],)).fetchone()
                    if not exists:
                        insert_row(con, table, row)
            for table in TABLES:
                if table in tables(con):
                    con.execute('DELETE FROM ' + table + ' WHERE thread_id=?', (item['id'],))
            if item['old']:
                row = unpack(item['metadata']['thread'])
                cols = {r[1] for r in con.execute('PRAGMA table_info(threads)')}
                if set(row) - cols:
                    raise ValueError('目标数据库版本缺少字段: threads')
                keys = [k for k in row if k != 'id']
                con.execute('UPDATE threads SET ' + ','.join('"' + k.replace('"', '""') + '"=?' for k in keys) + ' WHERE id=?', [row[k] for k in keys] + [item['id']])
            else:
                insert_row(con, 'threads', item['metadata']['thread'])
            for table, rows in item['metadata']['related'].items():
                for row in rows:
                    insert_row(con, table, row)
        con.commit()
        committed = True
        (snapshot / 'committed').write_text('committed\n')
        return {**public_plan(actions, token), 'rollback_path': str(snapshot), 'rollback_archive_path': rollback_archive}
    except Exception as error:
        if not committed:
            con.rollback()
            if snapshot:
                try:
                    for name in reversed(changed):
                        entry = next(x for x in journal['files'] if x['path'] == name)
                        target = Path(name)
                        if entry['backup']:
                            fd, staged = tempfile.mkstemp(prefix='.agent-dash-restore-', dir=target.parent)
                            try:
                                with os.fdopen(fd, 'wb') as f:
                                    with (snapshot / entry['backup']).open('rb') as source:
                                        shutil.copyfileobj(source, f, 1024 * 1024)
                                    f.flush()
                                    os.fsync(f.fileno())
                                os.replace(staged, target)
                            finally:
                                if os.path.exists(staged):
                                    os.unlink(staged)
                        elif target.exists():
                            target.unlink()
                    (snapshot / 'rolledback').write_text('rolled back\n')
                except Exception as restore_error:
                    raise ValueError(f'{error}; 自动回滚失败: {restore_error}; 回滚快照: {snapshot}') from error
        if snapshot:
            raise ValueError(str(error) + '; 回滚快照: ' + str(snapshot)) from error
        raise
    finally:
        con.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    exp = commands.add_parser('export')
    exp.add_argument('--home', required=True)
    exp.add_argument('--output', required=True)
    exp.add_argument('--id', action='append', required=True)
    for cmd in ('preview', 'import'):
        p = commands.add_parser(cmd)
        p.add_argument('--home', required=True)
        p.add_argument('--input', required=True)
        p.add_argument('--active-id', action='append', default=[])
        p.add_argument('--map', nargs=2, action='append', default=[])
        if cmd == 'import':
            p.add_argument('--preview-token', required=True)
    a = parser.parse_args()
    if a.command == 'export':
        return do_export(a)
    with tempfile.TemporaryDirectory() as tmp:
        entries = archive(a.input, tmp)
        if a.command == 'import':
            return do_import(a, entries)
        con = connection(Path(a.home).expanduser().resolve())
        try:
            con.execute('BEGIN')
            return public_plan(*plan(a, con, entries))
        finally:
            con.close()


if __name__ == '__main__':
    try:
        print(json.dumps(main(), ensure_ascii=False))
    except (ValueError, KeyError, TypeError, OSError, sqlite3.Error, zipfile.BadZipFile, json.JSONDecodeError) as e:
        print(json.dumps({'error': str(e)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
