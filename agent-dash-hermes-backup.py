#!/usr/bin/env python3
"""Export and restore Hermes state.db sessions as an agent-dash archive."""
import argparse
import base64
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import tempfile
import time
import unicodedata
import zipfile

LIMIT = 256 * 1024 * 1024
TABLES = ('sessions', 'messages', 'session_model_usage', 'system_prompts')


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def sha(value):
    return hashlib.sha256(value).hexdigest()


def packed(value):
    if isinstance(value, bytes):
        return {'$bytes': base64.b64encode(value).decode()}
    return value


def unpacked(value):
    if isinstance(value, dict) and set(value) == {'$bytes'}:
        return base64.b64decode(value['$bytes'], validate=True)
    if isinstance(value, (dict, list)):
        raise ValueError('无效数据库值')
    return value


def dbpath(home):
    home = Path(home).expanduser().absolute()
    if home.is_symlink() or not home.is_dir():
        raise ValueError('Hermes home 不存在或是符号链接')
    path = home / 'state.db'
    if path.is_symlink() or not path.is_file():
        raise ValueError('Hermes state.db 不存在或是符号链接')
    return path


def connect(home, write=False):
    path = dbpath(home)
    from urllib.parse import quote
    conn = sqlite3.connect('file:' + quote(str(path)) + ('?mode=rw' if write else '?mode=ro'), uri=True, timeout=0)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA foreign_keys=ON')
    return conn


def cols(db, table):
    return [row[1] for row in db.execute('PRAGMA table_info("' + table + '")')]


def rows(db, table, where, args):
    return [{k: packed(row[k]) for k in row.keys()} for row in db.execute('SELECT * FROM "' + table + '" WHERE ' + where, args)]


def check_recovery_names(selected, existing):
    # macOS volumes can fold Unicode normalization and case in filenames.
    keys = {unicodedata.normalize('NFD', sid).casefold(): sid for sid in selected}
    if len(keys) != len(selected) or any(keys.get(unicodedata.normalize('NFD', sid).casefold(), sid) != sid for sid in existing):
        raise ValueError('Hermes recovery JSONL 文件名冲突')


def recovery_path(home, sid):
    if not isinstance(sid, str) or not sid.strip() or sid.strip() != sid or sid in ('.', '..') or re.search(r'[/\\\x00-\x1f]', sid):
        raise ValueError('无法安全定位 Hermes recovery JSONL')
    directory = Path(home) / 'sessions'
    path = directory / (sid + '.jsonl')
    if directory.is_symlink() or path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError('Hermes recovery JSONL 路径无效')
    return path


def recovery(home, sid):
    path = recovery_path(home, sid)
    if not path.exists():
        return None
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(fd)
        if before.st_size > LIMIT:
            raise ValueError('Hermes recovery JSONL 超过大小限制')
        raw = stream.read(LIMIT + 1)
        after = path.stat()
        if before.st_ino != after.st_ino or before.st_mtime_ns != after.st_mtime_ns or len(raw) != after.st_size:
            raise ValueError('Hermes recovery JSONL 已变化')
        return packed(raw)


