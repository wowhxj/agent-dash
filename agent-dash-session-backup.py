#!/usr/bin/env python3
"""Coordinate native session backup archives without accessing implicit homes."""
import argparse
import base64
from contextlib import contextmanager
import shutil
import hashlib
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

from agent_dash_backup_paths import absolute_source

ROOT = Path(__file__).resolve().parent
BACKENDS = {'codex': ('python', 'agent-dash-backup.py'), 'pi': ('python', 'agent-dash-pi-backup.py'), 'dsh': ('python', 'agent-dash-dsh-backup.py'), 'hermes': ('python', 'agent-dash-hermes-backup.py')}
LIMIT = 2 * 1024 * 1024 * 1024
TOTAL = 6 * 1024 * 1024 * 1024
MANIFEST_LIMIT = 16 * 1024 * 1024


def canonical(obj):
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()


def invoke(backend, args):
    kind, script = BACKENDS[backend]
    if not (ROOT / script).is_file():
        raise ValueError(f'后端 {backend} 当前不可用：缺少原生备份程序')
    cmd = [sys.executable if kind == 'python' else 'node', str(ROOT / script), *args]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode:
            try:
                msg = json.loads(proc.stderr).get('error', proc.stderr)
            except (ValueError, AttributeError):
                msg = proc.stderr.strip() or proc.stdout.strip()
            raise ValueError(str(msg) or f'{backend} exited {proc.returncode}')
        result = json.loads(proc.stdout)
        if not isinstance(result, dict):
            raise ValueError('子包返回格式无效')
        return result
    except (OSError, json.JSONDecodeError) as e:
        raise ValueError(f'{backend} 子包调用失败: {e}') from e


