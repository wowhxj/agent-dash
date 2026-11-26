#!/usr/bin/env python3
"""Conservative native agy 1.5.18 session backup and create-only restore."""
import argparse
from contextlib import closing, contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sqlite3
import subprocess
import sys
import tempfile
import unicodedata
import urllib.parse
import zipfile

LIMIT = 256 * 1024 * 1024
TOTAL = 1024 * 1024 * 1024
ID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
WARNINGS = ['仅支持新建会话；已有同 ID 的会话不会覆盖。',
            '请在整个恢复期间保持目标 agy 配置停止；文件占用检查不能阻止其他进程随后启动。',
            '建议导出时停止目标会话；SQLite 快照包含 WAL，但附件不能与数据库保证同一时刻。',
            '会话内含原机器路径；尚未验证完整路径迁移，导入不会改写路径。',
            'implicit 数据的会话关联未知，未包含在单会话备份中；附件及外部工作区文件可能缺失。',
            '恢复后需重新启动 agy 以扫描并更新索引；搜索索引和其他客户端缓存可能延后更新。',
            '恢复期间进程被强制终止可能留下不完整的同 ID 文件，之后将显示冲突，需检查后手动处理。']


def check(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(data):
    return json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()


def safe_id(sid):
    check(isinstance(sid, str) and ID.fullmatch(sid), '无效 agy 会话 ID')
    return sid


def home_path(home):
    home = Path(home).expanduser().absolute()
    check(home.is_dir() and not home.is_symlink(), 'agy 目录不存在或是符号链接')
    return home


def safe_child(root, rel):
    rel = member_path(rel)
    path = root
    for part in rel.parts:
        path = path / part
        check(not path.is_symlink(), '不支持符号链接: ' + str(path))
    return path


def member_path(name):
    rel = PurePosixPath(name)
    check(not rel.is_absolute() and rel.parts and str(rel) == name
          and not re.search(r'[\\\\:\x00-\x1f]', name)
          and '..' not in rel.parts, '无效归档路径')
    return rel


def member_id(name):
    rel = member_path(name)
    group, *parts = rel.parts
    if group == 'conversations' and len(parts) == 1 and parts[0].endswith('.db'):
        return safe_id(parts[0][:-3])
    if group == 'annotations' and len(parts) == 1 and parts[0].endswith('.pbtxt'):
        return safe_id(parts[0][:-6])
    if group == 'brain' and len(parts) >= 2:
        return safe_id(parts[0])
    raise ValueError('未知归档成员')


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


@contextmanager
def restore_lock(home):
    fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def db_uri(path):
    for suffix in ('-wal', '-shm', '-journal'):
        check(not Path(str(path) + suffix).is_symlink(), '数据库辅助文件是符号链接')
    return 'file:' + urllib.parse.quote(str(path)) + '?mode=ro'


def validate_trajectory(db, sid):
    check(db.execute('pragma quick_check').fetchone()[0] == 'ok'
          and db.execute('pragma user_version').fetchone()[0] == 1
          and db.execute("select 1 from sqlite_master where type='table' and name='trajectory_meta'").fetchone()
          and db.execute('select 1 from trajectory_meta where cascade_id=?', (sid,)).fetchone(),
          '会话数据库损坏，或版本及会话 ID 不匹配')


def read_file(path):
    check(path.is_file() and not path.is_symlink(), '备份文件不存在或是符号链接')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as f:
        before = os.fstat(f.fileno())
        data = f.read(LIMIT + 1)
        after = path.stat()
        check((before.st_dev, before.st_ino, before.st_mtime_ns, before.st_size) ==
              (after.st_dev, after.st_ino, after.st_mtime_ns, after.st_size), '备份文件读取时发生变化')
    check(len(data) <= LIMIT, '文件超过大小限制')
    return data


def snapshot_db(path, sid):
    check(path.is_file() and not path.is_symlink(), '找不到会话数据库')
    with tempfile.TemporaryDirectory(prefix='agy-db-') as d:
        target = Path(d) / 'session.db'
        with closing(sqlite3.connect(db_uri(path), uri=True, timeout=5)) as source, closing(sqlite3.connect(target)) as dest:
            source.backup(dest)
            validate_trajectory(dest, sid)
        return read_file(target)


def offline(home):
    # This observes the destination profile only; it cannot prevent a new
    # process from starting, so the caller must also keep agy stopped.
    try:
        result = subprocess.run(['lsof', '-t', '+D', str(home)], capture_output=True, timeout=15)
    except (FileNotFoundError, subprocess.SubprocessError) as e:
        raise ValueError('无法检查目标 agy 目录是否使用中') from e
    pids = set(result.stdout.split())
    pids.discard(str(os.getpid()).encode())
    check(result.returncode in (0, 1) and not pids and not result.stderr,
          '目标 agy 目录正在使用或无法确认状态，请停止使用该目录的进程')


def workspace_index(home, ids):
    path = safe_child(home, 'conversation_summaries.db')
    if not path.is_file():
        return {sid: [] for sid in ids}
    result = {}
    with closing(sqlite3.connect(db_uri(path), uri=True, timeout=5)) as db:
        for sid in ids:
            row = db.execute('select workspace_uris from conversation_summaries where conversation_id=?', (sid,)).fetchone()
            uris = json.loads(row[0]) if row and row[0] else []
            check(isinstance(uris, list), 'agy 工作区索引无效')
            paths = []
            for value in uris:
                check(isinstance(value, str), 'agy 工作区地址无效')
                parsed = urllib.parse.urlsplit(value)
                if parsed.scheme == 'file' and parsed.netloc in ('', 'localhost'):
                    paths.append(urllib.parse.unquote(parsed.path))
            result[sid] = paths
    return result


def export(home, ids, output):
    check(ids and len(ids) == len(set(ids)), '会话 ID 为空或重复')
    for sid in ids:
        safe_id(sid)
    home = home_path(home)
    output = Path(output).expanduser().absolute()
    check(not output.exists() and not output.is_symlink(), '输出文件已存在')
    paths = workspace_index(home, ids)
    files = {}
    sessions = []
    for sid in ids:
        name = 'conversations/' + sid + '.db'
        files[name] = snapshot_db(safe_child(home, name), sid)
        for rel in ('annotations/' + sid + '.pbtxt', 'brain/' + sid):
            source = safe_child(home, rel)
            if source.is_file():
                files[rel] = read_file(source)
            elif source.is_dir():
                for item in source.rglob('*'):
                    check(not item.is_symlink(), '不支持会话附件中的符号链接')
                    if item.is_file():
                        name = item.relative_to(home).as_posix()
                        member_path(name)
                        files[name] = read_file(item)
        sessions.append({'id': sid, 'cwd': paths[sid][0] if paths[sid] else '', 'workspaces': paths[sid]})
    check(len(files) <= 10000 and sum(map(len, files.values())) <= TOTAL, '备份内容超过限制')
    manifest = {'format': 'agent-dash-agy', 'version': 1, 'sessions': sessions,
                'files': {k: digest(v) for k, v in files.items()}, 'warnings': WARNINGS}
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent) as stage:
        with zipfile.ZipFile(stage, 'w', zipfile.ZIP_STORED) as z:
            z.writestr('manifest.json', canonical(manifest))
            for name, data in files.items():
                z.writestr(name, data)
        stage.flush(); os.fsync(stage.fileno()); os.link(stage.name, output)
    return {'output': str(output), 'count': len(ids), 'sessions': sessions, 'warnings': WARNINGS}