def restore_recovery(home, sid, value):
    path = recovery_path(home, sid)
    if value is None:
        path.unlink(missing_ok=True)
        return
    path.parent.mkdir(mode=0o700, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.agent-dash-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as target:
            target.write(unpacked(value))
            target.flush()
            os.fsync(target.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


POLICY_PREFIX = 'gateway.local_policy.v1:'


LOCAL_META = ('gateway.local_legacy.v1:', 'gateway.history_control.v1.')


def receipt(db, sid, prefix=POLICY_PREFIX):
    if not cols(db, 'state_meta'):
        return None
    row = db.execute('SELECT value FROM state_meta WHERE key=?', (prefix + sid,)).fetchone()
    return row[0] if row else None


def collect(db, ids, branch=True):
    if not ids or len(ids) != len(set(ids)) or any(not isinstance(i, str) or not i for i in ids):
        raise ValueError('需要不重复的会话 ID')
    schema = {t: cols(db, t) for t in TABLES}
    if not {'id', 'parent_session_id'} <= set(schema['sessions']) or not {'id', 'session_id'} <= set(schema['messages']) or not schema['system_prompts']:
        raise ValueError('不支持的 Hermes schema')
    parents = dict(db.execute('SELECT id,parent_session_id FROM sessions'))
    selected = set(ids)
    if not selected <= parents.keys():
        raise ValueError('未找到会话: ' + ', '.join(sorted(selected - parents.keys())))
    if branch:
        children = {}
        if branch != 'ancestors':
            for child, parent in parents.items():
                children.setdefault(parent, []).append(child)
        queue = list(selected)
        while queue:
            sid = queue.pop()
            neighbors = set(children.get(sid, ()))
            if parents[sid]:
                neighbors.add(parents[sid])
            if not neighbors <= parents.keys():
                raise ValueError('会话父节点不存在')
            queue.extend(neighbors - selected)
            selected.update(neighbors)
    if branch == 'ancestors':
        for sid in tuple(selected):
            raw = receipt(db, sid)
            if raw:
                saved = json.loads(raw)
                selected.update(saved.get('lineage', ()))
                selected.add(saved['entry']['session_id'])
    check_recovery_names(selected, parents)
    sessions = [rows(db, 'sessions', 'id=?', (sid,))[0] for sid in sorted(selected)]
    for s in sessions:
        seen = set()
        cursor = s['id']
        while cursor:
            if cursor in seen or cursor not in parents:
                raise ValueError('会话父节点缺失或循环')
            seen.add(cursor)
            cursor = parents[cursor]
    messages, usage = [], []
    for sid in sorted(selected):
        messages.extend(rows(db, 'messages', 'session_id=? ORDER BY id', (sid,)))
        if schema['session_model_usage']:
            usage.extend(rows(db, 'session_model_usage', 'session_id=? ORDER BY rowid', (sid,)))
    hashes = {s.get('system_prompt_hash') for s in sessions} - {None, ''}
    prompts = []
    for h in sorted(hashes):
        found = rows(db, 'system_prompts', 'hash=?', (h,))
        if len(found) != 1:
            raise ValueError('系统提示缺失')
        prompts.extend(found)
    home = Path(db.execute('PRAGMA database_list').fetchone()[2]).parent
    files = {sid: recovery(home, sid) for sid in sorted(selected)}
    return {'format': 'agent-dash-hermes', 'version': 1, 'schema': schema, 'sessions': sessions, 'messages': messages, 'session_model_usage': usage, 'system_prompts': prompts, 'recovery': files, 'receipts': {sid: receipt(db, sid) for sid in sorted(selected)}, 'local_meta': {sid: {p: receipt(db, sid, p) for p in LOCAL_META} for sid in sorted(selected)}}


def save_archive(path, data):
    raw = encode(data)
    if len(raw) > LIMIT:
        raise ValueError('归档超过大小限制')
    path = Path(path).expanduser().absolute()
    if path.exists() or path.is_symlink():
        raise ValueError('输出文件已存在')
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.agent-dash-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w+b') as stream:
            with zipfile.ZipFile(stream, 'w', zipfile.ZIP_STORED) as z:
                z.writestr('manifest.json', encode({'format': 'agent-dash-hermes', 'version': 1, 'sha256': sha(raw)}))
                z.writestr('sessions.json', raw)
            stream.flush()
            os.fsync(stream.fileno())
        load_archive(tmp)
        os.link(tmp, path)
    finally:
        os.unlink(tmp)
    return str(path)


def load_archive(path):
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        if len(infos) != 2 or set(z.namelist()) != {'manifest.json', 'sessions.json'} or z.getinfo('manifest.json').file_size > 4096 or any(i.flag_bits & 1 or i.file_size > LIMIT or i.file_size > 1000 * max(i.compress_size, 1) for i in infos):
            raise ValueError('归档目录或大小无效')
        manifest = json.loads(z.read('manifest.json'))
        raw = z.read('sessions.json')
        if manifest != {'format': 'agent-dash-hermes', 'version': 1, 'sha256': sha(raw)}:
            raise ValueError('归档格式或校验失败')
        data = json.loads(raw)
    if not isinstance(data, dict) or data.get('format') != 'agent-dash-hermes' or data.get('version') != 1 or set(data) != {'format', 'version', 'schema', 'recovery', 'receipts', 'local_meta', *TABLES}:
        raise ValueError('不支持的归档格式')
    schema = data['schema']
    if not isinstance(schema, dict) or set(schema) != set(TABLES):
        raise ValueError('无效 schema')
    for table in TABLES:
        columns = schema[table]
        if not isinstance(columns, list) or any(not isinstance(c, str) or not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', c) for c in columns) or len(set(columns)) != len(columns) or not isinstance(data[table], list):
            raise ValueError('无效 schema 或数据')
        for row in data[table]:
            if not isinstance(row, dict) or set(row) != set(columns):
                raise ValueError('无效数据行')
            for value in row.values():
                unpacked(value)
    ids = [s.get('id') for s in data['sessions']]
    if not ids or len(set(ids)) != len(ids) or any(not isinstance(i, str) or not i for i in ids):
        raise ValueError('无效会话 ID')
    if not isinstance(data['recovery'], dict) or set(data['recovery']) != set(ids):
        raise ValueError('Hermes recovery 清单无效')
    for v in data['recovery'].values():
        if v is not None and not isinstance(unpacked(v), bytes):
            raise ValueError('Hermes recovery 内容无效')
    if any(r.get('session_id') not in ids for t in ('messages', 'session_model_usage') for r in data[t]):
        raise ValueError('关联数据引用了其他会话')
    byid = {s['id']: s for s in data['sessions']}
    if not isinstance(data['receipts'], dict) or set(data['receipts']) != set(ids):
        raise ValueError('Hermes 本地会话回执清单无效')
    if not isinstance(data['local_meta'], dict) or set(data['local_meta']) != set(ids):
        raise ValueError('Hermes 本地元数据清单无效')
    for sid, raw in data['receipts'].items():
        meta = data['local_meta'][sid]
        if not isinstance(meta, dict) or set(meta) != set(LOCAL_META) or any(v is not None and not isinstance(v, str) for v in meta.values()):
            raise ValueError('Hermes 本地元数据行无效')
        if raw is None:
            continue
        saved = json.loads(raw)
        if not isinstance(saved, dict) or saved.get('session_id') != sid or not isinstance(saved.get('entry'), dict) or saved['entry'].get('session_id') not in byid or saved.get('route') != byid[saved['entry']['session_id']].get('session_key') or not isinstance(saved.get('policy'), dict):
            raise ValueError('Hermes 本地会话回执身份无效')
    for sid in ids:
        seen, cursor = set(), sid
        while cursor:
            if cursor in seen or cursor not in byid:
                raise ValueError('会话父节点缺失或循环')
            seen.add(cursor)
            cursor = byid[cursor].get('parent_session_id')
    hashes = {s.get('system_prompt_hash') for s in data['sessions']} - {None, ''}
    if {p.get('hash') for p in data['system_prompts']} != hashes or len(data['system_prompts']) != len(hashes):
        raise ValueError('系统提示不匹配')
    return data


def mapped(path, mappings):
    if not isinstance(path, str):
        return path
    for old, new in sorted(mappings, key=lambda x: len(x[0].rstrip('/')), reverse=True):
        if path == old:
            return new
        if path.startswith(old.rstrip('/') + '/'):
            return new.rstrip('/') + path[len(old.rstrip('/')):]
    return path


def normalize(data, maps):
    if len({x[0] for x in maps}) != len(maps) or any(not os.path.isabs(a) or not os.path.isabs(b) for a, b in maps):
        raise ValueError('无效目录映射')
    data = json.loads(encode(data))
    for row in data['sessions']:
        for key in ('cwd', 'git_repo_root'):
            if key in row:
                row[key] = mapped(row[key], maps)
        config = row.get('model_config')
        if isinstance(config, str):
            try:
                parsed = json.loads(config)
            except json.JSONDecodeError:
                parsed = None
            if isinstance(parsed, dict) and isinstance(parsed.get('cwd'), str):
                new = mapped(parsed['cwd'], maps)
                if new != parsed['cwd']:
                    parsed['cwd'] = new
                    row['model_config'] = encode(parsed).decode()
    for sid, raw in data['receipts'].items():
        if raw is None or not maps:
            continue
        saved = json.loads(raw)
        policy = saved['policy']
        changed = False
        for key in ('cwd',):
            if key in policy and mapped(policy[key], maps) != policy[key]:
                policy[key] = mapped(policy[key], maps)
                changed = True
        for key, fields in (('terminal_json', ('TERMINAL_CWD',)), ('request_json', ('cwd', 'row_cwd'))):
            if key not in policy:
                continue
            nested = json.loads(policy[key])
            if isinstance(nested, dict) and any(f in nested and mapped(nested[f], maps) != nested[f] for f in fields):
                for f in fields:
                    if f in nested:
                        nested[f] = mapped(nested[f], maps)
                policy[key] = encode(nested).decode()
                changed = True
        if changed:
            data['receipts'][sid] = encode(saved).decode()
    return data


def comparable(data, sid):
    return {'session': next(s for s in data['sessions'] if s['id'] == sid), 'recovery': data['recovery'][sid], 'receipt': data['receipts'][sid], 'local_meta': data['local_meta'][sid],
            'messages': [{k: v for k, v in r.items() if k != 'id'} for r in data['messages'] if r['session_id'] == sid],
            'usage': sorted((r for r in data['session_model_usage'] if r['session_id'] == sid), key=encode)}


@contextmanager
def registry(home, write=False):
    runtime = dbpath(home).parent / 'runtime'
    if runtime.is_symlink():
        raise ValueError('活动会话目录是符号链接')
    if write:
        runtime.mkdir(mode=0o700, exist_ok=True)
    lock = runtime / 'active_sessions.lock'
    state = runtime / 'active_sessions.json'
    if lock.is_symlink() or state.is_symlink():
        raise ValueError('活动会话注册表路径是符号链接')
    if not write and not lock.exists():
        if state.exists():
            raise ValueError('活动会话注册表缺少原生锁')
        yield set()
        if lock.exists() or state.exists():
            raise ValueError('活动会话注册表已变化，请重试')
        return
    flags = os.O_CREAT | os.O_RDWR if write else os.O_RDONLY
    fd = os.open(lock, flags | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        active = set()
        if state.exists():
            data = json.loads(state.read_text(encoding='utf-8-sig'))
            entries = data.get('entries') if isinstance(data, dict) else data
            if not isinstance(entries, list):
                raise ValueError('活动会话注册表无效')
            seen = set()
            for entry in entries:
                if not isinstance(entry, dict) or not isinstance(entry.get('session_id'), str) or not entry['session_id'] or not isinstance(entry.get('lease_id'), str) or not entry['lease_id'] or entry['lease_id'] in seen or type(entry.get('pid')) is not int or entry['pid'] <= 0:
                    raise ValueError('活动会话注册表条目无效')
                seen.add(entry['lease_id'])
                try:
                    os.kill(entry['pid'], 0)
                except ProcessLookupError:
                    continue
                except PermissionError:
                    pass
                active.add(entry['session_id'])
        yield active
    finally:
        os.close(fd)


def leased(db, sid):
    for table, key in (('compression_locks', 'session_id'), ('session_turn_leases', 'conversation_id')):
        if {key, 'expires_at'} <= set(cols(db, table)) and db.execute('SELECT 1 FROM "' + table + '" WHERE "' + key + '"=? AND expires_at>?', (sid, time.time())).fetchone():
            return True
    for table, key, states in (('session_admissions', 'target_session_id', ('queued', 'started', 'unknown')), ('worker_executions', 'session_id', ('registered', 'running', 'unknown'))):
        if {key, 'status'} <= set(cols(db, table)) and db.execute('SELECT 1 FROM "' + table + '" WHERE "' + key + '"=? AND status IN (?,?,?) LIMIT 1', (sid, *states)).fetchone():
            return True
    return False


def plan(db, a, data):
    check_recovery_names([s['id'] for s in data['sessions']], (r[0] for r in db.execute('SELECT id FROM sessions')))
    for t in TABLES:
        if set(cols(db, t)) != set(data['schema'][t]):
            raise ValueError('Hermes schema 不匹配: ' + t)
    for prompt in data['system_prompts']:
        old = rows(db, 'system_prompts', 'hash=?', (prompt['hash'],))
        if old and old[0] != prompt:
            raise ValueError('系统提示哈希冲突')
    actions = []
    for session in data['sessions']:
        sid = session['id']
        exists = db.execute('SELECT 1 FROM sessions WHERE id=?', (sid,)).fetchone()
        incoming_control = data['local_meta'][sid][LOCAL_META[1]]
        current_control = receipt(db, sid, LOCAL_META[1])
        if current_control is not None and current_control != incoming_control:
            raise ValueError('Hermes 历史所有者绑定冲突: ' + sid)
        if (data['receipts'][sid] is not None or any(data['local_meta'][sid].values())) and not {'key', 'value'} <= set(cols(db, 'state_meta')):
            raise ValueError('目标 Hermes 缺少 state_meta')
        current_receipt = receipt(db, sid)
        if not exists and (current_receipt is not None or any(receipt(db, sid, p) is not None for p in LOCAL_META)):
            raise ValueError('已有本地回执占用会话 ID: ' + sid)
        if current_receipt is not None:
            prior_owner = json.loads(current_receipt).get('principal_id')
            incoming = data['receipts'][sid]
            if incoming is None or json.loads(incoming).get('principal_id') != prior_owner:
                raise ValueError('Hermes 本地会话所有者冲突: ' + sid)
        if not exists and recovery(a.home, sid) is not None:
            raise ValueError('已有 recovery JSONL 占用会话路径: ' + sid)
        old = collect(db, [sid], branch=False) if exists else None
        action = 'create' if not old else 'skip' if comparable(old, sid) == comparable(data, sid) else 'overwrite'
        if action != 'skip':
            existing_key = old['sessions'][0].get('session_key') if old else None
            if sid in a.active_id or {sid, session.get('session_key'), existing_key} & a.registry_active or leased(db, sid):
                action = 'busy'
        actions.append({'id': sid, 'action': action, 'path': str(dbpath(a.home)), 'old_sha256': sha(encode(comparable(old, sid))) if old else None})
    parents = {s['id']: s.get('parent_session_id') for s in data['sessions']}
    def root(sid):
        while parents[sid]:
            sid = parents[sid]
        return sid
    busy_branches = {root(x['id']) for x in actions if x['action'] == 'busy'}
    for item in actions:
        if item['action'] in ('create', 'overwrite') and root(item['id']) in busy_branches:
            item['action'] = 'busy'
    token = sha(encode({'home': str(dbpath(a.home)), 'data': data, 'actions': actions, 'active': sorted(set(a.active_id)), 'map': a.map}))
    return actions, token


def public(actions, token):
    return {'preview_token': token, 'sessions': [{k: v for k, v in row.items() if k != 'old_sha256'} for row in actions]}


def insert(db, table, row):
    names = list(row)
    if any('"' in n for n in names):
        raise ValueError('无效列名')
    db.execute('INSERT INTO "' + table + '" (' + ','.join('"' + n + '"' for n in names) + ') VALUES (' + ','.join('?' for _ in names) + ')', [unpacked(row[n]) for n in names])


def run_import(a, data):
    db = connect(a.home, True)
    restored = {}
    try:
        db.execute('BEGIN IMMEDIATE')
        db.execute('PRAGMA defer_foreign_keys=ON')
        actions, token = plan(db, a, data)
        if token != a.preview_token:
            raise ValueError('预览已失效，请重新预览')
        changes = [x['id'] for x in actions if x['action'] in ('create', 'overwrite')]
        old_ids = [x['id'] for x in actions if x['action'] == 'overwrite']
        previous_files = {sid: recovery(a.home, sid) for sid in changes}
        rollback = None
        if old_ids:
            root = dbpath(a.home).parent / 'agent-dash-backups'
            if root.is_symlink():
                raise ValueError('回滚目录是符号链接')
            root.mkdir(mode=0o700, exist_ok=True)
            directory = Path(tempfile.mkdtemp(prefix='import-', dir=root))
            rollback = save_archive(directory / 'rollback.zip', collect(db, old_ids, branch='ancestors'))
        needed_hashes = {s.get('system_prompt_hash') for s in data['sessions'] if s['id'] in changes}
        for row in data['system_prompts']:
            if row['hash'] in needed_hashes and not db.execute('SELECT 1 FROM system_prompts WHERE hash=?', (row['hash'],)).fetchone():
                insert(db, 'system_prompts', row)
        for sid in changes:
            session = next(s for s in data['sessions'] if s['id'] == sid)
            if db.execute('SELECT 1 FROM sessions WHERE id=?', (sid,)).fetchone():
                names = [n for n in session if n != 'id']
                db.execute('UPDATE sessions SET ' + ','.join('"' + n + '"=?' for n in names) + ' WHERE id=?', [unpacked(session[n]) for n in names] + [sid])
                db.execute('DELETE FROM messages WHERE session_id=?', (sid,))
                if cols(db, 'session_model_usage'):
                    db.execute('DELETE FROM session_model_usage WHERE session_id=?', (sid,))
            else:
                # Parent references can be inserted in any order in this transaction.
                insert(db, 'sessions', session)
        for sid in changes:
            if cols(db, 'state_meta'):
                for prefix, value in {POLICY_PREFIX: data['receipts'][sid], **data['local_meta'][sid]}.items():
                    key = prefix + sid
                    db.execute('DELETE FROM state_meta WHERE key=?', (key,))
                    if value is not None:
                        db.execute('INSERT INTO state_meta(key,value) VALUES (?,?)', (key, value))
        for table in ('messages', 'session_model_usage'):
            for row in data[table]:
                if row['session_id'] in changes:
                    insert(db, table, {k: v for k, v in row.items() if table != 'messages' or k != 'id'})
                    if table == 'messages':
                        inserted = db.execute('SELECT last_insert_rowid()').fetchone()[0]
                        names = [n for n in ('display_order', 'message_uid') if n in row]
                        if names:
                            db.execute('UPDATE messages SET ' + ','.join('"' + n + '"=?' for n in names) + ' WHERE id=?', [unpacked(row[n]) for n in names] + [inserted])
        for sid in changes:
            previous = previous_files[sid]
            if recovery(a.home, sid) != previous:
                raise ValueError('Hermes recovery JSONL 已变化，请重新预览')
            if previous != data['recovery'][sid]:
                restore_recovery(a.home, sid, data['recovery'][sid])
                restored[sid] = previous
        db.commit()
        return {**public(actions, token), 'rollback_path': str(Path(rollback).parent) if rollback else None, 'rollback_archive_path': rollback}
    except BaseException:
        db.rollback()
        for sid, previous in reversed(list(restored.items())):
            restore_recovery(a.home, sid, previous)
        raise
    finally:
        db.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    exp = commands.add_parser('export')
    exp.add_argument('--home', required=True)
    exp.add_argument('--output', required=True)
    exp.add_argument('--id', action='append', required=True)
    for name in ('preview', 'import'):
        p = commands.add_parser(name)
        p.add_argument('--home', required=True)
        p.add_argument('--input', required=True)
        p.add_argument('--active-id', action='append', default=[])
        p.add_argument('--map', action='append', nargs=2, default=[])
        if name == 'import':
            p.add_argument('--preview-token', required=True)
    a = parser.parse_args()
    if a.command == 'export':
        with registry(a.home) as active, connect(a.home) as db:
            db.execute('BEGIN')
            data = collect(db, a.id)
            if any({s['id'], s.get('session_key')} & active or leased(db, s['id']) for s in data['sessions']):
                raise ValueError('Hermes 会话正在使用 (busy)')
        return {'output': save_archive(a.output, data), 'count': len(data['sessions'])}
    data = normalize(load_archive(a.input), a.map)
    with registry(a.home, write=a.command == 'import') as active:
        a.registry_active = active
        if a.command == 'import':
            return run_import(a, data)
        with connect(a.home) as db:
            db.execute('BEGIN')
            return public(*plan(db, a, data))


if __name__ == '__main__':
    try:
        print(json.dumps(main(), ensure_ascii=False))
    except (ValueError, KeyError, TypeError, OSError, sqlite3.Error, zipfile.BadZipFile, json.JSONDecodeError) as error:
        print(json.dumps({'error': str(error)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
