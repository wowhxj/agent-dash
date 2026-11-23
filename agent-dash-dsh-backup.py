#!/usr/bin/env python3
"""Native DSH backup for the standard POSIX sessions/ and storages/ layout."""
import argparse
import importlib.util
from contextlib import ExitStack
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import urllib.parse
import zipfile

from agent_dash_backup_paths import absolute_source, windows_destination

spec = importlib.util.spec_from_file_location('dsh_assets', Path(__file__).with_name('agent-dash-dsh-assets.py'))
asset = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asset)

SAFE_ID = re.compile(r'[a-zA-Z0-9][a-zA-Z0-9_-]{0,126}')
LIMIT = 256 << 20
TOTAL = 1 << 30
REG = Path('storages/workspace.json')
WARNINGS = ['工作区文件、插件/模型配置、任务与提醒、外部路径不随会话迁移；目标 DSH Host 必须在导入全程停止。']


def check(value, message):
    if not value:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()


def under(root, path):
    check(path.is_relative_to(root) and path.resolve() == path, f'DSH 存储路径不安全: {path}')
    return path


def read(path):
    check(not path.is_symlink() and path.is_file() and path.stat().st_size <= LIMIT, f'DSH 文件缺失或超出限制: {path}')
    return path.read_bytes()


def native(home, op, **payload):
    desktop = Path('/Applications/DeepSeek Harness.app/Contents')
    node = os.getenv('DSH_NODE_EXECUTABLE')
    anchor = os.getenv('DSH_INSTALL_DIR')
    if not anchor and desktop.is_dir():
        node = str(desktop / 'MacOS/DeepSeek Harness')
        anchor = str(desktop / 'Resources/app.asar/dsh/node_modules/@deepseek-ai/dsh')
    if not anchor and shutil.which('dsh'):
        anchor = str(Path(shutil.which('dsh')).resolve().parent.parent)
    check(anchor, '需要已安装的 DSH；请设置 DSH_INSTALL_DIR 和 DSH_NODE_EXECUTABLE')
    args = [node or 'node', str(Path(__file__).with_suffix('.mjs'))]
    env = {**os.environ, 'DSH_INSTALL_DIR': anchor, 'ELECTRON_RUN_AS_NODE': '1'}
    result = subprocess.run(args, input=canonical(dict(home=str(home), op=op, **payload)), capture_output=True, env=env)
    check(result.returncode == 0, 'DSH: ' + result.stderr.decode(errors='replace').strip()[-2000:])
    return json.loads(result.stdout)


def files(home, sid):
    check(isinstance(sid, str) and SAFE_ID.fullmatch(sid), 'DSH 会话 ID 不是受支持的安全路径段')
    root = under(home, home / 'sessions')
    matches = [under(home, p) for p in root.glob('*/' + sid)]
    check(len(matches) <= 1, f'DSH 会话 ID 不唯一: {sid}')
    if not matches:
        return None
    path = matches[0] / 'session.v4.jsonl.zstd'
    check(all(re.fullmatch(r'session(?:\.v[1-4])?\.jsonl\.zstd|session\.lock', p.name) and p.is_file() and not p.is_symlink() for p in matches[0].iterdir()), f'DSH 会话包含不支持的存储格式: {sid}')
    read(path)
    return path


def validate_row(row):
    h = row['header']
    check(isinstance(h['id'], str) and SAFE_ID.fullmatch(h['id']) and absolute_source(h.get('cwd')), 'DSH 会话头无效')
    check(type(row['inherited']) is int and 0 <= row['inherited'] <= len(row['events']), 'DSH 继承序列长度无效')
    events = row['events']
    check(isinstance(events, list) and all(e['seq'] == i for i,e in enumerate(events)), 'DSH 事件序列不连续')
    return h['id']