def unpack(path):
    with zipfile.ZipFile(path) as z:
        infos = z.infolist(); names = [i.filename for i in infos]
        check(len(names) == len(set(names)) <= 10001 and 'manifest.json' in names, '无效归档')
        check(all(not i.is_dir() and not i.flag_bits & 1 and i.file_size <= LIMIT for i in infos) and sum(i.file_size for i in infos) <= TOTAL, '归档超出限制')
        check(z.getinfo('manifest.json').file_size <= 2 * 1024 * 1024, '归档清单超过大小限制')
        manifest = json.loads(z.read('manifest.json'))
        check(isinstance(manifest, dict) and manifest.get('format') == 'agent-dash-agy'
              and manifest.get('version') == 1, '不支持的 agy 归档')
        sessions = manifest.get('sessions'); declared = manifest.get('files')
        check(isinstance(sessions, list) and sessions and isinstance(declared, dict), '无效 agy 清单')
        ids = {safe_id(s['id']) for s in sessions}
        folded = {unicodedata.normalize('NFD', n).casefold() for n in names}
        check(len(sessions) == len(ids) and len(names) == len(folded)
              and set(names) == {'manifest.json'} | set(declared), '归档成员不匹配')
        files = {}
        for name, expected in declared.items():
            check(member_id(name) in ids, '未知归档成员')
            data = z.read(name)
            check(digest(data) == expected, '归档校验失败')
            files[name] = data
        for sid in ids:
            name = 'conversations/' + sid + '.db'
            check(name in files, '会话数据库缺失')
            with tempfile.TemporaryDirectory(prefix='agy-validate-') as d:
                p = Path(d) / 'db'; p.write_bytes(files[name])
                with closing(sqlite3.connect(p)) as db:
                    db.execute('PRAGMA trusted_schema=OFF')
                    validate_trajectory(db, sid)
        for row in sessions:
            check(isinstance(row.get('workspaces'), list) and all(isinstance(x, str) for x in row['workspaces']), '工作区清单无效')
        return manifest, files


def project_dirs(path):
    manifest, _ = unpack(path)
    for row in manifest['sessions']:
        yield from row['workspaces']