def file_sha(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def selection(values):
    result = []
    for value in values:
        backend, sep, sid = value.partition(':')
        if not sep or not backend or not sid:
            raise ValueError('会话必须使用 BACKEND:ID 格式')
        if backend not in BACKENDS:
            raise ValueError('不支持的后端: ' + backend)
        if (backend, sid) in result:
            raise ValueError('重复会话: ' + value)
        result.append((backend, sid))
    return result


def homes(values):
    result = {}
    for backend, path in values:
        if backend not in BACKENDS or backend in result:
            raise ValueError('不支持或重复的后端目录: ' + backend)
        result[backend] = str(Path(path).expanduser().resolve())
    return result


def options(a, backend):
    result = []
    for b, sid in selection(a.active_session):
        if b == backend:
            result.extend(['--active-id', sid])
    for old, new in a.map:
        result.extend(['--map', old, new])
    return result


def export(a, paths):
    sessions = selection(a.session)
    if not sessions:
        raise ValueError('至少选择一个会话')
    output = Path(a.output).expanduser().absolute()
    if output.exists() or output.is_symlink():
        raise ValueError('输出文件已存在')
    groups = {}
    for backend, sid in sessions:
        groups.setdefault(backend, []).append(sid)
    with tempfile.TemporaryDirectory() as tmp:
        packages, results = {}, {}
        for backend, ids in groups.items():
            if backend not in paths:
                raise ValueError('缺少后端目录: ' + backend)
            package = Path(tmp) / (backend + '.zip')
            args = ['export', '--home', paths[backend], '--output', str(package)]
            for sid in ids:
                args.extend(['--id', sid])
            results[backend] = invoke(backend, args)
            if package.stat().st_size > LIMIT:
                raise ValueError('子包超过大小限制')
            packages[backend] = package
        if sum(p.stat().st_size for p in packages.values()) > TOTAL:
            raise ValueError('归档超过大小限制')
        output.parent.mkdir(parents=True, exist_ok=True)
        fd, stage = tempfile.mkstemp(prefix='.agent-dash-', dir=output.parent)
        try:
            with os.fdopen(fd, 'w+b') as f:
                with zipfile.ZipFile(f, 'w', compression=zipfile.ZIP_STORED) as z:
                    manifest = {'format': 'agent-dash-sessions', 'version': 1, 'packages': []}
                    for backend, package in packages.items():
                        member = 'packages/' + backend + '.zip'
                        manifest['packages'].append({'backend': backend, 'member': member, 'size': package.stat().st_size, 'sha256': file_sha(package)})
                        with package.open('rb') as source, z.open(member, 'w', force_zip64=True) as target:
                            shutil.copyfileobj(source, target, 1024 * 1024)
                    z.writestr('manifest.json', canonical(manifest))
                f.flush()
                os.fsync(f.fileno())
            with read_archive(stage) as validated:
                if set(validated) != set(packages):
                    raise ValueError('导出归档校验失败')
            os.link(stage, output)
        finally:
            os.unlink(stage)
    return {'output': str(output), 'count': len(sessions), 'backends': results}


@contextmanager
def read_archive(path):
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        names = [i.filename for i in infos]
        if len(infos) > 10001 or len(names) != len(set(names)) or 'manifest.json' not in names:
            raise ValueError('无效归档目录')
        if any(i.is_dir() or i.flag_bits & 1 or i.file_size > LIMIT or (i.file_size and not i.compress_size) or i.file_size > 1000 * max(i.compress_size, 1) for i in infos) or sum(i.file_size for i in infos) > TOTAL:
            raise ValueError('归档超过安全限制')
        if z.getinfo('manifest.json').file_size > MANIFEST_LIMIT:
            raise ValueError('归档清单超过大小限制')
        manifest = json.loads(z.read('manifest.json'))
        if not isinstance(manifest, dict):
            raise ValueError('无效归档清单')
        native = {'agent-dash-codex': 'codex', 'agent-dash-pi': 'pi', 'agent-dash-dsh': 'dsh', 'agent-dash-hermes': 'hermes'}
        if manifest.get('format') in native and manifest.get('version') == 1:
            if Path(path).stat().st_size > LIMIT:
                raise ValueError('子包超过大小限制')
            yield {native[manifest['format']]: Path(path)}
            return
        if manifest.get('format') != 'agent-dash-sessions' or manifest.get('version') != 1 or not isinstance(manifest.get('packages'), list) or not manifest['packages']:
            raise ValueError('不支持的归档格式')
        with tempfile.TemporaryDirectory() as tmp:
            used, packages = {'manifest.json'}, {}
            for item in manifest['packages']:
                backend = item['backend']
                if backend not in BACKENDS:
                    raise ValueError('不支持的后端: ' + str(backend))
                member = 'packages/' + backend + '.zip'
                if backend in packages or item['member'] != member or member not in names:
                    raise ValueError('无效或重复的子包')
                package = Path(tmp) / (backend + '.zip')
                with z.open(member) as source, package.open('wb') as target:
                    shutil.copyfileobj(source, target, 1024 * 1024)
                if package.stat().st_size != item['size'] or file_sha(package) != item['sha256']:
                    raise ValueError('子包校验失败: ' + backend)
                packages[backend] = package
                used.add(member)
            if used != set(names):
                raise ValueError('归档含未知成员')
            yield packages


def encode(obj):
    return base64.urlsafe_b64encode(canonical(obj)).decode()


def decode(token):
    try:
        value = json.loads(base64.b64decode(token, altchars=b'-_', validate=True))
        if not isinstance(value, dict):
            raise ValueError()
        return value
    except (ValueError, TypeError) as e:
        raise ValueError('无效预览令牌') from e


def execute(a, paths):
    with read_archive(a.input) as packages:
        return execute_packages(a, paths, packages)


def execute_packages(a, paths, packages):
    config = {'packages': {b: file_sha(path) for b, path in packages.items()}, 'homes': paths, 'active': a.active_session, 'map': a.map}
    tokens = {}
    if a.command == 'import':
        saved = decode(a.preview_token)
        if saved.get('config') != config or not isinstance(saved.get('tokens'), dict):
            raise ValueError('预览已失效，请重新预览')
        tokens = saved['tokens']
    results, errors, sessions = {}, {}, []
    for backend, package in packages.items():
        try:
            if backend not in paths:
                raise ValueError('缺少后端目录: ' + backend)
            if a.command == 'import' and backend not in tokens:
                raise ValueError('该后端没有成功的预览，请重新预览')
            args = [a.command, '--home', paths[backend], '--input', str(package), *options(a, backend)]
            if a.command == 'import':
                args.extend(['--preview-token', tokens[backend]])
            result = invoke(backend, args)
            if a.command == 'preview':
                tokens[backend] = result['preview_token']
            results[backend] = result
            sessions.extend({**item, 'backend': backend} for item in result['sessions'])
        except (ValueError, KeyError, TypeError) as e:
            errors[backend] = str(e)
    return {'preview_token': encode({'config': config, 'tokens': tokens}), 'sessions': sessions, 'backends': results, 'errors': errors, 'affected_backends': list(results) if a.command == 'import' else []}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    inspect = commands.add_parser('inspect')
    inspect.add_argument('--input', required=True)
    exp = commands.add_parser('export')
    exp.add_argument('--output', required=True)
    exp.add_argument('--session', action='append', default=[])
    for name in ('preview', 'import'):
        p = commands.add_parser(name)
        p.add_argument('--input', required=True)
        p.add_argument('--active-session', action='append', default=[])
        p.add_argument('--map', nargs=2, action='append', default=[])
        if name == 'import':
            p.add_argument('--preview-token', required=True)
    for p in (exp, *[commands.choices[x] for x in ('preview', 'import')]):
        p.add_argument('--home', nargs=2, action='append', default=[])
    a = parser.parse_args()
    if a.command == 'inspect':
        with read_archive(a.input) as packages:
            directories = set()
            for backend, path in packages.items():
                reader = importlib.import_module(Path(BACKENDS[backend][1]).stem)
                try:
                    for value in reader.project_dirs(path):
                        if absolute_source(value):
                            directories.add(value)
                except (ValueError, KeyError, TypeError, AttributeError, zipfile.BadZipFile) as error:
                    raise ValueError(f'{backend} 子包的目录元数据无效') from error
            return {'backends': list(packages), 'project_dirs': sorted(directories)}
    paths = homes(a.home)
    return export(a, paths) if a.command == 'export' else execute(a, paths)


if __name__ == '__main__':
    try:
        result = main()
        print(json.dumps(result, ensure_ascii=False))
        sys.exit(1 if result.get('errors') else 0)
    except (ValueError, KeyError, TypeError, OSError, zipfile.BadZipFile, json.JSONDecodeError) as e:
        print(json.dumps({'error': str(e)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