def export(home, ids, output):
    check(ids and len(set(ids)) == len(ids), 'DSH 备份会话重复或为空')
    for sid in ids:
        check(files(home, sid), f'DSH 标准存储中没有会话 {sid}，请核对 DSH_HOME 和 JSONL 根目录')
    output = Path(output).absolute()
    entries, seen = [], set()
    with tempfile.TemporaryDirectory(prefix='agent-dash-dsh-export-') as work, tempfile.NamedTemporaryFile(dir=output.parent) as temp:
        tree = native(home, 'tree', ids=ids, stage=work)
        total = 0
        with zipfile.ZipFile(temp, 'w', zipfile.ZIP_DEFLATED) as z:
            for entry in tree['rows']:
                check(entry['file'].isdigit(), 'DSH 暂存索引无效')
                row = json.loads(read(Path(work) / entry['file']))
                row.update(selected=entry['selected'], owners=entry['owners'])
                sid = validate_row(row)
                check(sid == entry['id'] and files(home, sid), 'DSH 依赖的存储路径无效')
                data = canonical(row)
                check(len(data) <= LIMIT, 'DSH 会话超过大小限制')
                entries.append(dict(id=sid, cwd=row['header']['cwd'], sha256=digest(data)))
                z.writestr('sessions/' + sid + '.json', data)
                total += len(data)
                for key, blob in asset.collect(home, row['events']).items():
                    if key not in seen:
                        total += len(blob)
                        z.writestr('assets/' + key, blob)
                        seen.add(key)
                check(total <= TOTAL, 'DSH 备份超出总大小限制')
            manifest = dict(format='agent-dash-dsh', version=1,
                            sessions=[e for e in entries if e['id'] in ids],
                            dependencies=[e for e in entries if e['id'] not in ids],
                            warnings=WARNINGS + tree['warnings'])
            z.writestr('manifest.json', canonical(manifest))
        temp.flush(); os.fsync(temp.fileno()); os.link(temp.name, output)
    return dict(output=str(output), count=len(ids), sessions=manifest['sessions'], warnings=manifest['warnings'])


def unpack(path):
    rows, blobs = [], {}
    with zipfile.ZipFile(path) as z:
        names = set(z.namelist())
        check(len(names) == len(z.infolist()) <= 10000 and all(i.file_size <= LIMIT for i in z.infolist()) and sum(i.file_size for i in z.infolist()) <= TOTAL, 'DSH 备份内容超过限制或重名')
        m = json.loads(z.read('manifest.json')); names.remove('manifest.json')
        check(m['format'] == 'agent-dash-dsh' and m['version'] == 1 and m['sessions'], 'DSH 备份格式不支持')
        roots = {entry['id'] for entry in m['sessions']}
        for entry in m['sessions'] + m.get('dependencies', []):
            sid = entry['id']; check(SAFE_ID.fullmatch(sid), 'DSH 会话 ID 无效')
            name = 'sessions/' + sid + '.json'; names.remove(name); data = z.read(name); row = json.loads(data)
            check(digest(data) == entry['sha256'] and validate_row(row) == sid and row['header']['cwd'] == entry['cwd'], 'DSH 会话校验失败')
            check(row['selected'] == (sid in roots) and row['owners'] and set(row['owners']) <= roots and (sid not in roots or sid in row['owners']), 'DSH 依赖归属无效')
            rows.append(row)
        for name in names:
            check(re.fullmatch(r'assets/[0-9a-f]{64}', name), 'DSH 备份含未声明内容')
            data = z.read(name); key = name[7:]; check(digest(data) == key, 'DSH 附件校验失败'); blobs[key] = data
    asset.verify_coverage([e for r in rows for e in r['events']], blobs)
    return rows, blobs, m.get('warnings', WARNINGS)


def project_dirs(path):
    rows, _, _warnings = unpack(path)
    for row in rows:
        yield row['header']['cwd']
        for event in row['events']:
            if event['type'] == 'working-directory/change':
                yield event['data']['cwd']


def offline(home):
    bridge = under(home, home / 'emacs-dsh-bridge.json')
    if bridge.exists():
        url = urllib.parse.urlsplit(json.loads(read(bridge))['launch']['value'])
        check(url.hostname == '127.0.0.1' and url.port, 'DSH bridge 无效，无法确认目标 Host 状态')
        with socket.socket() as sock:
            sock.settimeout(1)
            check(sock.connect_ex(('127.0.0.1', url.port)) != 0, '请先停止目标 DSH Host，再进行离线恢复')
    profiles = under(home, home / 'profiles')
    config = list(profiles.glob('*/cordis.patch.yml'))
    if config:
        c = subprocess.run(['lsof', '-t', '--', *map(str, config)], capture_output=True)
        check(c.returncode == 1 and not c.stdout and not c.stderr, '请先停止目标 DSH Host，或检查 lsof 能否确认 profile 未使用')


def mapped(path, rules):
    source = Path(path)
    for old, new in sorted(rules, key=lambda x: len(x[0]), reverse=True):
        target = windows_destination(path, old, new)
        if target is not None:
            return str(Path(target).resolve())
        if source.is_relative_to(old):
            return str((Path(new) / source.relative_to(old)).resolve())
    return str(source)


