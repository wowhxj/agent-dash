#!/usr/bin/env python3
"""Back up Pi JSONL sessions without accessing the Pi profile."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

LIMIT = 256 * 1024 * 1024
TOTAL = 1024 * 1024 * 1024


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe(home, rel):
    if not isinstance(rel, str) or '\\' in rel:
        raise ValueError('无效会话路径')
    p = PurePosixPath(rel)
    if p.is_absolute() or not p.parts or 'agent-dash-backups' in p.parts or any(x in ('.', '..') for x in p.parts) or not rel.endswith('.jsonl') or str(p) != rel:
        raise ValueError('无效会话路径: ' + rel)
    target = home
    for part in p.parts:
        target = target / part
        if target.is_symlink():
            raise ValueError('会话路径含符号链接: ' + str(target))
    return target


def header(line):
    first = json.loads(line)
    if not isinstance(first, dict) or first.get('type') != 'session' or not isinstance(first.get('id'), str) or not first['id'] or not isinstance(first.get('cwd'), str):
        raise ValueError('Pi 会话头无效')
    return first


def session_hash(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > LIMIT:
        raise ValueError('会话路径或大小无效: ' + str(path))
    sha = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            sha.update(chunk)
    return sha.hexdigest()


def stream_session(source, sink, first_line, mapped_line):
    # Keep at most one JSONL record in memory. Preserve all bytes after the header.
    size = len(first_line)
    original = hashlib.sha256(first_line)
    mapped = hashlib.sha256(mapped_line)
    if sink is not None:
        sink.write(mapped_line)
    for line in source:
        size += len(line)
        if size > LIMIT:
            raise ValueError('会话超过大小限制')
        if line.strip() and not isinstance(json.loads(line), dict):
            raise ValueError('Pi 会话记录无效')
        original.update(line)
        mapped.update(line)
        if sink is not None:
            sink.write(line)
    return size, original.hexdigest(), mapped.hexdigest()


def scan(home):
    result = {}
    if not home.exists():
        return result
    if not home.is_dir() or home.is_symlink():
        raise ValueError('Pi sessions 路径无效')
    def onerror(error):
        raise error
    for directory, dirs, files in os.walk(home, onerror=onerror):
        directory = Path(directory)
        dirs[:] = [d for d in dirs if d != 'agent-dash-backups' and not (directory / d).is_symlink()]
        for name in files:
            path = directory / name
            if not name.endswith('.jsonl') or path.is_symlink() or not path.is_file():
                continue
            try:
                with path.open('rb') as stream:
                    sid = header(stream.readline(LIMIT + 1))['id']
            except (ValueError, UnicodeDecodeError):
                continue
            if sid in result:
                raise ValueError('存在重复 Pi 会话 ID: ' + sid)
            result[sid] = path
    return result


def export(a):
    home = Path(a.home).expanduser().resolve()
    if not a.id or len(set(a.id)) != len(a.id):
        raise ValueError('需要不重复的会话 ID')
    found = scan(home)
    chosen = {}
    visiting = set()
    def add(sid):
        if sid in chosen:
            return
        if sid in visiting:
            raise ValueError('parentSession 存在循环')
        if sid not in found:
            raise ValueError('未找到会话: ' + sid)
        visiting.add(sid)
        path = found[sid]
        with path.open('rb') as source:
            first = header(source.readline(LIMIT + 1))
        if first['id'] != sid:
            raise ValueError('读取时会话身份发生变化: ' + str(path))
        parent = first.get('parentSession')
        parent_id = None
        if parent:
            if not isinstance(parent, str):
                raise ValueError('parentSession 无效: ' + sid)
            parent_local = Path(parent)
            resolved_parent = parent_local.resolve() if parent_local.is_absolute() else parent_local
            exact = [k for k, p in found.items() if p in (parent_local, resolved_parent)]
            candidates = exact or [k for k, p in found.items() if p.name == parent.replace('\\', '/').rsplit('/', 1)[-1]]
            if len(candidates) != 1:
                raise ValueError('无法唯一解析 parentSession: ' + parent)
            parent_id = candidates[0]
            add(parent_id)
        visiting.remove(sid)
        chosen[sid] = (path, parent, parent_id)
    for sid in a.id:
        add(sid)
    if sum(v[0].stat().st_size for v in chosen.values()) > TOTAL:
        raise ValueError('归档超过大小限制')
    out = Path(a.output).expanduser().absolute()
    if out.exists():
        raise ValueError('输出文件已存在')
    out.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.agent-dash-', dir=out.parent)
    try:
        with os.fdopen(fd, 'w+b') as f:
            with zipfile.ZipFile(f, 'w', zipfile.ZIP_DEFLATED, compresslevel=1) as z:
                items = []
                for index, (sid, (path, parent_path, parent)) in enumerate(chosen.items()):
                    rel = path.relative_to(home).as_posix()
                    safe(home, rel)
                    member = 'sessions/' + str(index) + '.jsonl'
                    before = path.stat()
                    if before.st_size > LIMIT:
                        raise ValueError('会话超过大小限制')
                    with path.open('rb') as source, z.open(member, 'w') as sink:
                        line = source.readline(LIMIT + 1)
                        first = header(line)
                        if first['id'] != sid or first.get('parentSession') != parent_path:
                            raise ValueError('导出时会话身份发生变化: ' + str(path))
                        size, sha, _ = stream_session(source, sink, line, line)
                    after = path.stat()
                    if before.st_ino != after.st_ino or before.st_mtime_ns != after.st_mtime_ns or size != after.st_size:
                        raise ValueError('导出时会话发生变化: ' + str(path))
                    items.append({'id': sid, 'path': rel, 'parent_id': parent, 'member': member, 'size': size, 'sha256': sha})
                z.writestr('manifest.json', canonical({'format': 'agent-dash-pi', 'version': 1, 'sessions': items}))
                validate_directory(z.infolist())
            f.flush()
            os.fsync(f.fileno())
        os.link(name, out)
    finally:
        os.unlink(name)
    return {'output': str(out), 'count': len(chosen)}


def validate_directory(infos):
    names = {i.filename for i in infos}
    if len(infos) > 10001 or len(names) != len(infos) or 'manifest.json' not in names or any(i.is_dir() or i.flag_bits & 1 or i.file_size > LIMIT or i.file_size > 1000 * max(i.compress_size, 1) for i in infos) or sum(i.file_size for i in infos) > TOTAL:
        raise ValueError('无效或过大的归档')
    return names


def archive(a, stage):
    home = Path(a.home).expanduser().resolve()
    mappings = a.map or []
    if len({x[0] for x in mappings}) != len(mappings) or any(not os.path.isabs(x) or not os.path.isabs(y) for x, y in mappings):
        raise ValueError('无效目录映射')
    with zipfile.ZipFile(a.input) as z:
        names = validate_directory(z.infolist())
        manifest = json.loads(z.read('manifest.json'))
        if manifest.get('format') != 'agent-dash-pi' or manifest.get('version') != 1 or not isinstance(manifest.get('sessions'), list):
            raise ValueError('不支持的归档格式')
        entries, targets, source_paths, used = [], {}, set(), {'manifest.json'}
        for i, item in enumerate(manifest['sessions']):
            sid, member = item['id'], item['member']
            if not isinstance(sid, str) or not sid or sid in targets or member != 'sessions/' + str(i) + '.jsonl' or member not in names:
                raise ValueError('无效会话或归档成员')
            used.add(member)
            target = safe(home, item['path'])
            if target in source_paths:
                raise ValueError('归档含重复会话路径')
            source_paths.add(target)
            with z.open(member) as source:
                first = header(source.readline(LIMIT + 1))
            if first['id'] != sid:
                raise ValueError('会话身份不匹配')
            cwd = mapped_cwd(first['cwd'], mappings)
            if cwd != first['cwd']:
                target = safe(home, (PurePosixPath(encoded(cwd)) / target.name).as_posix())
            targets[sid] = target
        if used != names:
            raise ValueError('归档成员无效')
        groups = {}
        for sid, target in targets.items():
            groups.setdefault(target, []).append(sid)
        reserved = set(groups)
        for target, ids in groups.items():
            if len(ids) == 1:
                continue
            for sid in sorted(ids):
                # Legacy paths may share a basename after their cwd buckets merge.
                # Keep the session ID as the native filename suffix when it is filesystem-safe.
                safe_id = len(sid.encode()) <= 180 and not re.search(r'[\\/\x00-\x1f]', sid)
                key = sid if safe_id else digest(sid.encode())
                stamp = target.stem.split('_', 1)[0]
                if not re.fullmatch(r'[0-9TtZz.:-]{1,40}', stamp):
                    stamp = 'restored'
                candidate = target.with_name(f'{stamp}_{key}.jsonl')
                index = 1
                while candidate in reserved:
                    candidate = target.with_name(f'{stamp}-{index}_{key}.jsonl')
                    index += 1
                reserved.add(candidate)
                targets[sid] = safe(home, candidate.relative_to(home).as_posix())
        by_id = {item['id']: item for item in manifest['sessions']}
        for i, item in enumerate(manifest['sessions']):
            parent = item.get('parent_id')
            seen = set()
            cursor = item['id']
            while cursor is not None:
                if cursor in seen or cursor not in by_id:
                    raise ValueError('parentSession 缺失或存在循环')
                seen.add(cursor)
                cursor = by_id[cursor].get('parent_id')
            payload = Path(stage) / str(i) if stage is not None else None
            with z.open(item['member']) as source:
                line = source.readline(LIMIT + 1)
                first = header(line)
                original = first.get('parentSession')
                if bool(original) != bool(parent) or (parent and (not isinstance(original, str) or original.replace(chr(92), '/').rsplit('/', 1)[-1] != PurePosixPath(by_id[parent]['path']).name)):
                    raise ValueError('parentSession 元数据不匹配')
                cwd = mapped_cwd(first['cwd'], mappings)
                mapped_line = line
                if cwd != first['cwd'] or (parent and original != str(targets[parent])):
                    first['cwd'] = cwd
                    if parent:
                        first['parentSession'] = str(targets[parent])
                    mapped_line = canonical(first) + (b'\n' if line.endswith(b'\n') else b'')
                if payload is None:
                    size, sha, new_sha = stream_session(source, None, line, mapped_line)
                else:
                    with payload.open('xb') as sink:
                        size, sha, new_sha = stream_session(source, sink, line, mapped_line)
            if size != item['size'] or sha != item['sha256']:
                raise ValueError('会话校验失败')
            entries.append((item, targets[item['id']], payload, new_sha))
        return entries


def mapped_cwd(cwd, mappings):
    for old, new in sorted(mappings, key=lambda pair: len(pair[0].rstrip('/')), reverse=True):
        if cwd == old:
            return new
        if cwd.startswith(old.rstrip('/') + '/'):
            return new.rstrip('/') + cwd[len(old.rstrip('/')):]
    return cwd


def encoded(cwd):
    return '--' + re.sub(r'[/\\:]', '-', cwd.lstrip('/\\',)) + '--'


def busy(path):
    if not path.exists():
        return False
    p = subprocess.run(['lsof', '-t', '--', str(path)], capture_output=True)
    if p.returncode == 0 or p.stdout:
        return True
    if p.returncode != 1 or p.stderr:
        raise ValueError('无法确认会话是否正在使用')
    return False


def plan(a, entries):
    home = Path(a.home).expanduser().resolve()
    existing = scan(home)
    actions = []
    targets = {item['id']: target for item, target, _, _ in entries}
    for item, target, payload, new_sha in entries:
        sid = item['id']
        safe(home, target.relative_to(home).as_posix())
        old = existing.get(sid)
        old_path = old or target
        if target.exists() and target != old:
            raise ValueError('目标路径被其他会话或无效文件占用: ' + str(target))
        prior = session_hash(old_path) if old_path.exists() else None
        action = 'skip' if old_path == target and prior == new_sha else 'overwrite' if prior is not None else 'create'
        if action != 'skip' and (sid in (a.active_id or []) or busy(old_path) or (target != old_path and busy(target))):
            action = 'busy'
        actions.append({'id': sid, 'action': action, 'path': str(target), 'old_path': str(old_path), 'old_sha256': prior, 'new_sha256': new_sha, 'data': payload})
    by_id = {x['id']: x for x in actions}
    for item, _, _, _ in entries:
        parent = item.get('parent_id')
        if parent and by_id[parent]['action'] == 'busy' and not targets[parent].exists() and by_id[item['id']]['action'] != 'skip':
            by_id[item['id']]['action'] = 'busy'
    token = digest(canonical({'home': str(home), 'entries': [x[0] for x in entries], 'actions': [{k: v for k, v in x.items() if k != 'data'} for x in actions], 'active': sorted(set(a.active_id or [])), 'map': a.map or []}))
    return actions, token


def public(actions, token):
    return {'preview_token': token, 'sessions': [{k: x[k] for k in ('id', 'action', 'path', 'old_path')} for x in actions]}


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, stage = tempfile.mkstemp(prefix='.agent-dash-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            if isinstance(data, Path):
                with data.open('rb') as source:
                    shutil.copyfileobj(source, f, 1024 * 1024)
            else:
                f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(stage, path)
    finally:
        if os.path.exists(stage):
            os.unlink(stage)


def do_import(a, entries):
    home = Path(a.home).expanduser().resolve()
    home.mkdir(parents=True, mode=0o700, exist_ok=True)
    fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        return import_locked(a, entries, home)
    finally:
        os.close(fd)


def import_locked(a, entries, home):
    actions, token = plan(a, entries)
    if token != a.preview_token:
        raise ValueError('预览已失效，请重新预览')
    changes = [x for x in actions if x['action'] not in ('skip', 'busy')]
    if not changes:
        return {**public(actions, token), 'rollback_path': None, 'rollback_archive_path': None}
    root = home / 'agent-dash-backups'
    if root.is_symlink():
        raise ValueError('快照目录是符号链接')
    root.mkdir(mode=0o700, exist_ok=True)
    for previous in root.glob('import-*'):
        if previous.is_symlink() or (previous.is_dir() and not (previous / 'committed').exists() and not (previous / 'rolledback').exists()):
            raise ValueError('存在未完成的回滚快照: ' + str(previous))
    snap = Path(tempfile.mkdtemp(prefix='import-', dir=root))
    old_ids = [x['id'] for x in changes if x['old_sha256'] is not None]
    rollback_archive = None
    if old_ids:
        try:
            rollback_archive = str(snap / 'rollback.zip')
            export(argparse.Namespace(home=str(home), output=rollback_archive, id=old_ids))
        except (ValueError, OSError):
            rollback_archive = None
    journal = []
    for i, name in enumerate(dict.fromkeys(p for x in changes for p in (x['path'], x['old_path']))):
        path = Path(name)
        backup = str(i) + '.snapshot' if path.exists() else None
        if backup:
            atomic(snap / backup, path)
        journal.append({'path': name, 'backup': backup})
    atomic(snap / 'manifest.json', canonical({'files': journal}))
    changed = []
    try:
        again, new_token = plan(a, entries)
        if new_token != token:
            raise ValueError('会话状态已变化，请重新预览')
        for x in changes:
            target, old = Path(x['path']), Path(x['old_path'])
            safe(home, target.relative_to(home).as_posix())
            if busy(old) or (old != target and target.exists()):
                raise ValueError('会话状态已变化，请重新预览: ' + x['id'])
            current_sha = session_hash(old) if old.exists() else None
            if current_sha != x['old_sha256']:
                raise ValueError('会话内容已变化，请重新预览: ' + x['id'])
            atomic(target, x['data'])
            changed.append(str(target))
            if old != target and old.exists():
                old.unlink()
                changed.append(str(old))
        atomic(snap / 'committed', b'committed\n')
    except Exception as error:
        try:
            for name in reversed(changed):
                entry = next(x for x in journal if x['path'] == name)
                target = Path(name)
                if entry['backup']:
                    atomic(target, snap / entry['backup'])
                elif target.exists():
                    target.unlink()
            atomic(snap / 'rolledback', b'rolled back\n')
        except Exception as restore_error:
            raise ValueError(f'{error}; 自动回滚失败: {restore_error}; 回滚快照: {snap}') from error
        raise ValueError(f'{error}; 回滚快照: {snap}') from error
    return {**public(actions, token), 'rollback_path': str(snap), 'rollback_archive_path': rollback_archive}


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
    args = parser.parse_args()
    if args.command == 'export':
        return export(args)
    if args.command == 'import':
        with tempfile.TemporaryDirectory(prefix='agent-dash-pi-') as stage:
            return do_import(args, archive(args, stage))
    return public(*plan(args, archive(args, None)))


if __name__ == '__main__':
    try:
        print(json.dumps(main(), ensure_ascii=False))
    except (ValueError, KeyError, TypeError, OSError, zipfile.BadZipFile, json.JSONDecodeError) as error:
        print(json.dumps({'error': str(error)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