def identical(home, sid, files):
    database = 'conversations/' + sid + '.db'
    if any(safe_child(home, database + ext).exists() for ext in ('-wal', '-shm', '-journal')):
        return False
    actual = {database}
    annotation = 'annotations/' + sid + '.pbtxt'
    if safe_child(home, annotation).is_file():
        actual.add(annotation)
    brain = safe_child(home, 'brain/' + sid)
    if brain.is_dir():
        for item in brain.rglob('*'):
            check(not item.is_symlink(), '不支持会话附件中的符号链接')
            if item.is_file():
                actual.add(item.relative_to(home).as_posix())
    expected = {name for name in files if member_id(name) == sid}
    return actual == expected and all(safe_child(home, name).is_file()
                                      and digest(read_file(safe_child(home, name))) == digest(files[name])
                                      for name in actual)


def restore(a):
    home = home_path(a.home)
    manifest, files = unpack(a.input)
    workspaces = [path for row in manifest['sessions'] for path in row['workspaces']]
    for old, new in a.map:
        old = old.rstrip('/\\')
        check(old == new.rstrip('/\\') or not any(path == old or path.startswith(old + '/') for path in workspaces),
              'agy 尚不支持安全改写会话路径，请在原路径恢复')
    index = safe_child(home, 'conversation_summaries.db')
    indexed = set()
    if index.is_file():
        with closing(sqlite3.connect(db_uri(index), uri=True, timeout=5)) as db:
            indexed = {x[0] for x in db.execute('select conversation_id from conversation_summaries')}
    actions = []
    for row in manifest['sessions']:
        sid = row['id']
        database = 'conversations/' + sid + '.db'
        destination = safe_child(home, database)
        candidates = [database + ext for ext in ('', '-wal', '-shm', '-journal')]
        candidates += ['brain/' + sid, 'annotations/' + sid + '.pbtxt']
        existing = sid in indexed or any(safe_child(home, name).exists() for name in candidates)
        action = ('busy' if sid in a.active_id else
                  'skip' if destination.is_file() and identical(home, sid, files) else
                  'conflict' if existing else 'create')
        actions.append({'id': sid, 'action': action, 'path': str(destination), 'old_path': str(destination)})
    token = digest(canonical({'home': str(home), 'manifest': manifest, 'actions': actions,
                              'active': sorted(a.active_id), 'map': a.map}))
    result = {'preview_token': token, 'sessions': actions, 'warnings': WARNINGS}
    if a.command == 'preview':
        return result
    check(a.preview_token == token, '预览已失效，请重新预览')
    check(all(x['action'] in ('create', 'busy', 'skip') for x in actions), '已有同 ID 的目标会话，拒绝覆盖')
    selected = {x['id'] for x in actions if x['action'] == 'create'}
    if selected:
        with restore_lock(home):
            offline(home)
            install(home, {name: data for name, data in files.items() if member_id(name) in selected})
    return dict(result, rollback_path=None, rollback_archive_path=None)


def install(home, files):
    created_dirs = []
    installed = []
    with tempfile.TemporaryDirectory(prefix='.agent-dash-agy-', dir=home) as staging:
        stage = Path(staging)
        try:
            # Native discovery only sees the conversation once the DB is published.
            for i, name in enumerate(sorted(files, key=lambda name: name.startswith('conversations/'))):
                target = safe_child(home, name)
                missing = [p for p in target.parents if p != home and p.is_relative_to(home) and not p.exists()]
                for directory in reversed(missing):
                    directory.mkdir(mode=0o700)
                    created_dirs.append(directory)
                    sync_directory(directory.parent)
                source = stage / str(i)
                fd = os.open(source, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, 'wb') as f:
                    f.write(files[name]); f.flush(); os.fsync(f.fileno())
                os.link(source, target)
                installed.append((source, target))
                sync_directory(target.parent)
        except BaseException:
            for source, target in reversed(installed):
                if target.exists() and os.path.samestat(source.stat(), target.lstat()):
                    target.unlink()
                    sync_directory(target.parent)
            for directory in reversed(created_dirs):
                if directory.is_dir() and not any(directory.iterdir()):
                    directory.rmdir()
            raise


def main():
    p = argparse.ArgumentParser(); subs = p.add_subparsers(dest='command', required=True)
    for cmd in ('export', 'preview', 'import'):
        q = subs.add_parser(cmd); q.add_argument('--home', required=True)
        if cmd == 'export':
            q.add_argument('--output', required=True); q.add_argument('--id', action='append', required=True)
        else:
            q.add_argument('--input', required=True); q.add_argument('--active-id', action='append', default=[]); q.add_argument('--map', nargs=2, action='append', default=[])
            if cmd == 'import': q.add_argument('--preview-token', required=True)
    a = p.parse_args()
    result = export(a.home, a.id, a.output) if a.command == 'export' else restore(a)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, sqlite3.Error, zipfile.BadZipFile, KeyError, TypeError, json.JSONDecodeError) as e:
        print(json.dumps({'error': str(e)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
