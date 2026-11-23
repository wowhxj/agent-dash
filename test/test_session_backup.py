import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'agent-dash-session-backup.py'
SID = '01234567-89ab-7cde-8fab-0123456789ab'
REL = 'sessions/rollout-' + SID + '.jsonl'


class SessionBackupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.src = self.root / 'src'
        self.dst = self.root / 'dst'
        self.archive = self.root / 'backup.zip'
        for home in (self.src, self.dst):
            home.mkdir()
            con = sqlite3.connect(home / 'state_5.sqlite')
            con.execute('CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL)')
            con.close()
        path = self.src / REL
        path.parent.mkdir()
        path.write_text(json.dumps({'type': 'session_meta', 'payload': {'id': SID, 'cwd': '/old'}}) + '\n')
        con = sqlite3.connect(self.src / 'state_5.sqlite')
        con.execute('INSERT INTO threads VALUES (?, ?, ?, ?)', (SID, str(path), '/old', 'title'))
        con.commit()
        con.close()

    def tearDown(self):
        self.tmp.cleanup()

    def cli(self, *args, success=True):
        proc = subprocess.run([sys.executable, str(SCRIPT), *map(str, args)], capture_output=True, text=True)
        self.assertEqual(proc.returncode == 0, success, proc.stderr + proc.stdout)
        return json.loads(proc.stdout or proc.stderr)

    def export(self):
        return self.cli('export', '--home', 'codex', self.src, '--session', 'codex:' + SID, '--output', self.archive)

    def preview(self):
        return self.cli('preview', '--home', 'codex', self.dst, '--input', self.archive)

    def test_cli_export_preview_import_and_legacy(self):
        self.export()
        preview = self.preview()
        self.assertEqual((preview['sessions'][0]['backend'], preview['sessions'][0]['action']), ('codex', 'create'))
        result = self.cli('import', '--home', 'codex', self.dst, '--input', self.archive, '--preview-token', preview['preview_token'])
        self.assertTrue(result['backends']['codex']['rollback_path'])
        self.assertEqual((self.dst / REL).read_bytes(), (self.src / REL).read_bytes())
        self.assertEqual(self.preview()['sessions'][0]['action'], 'skip')
        legacy = self.root / 'legacy.zip'
        subprocess.run([sys.executable, str(ROOT / 'agent-dash-backup.py'), 'export', '--home', str(self.src), '--id', SID, '--output', str(legacy)], check=True, capture_output=True)
        self.assertEqual(self.cli('preview', '--home', 'codex', self.dst, '--input', legacy)['sessions'][0]['action'], 'skip')

    def test_codex_and_pi_same_id(self):
        pi_src, pi_dst = self.root / 'pi-src', self.root / 'pi-dst'
        pi_src.mkdir()
        pi_dst.mkdir()
        source = pi_src / 'project' / 'session.jsonl'
        source.parent.mkdir()
        source.write_text(json.dumps({'type': 'session', 'id': SID, 'cwd': '/old'}) + '\n')
        homes = ['--home', 'codex', self.src, '--home', 'pi', pi_src]
        self.cli('export', *homes, '--session', 'codex:' + SID, '--session', 'pi:' + SID, '--output', self.archive)
        homes = ['--home', 'codex', self.dst, '--home', 'pi', pi_dst]
        preview = self.cli('preview', *homes, '--input', self.archive)
        self.assertEqual({(s['backend'], s['id'], s['action']) for s in preview['sessions']}, {('codex', SID, 'create'), ('pi', SID, 'create')})
        inspection = self.cli('inspect', '--input', self.archive)
        self.assertEqual(set(inspection['backends']), {'codex', 'pi'})
        self.assertEqual(inspection['project_dirs'], ['/old'])
        with zipfile.ZipFile(self.archive) as z:
            raw_pi = self.root / 'pi-native.zip'
            raw_pi.write_bytes(z.read('packages/pi.zip'))
        inspection = self.cli('inspect', '--input', raw_pi)
        self.assertEqual(inspection['backends'], ['pi'])
        self.assertEqual(inspection['project_dirs'], ['/old'])
        self.cli('import', *homes, '--input', self.archive, '--preview-token', preview['preview_token'])
        self.assertEqual({s['action'] for s in self.cli('preview', *homes, '--input', self.archive)['sessions']}, {'skip'})

    def test_map_windows_project_to_existing_local_directory(self):
        old = r'C:\work\project'
        path = self.src / REL
        path.write_text(json.dumps({'type': 'session_meta', 'payload': {'id': SID, 'cwd': old}}) + '\n')
        with sqlite3.connect(self.src / 'state_5.sqlite') as db:
            db.execute('UPDATE threads SET cwd=? WHERE id=?', (old, SID))
        self.export()
        self.assertEqual(self.cli('inspect', '--input', self.archive)['project_dirs'], [old])
        project = self.root / 'project'
        project.mkdir()
        args = ['--home', 'codex', self.dst, '--input', self.archive, '--map', old, project]
        preview = self.cli('preview', *args)
        self.cli('import', *args, '--preview-token', preview['preview_token'])
        record = json.loads((self.dst / REL).read_text())
        self.assertEqual(record['payload']['cwd'], str(project))
        with sqlite3.connect(self.dst / 'state_5.sqlite') as db:
            self.assertEqual(db.execute('SELECT cwd FROM threads').fetchone(), (str(project),))

    def test_hermes_native_and_mixed_routing(self):
        source, target = self.root / 'hermes-src', self.root / 'hermes-dst'
        for home in (source, target):
            home.mkdir()
            with sqlite3.connect(home / 'state.db') as con:
                con.execute('CREATE TABLE sessions(id TEXT PRIMARY KEY, parent_session_id TEXT, system_prompt_hash TEXT, cwd TEXT, git_repo_root TEXT)')
                con.execute('CREATE TABLE messages(id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT)')
                con.execute('CREATE TABLE system_prompts(hash TEXT PRIMARY KEY, prompt TEXT)')
                con.execute('CREATE TABLE session_model_usage(session_id TEXT, model TEXT)')
        with sqlite3.connect(source / 'state.db') as con:
            con.execute('INSERT INTO sessions VALUES (?, NULL, NULL, ?, ?)', (SID, '/old', '/old'))
        self.cli('export', '--home', 'codex', self.src, '--home', 'hermes', source,
                 '--session', 'codex:' + SID, '--session', 'hermes:' + SID, '--output', self.archive)
        self.assertEqual(set(self.cli('inspect', '--input', self.archive)['backends']), {'codex', 'hermes'})
        native = self.root / 'hermes.zip'
        with zipfile.ZipFile(self.archive) as z:
            native.write_bytes(z.read('packages/hermes.zip'))
        inspection = self.cli('inspect', '--input', native)
        self.assertEqual(inspection['backends'], ['hermes'])
        self.assertEqual(inspection['project_dirs'], ['/old'])
        homes = ['--home', 'codex', self.dst, '--home', 'hermes', target]
        preview = self.cli('preview', *homes, '--input', self.archive, '--active-session', 'hermes:' + SID)
        self.assertEqual({(s['backend'], s['action']) for s in preview['sessions']}, {('codex', 'create'), ('hermes', 'busy')})
        preview = self.cli('preview', *homes, '--input', self.archive)
        self.cli('import', *homes, '--input', self.archive, '--preview-token', preview['preview_token'])
        self.assertEqual({s['action'] for s in self.cli('preview', *homes, '--input', self.archive)['sessions']}, {'skip'})

    def test_failed_export_never_publishes(self):
        self.cli('export', '--home', 'codex', self.src, '--session', 'codex:' + SID, '--session', 'pi:missing', '--output', self.archive, success=False)
        self.assertFalse(self.archive.exists())

    def test_partial_failure_and_retry(self):
        self.export()
        with zipfile.ZipFile(self.archive) as z:
            files = {name: z.read(name) for name in z.namelist()}
        manifest = json.loads(files['manifest.json'])
        import hashlib
        data = b'not a zip'
        manifest['packages'].append({'backend': 'pi', 'member': 'packages/pi.zip', 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
        files['manifest.json'] = json.dumps(manifest).encode()
        files['packages/pi.zip'] = data
        with zipfile.ZipFile(self.archive, 'w') as z:
            for name, content in files.items():
                z.writestr(name, content)
        preview = self.cli('preview', '--home', 'codex', self.dst, '--input', self.archive, success=False)
        self.assertIn('pi', preview['errors'])
        result = self.cli('import', '--home', 'codex', self.dst, '--input', self.archive, '--preview-token', preview['preview_token'], success=False)
        self.assertIn('pi', result['errors'])
        self.assertEqual(result['affected_backends'], ['codex'])
        retry = self.cli('preview', '--home', 'codex', self.dst, '--input', self.archive, success=False)
        self.assertEqual(retry['sessions'][0]['action'], 'skip')

    def test_zip_boundary(self):
        self.export()
        with zipfile.ZipFile(self.archive, 'a') as z:
            z.writestr('../outside', 'bad')
        error = self.cli('preview', '--home', 'codex', self.dst, '--input', self.archive, success=False)
        self.assertIn('error', error)
        self.assertFalse((self.root / 'outside').exists())


if __name__ == '__main__':
    unittest.main()