def locked(path, stack=None):
    if not path.exists() and stack is None:
        return False
    flags = os.O_RDONLY if stack is None else os.O_CREAT | os.O_RDWR
    with ExitStack() as local:
        handle = local.enter_context(os.fdopen(os.open(path, flags | os.O_NOFOLLOW, 0o600), 'rb'))
        try: fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return True
        if stack is not None: stack.enter_context(local.pop_all())
        return False


def restore(a, home):
    rows, blobs, warnings = unpack(a.input)
    for old, new in a.map:
        check(absolute_source(old) and Path(new).is_absolute(), 'DSH cwd 映射必须使用绝对路径')
    registry = under(home, home / REG)
    with tempfile.TemporaryDirectory(prefix='agent-dash-dsh-stage-') as work, ExitStack() as stack:
        stage = Path(work).resolve(); (stage/'storages').mkdir()
        before_reg = read(registry) if registry.exists() else None
        if before_reg is not None: (stage/REG).write_bytes(before_reg)
        if a.command == 'import':
            offline(home)
            fd = os.open(home, os.O_RDONLY); stack.callback(os.close, fd)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        oldfiles, actions = {}, []
        existing_headers = native(home, 'headers', ids=[r['header']['id'] for r in rows])
        for row in rows:
            h = row['header']; sid = h['id']; original = h['cwd']
            h['cwd'] = mapped(original, a.map)
            existing = existing_headers.get(sid)
            rules = a.map
            if existing and existing['cwd'] != h['cwd']:
                h['cwd'] = existing['cwd']
                rules = [(original, h['cwd']), *a.map]
                warnings = [*warnings, f"{sid} 保留目标机已登记的工作区 {h['cwd']}"]
            check(Path(h['cwd']).is_dir(), 'DSH 工作区不存在，请映射 cwd: ' + h['cwd'])
            for e in row['events']:
                if e['type'] == 'working-directory/change': e['data']['cwd'] = mapped(e['data']['cwd'], rules)
            old = files(home, sid)
            oldfiles[sid] = old
        busy = set()
        for row in rows:
            sid = row['header']['id']; old = oldfiles[sid]
            if sid in a.active_id or (old and locked(under(home, old.parent/'session.lock'), stack if a.command == 'import' else None)):
                busy.update(row['owners'])
        all_rows = rows
        for row in all_rows:
            sid = row['header']['id']
            if row['selected'] and sid in busy:
                actions.append(dict(id=sid, action='busy', path=str(oldfiles[sid] or home/'sessions'), old_path=str(oldfiles[sid] or home/'sessions')))
        rows = [row for row in all_rows if set(row['owners']) - busy]
        relevant_events = [e for row in rows for e in row['events']]
        if busy:
            blobs = asset.subset(relevant_events, blobs)
        outputs = native(home, 'stage', stage=str(stage), rows=rows) if rows else []
        changed = []; old_hashes = []
        existing = [r['header']['id'] for r in rows if oldfiles[r['header']['id']]]
        prior = {r['header']['id']: r for r in native(home, 'export', ids=existing)} if existing else {}
        records = json.loads(before_reg)['tables']['workspaces'].values() if before_reg else []
        for row, name in zip(rows, outputs, strict=True):
            sid = row['header']['id']; old = oldfiles[sid]
            source = under(stage, Path(name)); target = under(home, home / source.relative_to(stage))
            check(old is None or old == target, '目标同 ID 已属于另一工作区；请将原 cwd 映射到现有工作区')
            member = row['header'].get('origin') == 'subagent' or any(sid in r['sessionIds'] and r['path'] == row['header']['cwd'] for r in records)
            same = member and prior.get(sid) == {k:row[k] for k in ('header','events','inherited')}
            action = 'skip' if same else 'overwrite' if old else 'create'
            actions.append(dict(id=sid, action=action, path=str(target), old_path=str(old or target)))
            old_hashes.append(digest(read(old)) if old else None)
            if action in ('create','overwrite'):
                changed.append((target, source))
                cache = under(home, home/'storages/session_projcache/sessions'/f'{sid}.json')
                if cache.exists(): changed.append((cache, None))
        token = digest(canonical([str(home), digest(canonical(rows)), sorted(blobs), actions, old_hashes, digest(before_reg or b'')]))
        by_id = {item['id']:item for item in actions}
        public = []
        priority = {'skip':0, 'create':1, 'overwrite':2, 'busy':3}
        for row in all_rows:
            if row['selected']:
                sid = row['header']['id']; item = dict(by_id[sid]); public.append(item)
                if sid not in busy:
                    item['action'] = max((by_id[r['header']['id']]['action'] for r in rows if sid in r['owners']),key=priority.get)
        dependencies = [f"{x['id']} ({x['action']})" for x in actions if x['id'] not in {p['id'] for p in public}]
        if dependencies: warnings = [*warnings, '关联子会话/父会话: ' + ', '.join(dependencies)]
        result = dict(preview_token=token, sessions=public, warnings=warnings)
        if a.command == 'preview': return result
        check(a.preview_token == token, 'DSH 预览已失效，请重新预览')
        if not changed:
            asset.install(home, blobs, [e for r in rows for e in r['events']]); return dict(result, rollback_path=None, rollback_archive_path=None)
        snapshots = under(home, home/'agent-dash-backups'); snapshots.mkdir(mode=0o700, exist_ok=True)
        for journal in snapshots.glob('dsh-import-*/manifest.json'):
            check((journal.parent/'committed').exists() or (journal.parent/'rolledback').exists(), 'DSH 上次恢复中断，请检查回滚快照: ' + str(journal.parent))
        saved = Path(tempfile.mkdtemp(prefix='dsh-import-', dir=snapshots)); undo = saved/'rollback.zip'
        overwritten = [x['id'] for x in actions if x['action']=='overwrite']
        if overwritten: export(home, overwritten, undo)
        changed.append((registry, stage/REG))
        backups, written = [], []
        for i,(target,source) in enumerate(changed):
            old = saved/str(i) if target.exists() else None
            if old: old.write_bytes(read(target))
            backups.append({'target':str(target), 'backup':str(old) if old else None})
        (saved/'manifest.json').write_bytes(canonical(backups))
        for file in saved.iterdir():
            with file.open('rb') as f: os.fsync(f.fileno())
        sync_directory(saved)
        sync_directory(snapshots)
        try:
            offline(home)
            check((read(registry) if registry.exists() else None)==before_reg, 'DSH workspace 在预览后改变')
            asset.install(home, blobs, [e for r in rows for e in r['events']])
            for i,(target,source) in enumerate(changed):
                under(home,target); target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                backup=backups[i]['backup']; check((read(target) if target.exists() else None)==(read(Path(backup)) if backup else None),'DSH 目标发生变化')
                if source is not None and target.name == 'session.v4.jsonl.zstd' and not backup:
                    lease = under(home, target.parent/'session.lock')
                    fd = os.open(lease, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
                    stack.callback(os.close, fd)
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    check(not target.exists(), 'DSH 会话在导入时已被创建')
                if source is None:
                    target.unlink()
                else:
                    atomic(target, read(source))
                written.append(i)
                sync_directory(target.parent)
            atomic(saved/'committed', b'committed\n')
            sync_directory(saved)
        except Exception:
            for i in reversed(written):
                target = under(home,changed[i][0]); backup=backups[i]['backup']
                if backup: atomic(target,read(Path(backup)))
                else: target.unlink()
            (saved/'rolledback').write_text('rolled back\n'); raise
        return dict(result, rollback_path=str(saved), rollback_archive_path=str(undo) if overwritten else None)


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic(target, data):
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as f:
        try:
            f.write(data); f.flush(); os.fsync(f.fileno()); os.replace(f.name,target)
        finally:
            if os.path.exists(f.name): os.unlink(f.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest='command', required=True)
    for cmd in ['export','preview','import']:
        p = subs.add_parser(cmd); p.add_argument('--home',required=True)
        if cmd=='export':
            p.add_argument('--output',required=True); p.add_argument('--id',action='append',required=True)
        else:
            p.add_argument('--input',required=True); p.add_argument('--active-id',action='append',default=[]); p.add_argument('--map',nargs=2,action='append',default=[])
            if cmd=='import': p.add_argument('--preview-token',required=True)
    a = parser.parse_args(); home=Path(a.home).expanduser().resolve(strict=True)
    check(home.is_dir(), 'DSH_HOME 不是目录')
    return export(home,a.id,a.output) if a.command=='export' else restore(a,home)


if __name__ == '__main__':
    try: print(json.dumps(main(),ensure_ascii=False))
    except Exception as e:
        print(json.dumps({'error': str(e)},ensure_ascii=False),file=sys.stderr); sys.exit(1)
