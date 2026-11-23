import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'agent-dash-pi-backup.py'


def run(*args, ok=True):
    p = subprocess.run(['python3', str(SCRIPT), *map(str, args)], text=True, capture_output=True)
    if ok and p.returncode:
        raise AssertionError(p.stderr)
    if not ok:
        assert p.returncode, p.stdout
    return json.loads(p.stdout if ok else p.stderr)


def session(home, dirname, filename, sid, cwd, parent=None):
    path = home / dirname / filename
    path.parent.mkdir(parents=True, exist_ok=True)
    h = {'type': 'session', 'version': 3, 'id': sid, 'timestamp': '2025-01-01T00:00:00Z', 'cwd': str(cwd)}
    if parent:
        h['parentSession'] = str(parent)
    path.write_text(json.dumps(h) + '\n' + json.dumps({'type': 'message', 'id': 'a', 'parentId': None, 'timestamp': h['timestamp'], 'message': {'role': 'user', 'content': [{'type': 'text', 'text': 'original'}], 'timestamp': 1}}) + '\n')
    return path


class PiBackup(unittest.TestCase):
    def test_tree_mapping_tokens_overwrite_rollback(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            old, new = root / 'source', root / 'target'
            old.mkdir(); new.mkdir()
            cwd, mapped = root / 'old-project', root / 'new-project'
            cwd.mkdir(); mapped.mkdir()
            parent = session(old, '--old--', 'old.jsonl', 'legacy-id', cwd)
            child = session(old, '--old--', 'child.jsonl', 'branch', cwd, '/other/machine/old.jsonl')
            package = root / 'backup.zip'
            self.assertEqual(run('export', '--home', old, '--output', package, '--id', 'branch')['count'], 2)
            args = ['--home', new, '--input', package, '--map', cwd, mapped]
            preview = run('preview', *args)
            self.assertEqual([x['action'] for x in preview['sessions']], ['create', 'create'])
            report = run('import', *args, '--preview-token', preview['preview_token'])
            targets = {x['id']: Path(x['path']) for x in report['sessions']}
            h = json.loads(targets['branch'].read_text().splitlines()[0])
            self.assertEqual(h['parentSession'], str(targets['legacy-id']))
            self.assertEqual(h['cwd'], str(mapped))
            self.assertEqual([x['action'] for x in run('preview', *args)['sessions']], ['skip', 'skip'])
            with targets['branch'].open('a') as f:
                f.write(json.dumps({'type': 'custom', 'id': 'b', 'parentId': 'a', 'timestamp': '2025-01-01T00:00:00Z', 'customType': 'fixture', 'data': 'continued'}) + '\n')
            preview = run('preview', *args)
            self.assertEqual(preview['sessions'][1]['action'], 'overwrite')
            busy = run('preview', *args, '--active-id', 'branch')
            self.assertEqual(busy['sessions'][1]['action'], 'busy')
            run('import', *args, '--preview-token', busy['preview_token'], ok=False)
            report = run('import', *args, '--preview-token', preview['preview_token'])
            self.assertTrue(Path(report['rollback_path']).is_dir())
            self.assertIsNotNone(report['rollback_archive_path'])
            restore_args = ['--home', new, '--input', report['rollback_archive_path']]
            restore = run('preview', *restore_args)
            run('import', *restore_args, '--preview-token', restore['preview_token'])
            self.assertIn('continued', targets['branch'].read_text())
            child.write_text(child.read_text().replace('/other/machine/old.jsonl', '/missing/no.jsonl'))
            error = run('export', '--home', old, '--output', root / 'bad.zip', '--id', 'branch', ok=False)
            self.assertIn('parentSession', error['error'])

    def test_recursive_fresh_home_and_collision(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            src, dest = root / 'src', root / 'new' / 'sessions'
            session(src, '', 'one.jsonl', 'first', root)
            session(src, 'deep/legacy/tree', 'two.jsonl', 'second', root)
            session(src, 'agent-dash-backups/import-1', 'old.jsonl', 'first', root)
            package = root / 'tree.zip'
            run('export', '--home', src, '--id', 'first', '--id', 'second', '--output', package)
            args = ['--home', dest, '--input', package]
            first = run('preview', *args)
            self.assertFalse(dest.parent.exists())
            run('import', *args, '--preview-token', first['preview_token'])
            self.assertEqual([x['action'] for x in run('preview', *args)['sessions']], ['skip', 'skip'])
            path = session(dest, '', 'one.jsonl', 'unrelated', root)
            for content in [path.read_bytes(), b'damaged file\n']:
                path.write_bytes(content)
                self.assertIn('占用', run('preview', *args, ok=False)['error'])
                self.assertIn('占用', run('import', *args, '--preview-token', first['preview_token'], ok=False)['error'])
                self.assertEqual(path.read_bytes(), content)

    def test_mapping_merges_legacy_basenames_and_relinks_parent(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source, dest, project = root / 'src', root / 'dest', root / 'project'
            parent = session(source, 'legacy/a', 'same.jsonl', 'old-id', project)
            session(source, 'legacy/b', 'same.jsonl', 'branch-id', project, parent)
            package = root / 'p.zip'
            run('export', '--home', source, '--id', 'branch-id', '--output', package)
            args = ['--home', dest, '--input', package, '--map', project, root / 'mapped']
            first = run('preview', *args)
            paths = {row['id']: Path(row['path']) for row in first['sessions']}
            self.assertEqual(paths['old-id'].name, 'restored_old-id.jsonl')
            self.assertEqual(paths['branch-id'].name, 'restored_branch-id.jsonl')
            run('import', *args, '--preview-token', first['preview_token'])
            with paths['branch-id'].open() as stream:
                header = json.loads(stream.readline())
            self.assertEqual(header['id'], 'branch-id')
            self.assertEqual(header['parentSession'], str(paths['old-id']))
            self.assertEqual([row['action'] for row in run('preview', *args)['sessions']], ['skip', 'skip'])

    def test_concurrent_imports_recheck_after_lock(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            dest = root / 'dest'
            dest.mkdir()
            jobs = []
            fd = os.open(dest, os.O_RDONLY | os.O_DIRECTORY)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                for label in ['A', 'B']:
                    src = root / label
                    path = session(src, 'deep/nested', 'x.jsonl', 'same-id', root)
                    path.write_text(path.read_text().replace('original', label))
                    package = root / (label + '.zip')
                    run('export', '--home', src, '--id', 'same-id', '--output', package)
                    args = ['--home', str(dest), '--input', str(package)]
                    token = run('preview', *args)['preview_token']
                    jobs.append(subprocess.Popen(['python3', str(SCRIPT), 'import', *args, '--preview-token', token], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE))
                self.assertFalse((dest / 'deep').exists())
            finally:
                os.close(fd)
            outcomes = [p.communicate(timeout=10) for p in jobs]
            self.assertEqual(sorted(p.returncode for p in jobs), [0, 1], outcomes)
            winner = next(i for i, p in enumerate(jobs) if not p.returncode)
            self.assertIn('预览已失效', outcomes[1 - winner][1])
            self.assertEqual((dest / 'deep/nested/x.jsonl').read_bytes(), (root / ['A', 'B'][winner] / 'deep/nested/x.jsonl').read_bytes())

    def test_real_pi_session_manager_offline_append(self):
        pi = shutil.which('pi')
        node = shutil.which('node')
        if not pi or not node:
            self.skipTest('Pi 或 Node 不可用')
        source = Path(os.path.realpath(pi)).parents[1] / 'core' / 'session-manager.js'
        if not source.is_file():
            self.skipTest('Pi SessionManager 源码不可用')
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            old, new, project = root / 'source', root / 'target', root / 'project'
            old.mkdir(); new.mkdir(); project.mkdir()
            path = session(old, '--project--', 'legacy.jsonl', 'legacy-id', project)
            package = root / 'p.zip'
            run('export', '--home', old, '--output', package, '--id', 'legacy-id')
            args = ['--home', new, '--input', package]
            plan = run('preview', *args)
            target = Path(run('import', *args, '--preview-token', plan['preview_token'])['sessions'][0]['path'])
            code = """import {SessionManager} from process.argv[1];
const s=SessionManager.open(process.argv[2]);
if(s.getSessionId()!=='legacy-id' || !JSON.stringify(s.getEntries()).includes('original')) throw Error('restore');
s.appendMessage({role:'user',content:[{type:'text',text:'offline-continued'}],timestamp:Date.now()});
const reopened=SessionManager.open(process.argv[2]);
if(!JSON.stringify(reopened.getEntries()).includes('offline-continued')) throw Error('append');
"""
            # Node imports require a literal module specifier.
            code = code.replace('from process.argv[1]', 'from ' + json.dumps(source.as_uri())).replace('process.argv[2]', 'process.argv[1]')
            env = {'HOME': str(root), 'PI_CODING_AGENT_DIR': str(root / 'profile'), 'PI_OFFLINE': '1', 'PATH': os.environ['PATH']}
            p = subprocess.run([node, '--input-type=module', '-e', code, str(target)], cwd=project, env=env, text=True, capture_output=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn('offline-continued', target.read_text())


if __name__ == '__main__':
    unittest.main()
