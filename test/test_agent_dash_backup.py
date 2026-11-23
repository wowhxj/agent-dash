import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'agent-dash-backup.py'
SID = '01234567-89ab-7cde-8fab-0123456789ab'
REL = 'sessions/2026/01/02/rollout-2026-01-02T00-00-00-' + SID + '.jsonl'


class BackupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.src = self.root / 'source'
        self.dst = self.root / 'target'
        self.zip = self.root / 'backup.zip'
        for home in (self.src, self.dst):
            home.mkdir()
            con = sqlite3.connect(home / 'state_5.sqlite')
            con.executescript('CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL); CREATE TABLE thread_dynamic_tools(thread_id TEXT NOT NULL, position INTEGER, name TEXT);')
            con.close()
        path = self.src / REL
        path.parent.mkdir(parents=True)
        path.write_text('{"type":"session_meta","payload":{"id":"' + SID + '","cwd":"/old","runtime_workspace_roots":["/old"]}}\n' + '{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"cwd":"/old","runtime_workspace_roots":["/old"]}}}\n')
        con = sqlite3.connect(self.src / 'state_5.sqlite')
        con.execute('INSERT INTO threads VALUES (?, ?, ?, ?)', (SID, str(path), '/old', 'title'))
        con.execute('INSERT INTO thread_dynamic_tools VALUES (?, ?, ?)', (SID, 0, 'test'))
        con.commit()
        con.close()

    def tearDown(self):
        self.temp.cleanup()

    def cli(self, *args, ok=True):
        result = subprocess.run([sys.executable, str(SCRIPT), *map(str, args)], text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0)
        return json.loads(result.stderr)

    def export(self):
        return self.cli('export', '--home', self.src, '--output', self.zip, '--id', SID)

    def preview(self, *extra):
        return self.cli('preview', '--home', self.dst, '--input', self.zip, *extra)

    def test_create_skip_and_stale_preview(self):
        self.export()
        preview = self.preview()
        self.assertEqual(preview['sessions'][0]['action'], 'create')
        self.cli('import', '--home', self.dst, '--input', self.zip, '--preview-token', preview['preview_token'])
        self.assertEqual((self.dst / REL).read_bytes(), (self.src / REL).read_bytes())
        self.assertEqual(self.preview()['sessions'][0]['action'], 'skip')
        (self.dst / REL).write_text('changed')
        self.cli('import', '--home', self.dst, '--input', self.zip, '--preview-token', preview['preview_token'], ok=False)
        preview = self.preview()
        self.assertEqual(preview['sessions'][0]['action'], 'overwrite')
        result = self.cli('import', '--home', self.dst, '--input', self.zip, '--preview-token', preview['preview_token'])
        self.assertEqual((Path(result['rollback_path']) / '0.jsonl').read_text(), 'changed')

    def test_active_and_map_token(self):
        self.export()
        preview = self.preview('--active-id', SID, '--map', '/old', '/new')
        self.assertEqual(preview['sessions'][0]['action'], 'busy')
        result = self.cli('import', '--home', self.dst, '--input', self.zip, '--preview-token', preview['preview_token'], '--active-id', SID, '--map', '/old', '/new')
        self.assertEqual(result['sessions'][0]['action'], 'busy')
        self.assertFalse((self.dst / REL).exists())
        self.cli('import', '--home', self.dst, '--input', self.zip, '--preview-token', preview['preview_token'], ok=False)
        preview = self.preview('--map', '/old', '/new')
        self.cli('import', '--home', self.dst, '--input', self.zip, '--preview-token', preview['preview_token'], '--map', '/old', '/new')
        first, second = [json.loads(line) for line in (self.dst / REL).read_text().splitlines()]
        self.assertEqual(first['payload']['cwd'], '/new')
        self.assertEqual(first['payload']['runtime_workspace_roots'], ['/new'])
        self.assertEqual(second['payload']['thread_settings']['cwd'], '/new')
        self.assertEqual(second['payload']['thread_settings']['runtime_workspace_roots'], ['/new'])
        self.assertEqual(self.preview('--map', '/old', '/new')['sessions'][0]['action'], 'skip')

    def test_legacy_deflated_archive(self):
        self.export()
        with zipfile.ZipFile(self.zip) as z:
            contents = [(name, z.read(name)) for name in z.namelist()]
        with zipfile.ZipFile(self.zip, 'w', compression=zipfile.ZIP_DEFLATED) as z:
            for name, data in contents:
                z.writestr(name, data)
        preview = self.preview('--map', '/old', '/new')
        self.cli('import', '--home', self.dst, '--input', self.zip, '--map', '/old', '/new', '--preview-token', preview['preview_token'])
        self.assertEqual(self.preview('--map', '/old', '/new')['sessions'][0]['action'], 'skip')

    def test_reject_unexpected_member(self):
        self.export()
        with zipfile.ZipFile(self.zip, 'a') as z:
            z.writestr('../outside', 'x')
        self.cli('preview', '--home', self.dst, '--input', self.zip, ok=False)
        self.assertFalse((self.root / 'outside').exists())

    def test_busy_session_does_not_block_other_session(self):
        sid2 = '12345678-9abc-7def-8abc-123456789abc'
        rel2 = REL.replace(SID, sid2)
        path2 = self.src / rel2
        path2.write_text((self.src / REL).read_text().replace(SID, sid2))
        con = sqlite3.connect(self.src / 'state_5.sqlite')
        con.execute('INSERT INTO threads VALUES (?, ?, ?, ?)', (sid2, str(path2), '/old', 'other'))
        con.commit()
        con.close()
        self.cli('export', '--home', self.src, '--output', self.zip, '--id', SID, '--id', sid2)
        preview = self.preview('--active-id', SID)
        self.assertEqual([x['action'] for x in preview['sessions']], ['busy', 'create'])
        self.cli('import', '--home', self.dst, '--input', self.zip, '--active-id', SID, '--preview-token', preview['preview_token'])
        self.assertFalse((self.dst / REL).exists())
        self.assertTrue((self.dst / rel2).exists())

    def test_shared_project_metadata_is_not_overwritten(self):
        for home in (self.src, self.dst):
            con = sqlite3.connect(home / 'state_5.sqlite')
            con.executescript('ALTER TABLE threads ADD COLUMN project_id TEXT; CREATE TABLE projects(id TEXT PRIMARY KEY, name TEXT); CREATE TABLE project_roots(project_id TEXT, position INTEGER, path TEXT, PRIMARY KEY(project_id, position));')
            con.execute('INSERT INTO projects VALUES (?, ?)', ('p1', 'source' if home == self.src else 'local'))
            con.execute('INSERT INTO project_roots VALUES (?, ?, ?)', ('p1', 0, '/old' if home == self.src else '/local'))
            con.execute('UPDATE threads SET project_id=?', ('p1',))
            con.commit()
            con.close()
        self.export()
        preview = self.preview('--map', '/old', '/new')
        self.cli('import', '--home', self.dst, '--input', self.zip, '--map', '/old', '/new', '--preview-token', preview['preview_token'])
        con = sqlite3.connect(self.dst / 'state_5.sqlite')
        self.assertEqual(con.execute('SELECT name FROM projects').fetchone()[0], 'local')
        self.assertEqual(con.execute('SELECT path FROM project_roots').fetchone()[0], '/local')
        self.assertEqual(con.execute('SELECT cwd FROM threads').fetchone()[0], '/new')
        con.close()

    def test_rollback_archive_can_be_reimported(self):
        self.export()
        preview = self.preview()
        self.cli('import', '--home', self.dst, '--input', self.zip, '--preview-token', preview['preview_token'])
        target = self.dst / REL
        old = target.read_bytes() + b'{"type":"event_msg","payload":{}}\n'
        target.write_bytes(old)
        preview = self.preview()
        result = self.cli('import', '--home', self.dst, '--input', self.zip, '--preview-token', preview['preview_token'])
        rollback = result['rollback_archive_path']
        self.assertTrue(rollback)
        restore = self.cli('preview', '--home', self.dst, '--input', rollback)
        self.cli('import', '--home', self.dst, '--input', rollback, '--preview-token', restore['preview_token'])
        self.assertEqual(target.read_bytes(), old)

    def test_open_rollout_is_busy(self):
        self.export()
        target = self.dst / REL
        target.parent.mkdir(parents=True)
        target.write_text('previous')
        with target.open() as handle:
            self.assertEqual(self.preview()['sessions'][0]['action'], 'busy')
            self.assertEqual(handle.read(), 'previous')

    def test_compressed_export_and_existing_path_migration(self):
        source = self.src / REL
        compressed = Path(str(source) + '.zst')
        subprocess.run(['zstd', '-q', '-o', str(compressed), str(source)], check=True)
        source.unlink()
        con = sqlite3.connect(self.src / 'state_5.sqlite')
        con.execute('UPDATE threads SET rollout_path=? WHERE id=?', (str(source), SID))
        con.commit()
        con.close()
        old = self.dst / 'archived_sessions' / source.name
        old.parent.mkdir()
        old.write_text('previous')
        con = sqlite3.connect(self.dst / 'state_5.sqlite')
        con.execute('INSERT INTO threads VALUES (?, ?, ?, ?)', (SID, str(old), '/old', 'old'))
        con.commit()
        con.close()
        self.export()
        preview = self.preview()
        self.assertEqual(preview['sessions'][0]['action'], 'overwrite')
        result = self.cli('import', '--home', self.dst, '--input', self.zip, '--preview-token', preview['preview_token'])
        self.assertFalse(old.exists())
        self.assertTrue((self.dst / REL).exists())
        journal = json.loads((Path(result['rollback_path']) / 'manifest.json').read_text())
        saved = next(x for x in journal['files'] if x['path'] == str(old))
        self.assertEqual((Path(result['rollback_path']) / saved['backup']).read_text(), 'previous')

    def test_native_fork_path_is_normalized_and_legacy_pack_restores(self):
        source = self.src / REL
        fork_rel = REL.removesuffix('.jsonl') + '_12345678-9abc-7def-8abc-123456789abc.jsonl'
        compressed = self.src / (fork_rel + '.zst')
        subprocess.run(['zstd', '-q', '-o', str(compressed), str(source)], check=True)
        source.unlink()
        with sqlite3.connect(self.src / 'state_5.sqlite') as con:
            con.execute('UPDATE threads SET rollout_path=? WHERE id=?', (str(self.src / fork_rel), SID))
        self.export()
        with zipfile.ZipFile(self.zip) as z:
            manifest = json.loads(z.read('manifest.json'))
            member = manifest['sessions'][0]['member']
            data = z.read(member)
        self.assertEqual(manifest['sessions'][0]['path'], REL)
        manifest['sessions'][0]['path'] = fork_rel
        with zipfile.ZipFile(self.zip, 'w', compression=zipfile.ZIP_DEFLATED) as z:
            z.writestr(member, data)
            z.writestr('manifest.json', json.dumps(manifest))
        preview = self.preview('--map', '/old', '/new')
        self.assertEqual(preview['sessions'][0]['path'], str(self.dst / REL))
        self.cli('import', '--home', self.dst, '--input', self.zip, '--map', '/old', '/new', '--preview-token', preview['preview_token'])
        self.assertEqual(self.preview('--map', '/old', '/new')['sessions'][0]['action'], 'skip')
        with sqlite3.connect(self.dst / 'state_5.sqlite') as con:
            self.assertEqual(con.execute('SELECT id, rollout_path, cwd FROM threads').fetchone(), (SID, str(self.dst / REL), '/new'))
        orphan = self.dst / fork_rel
        orphan.write_bytes(data)
        self.assertIn('额外 rollout', self.cli('preview', '--home', self.dst, '--input', self.zip, ok=False)['error'])

    def test_incorrect_fork_path_identity_is_refused(self):
        source = self.src / REL
        invalid = source.with_name(source.name.replace(SID, '12345678-9abc-7def-8abc-123456789abc_' + SID))
        source.rename(invalid)
        with sqlite3.connect(self.src / 'state_5.sqlite') as con:
            con.execute('UPDATE threads SET rollout_path=? WHERE id=?', (str(invalid), SID))
        error = self.cli('export', '--home', self.src, '--output', self.zip, '--id', SID, ok=False)
        self.assertIn('rollout 文件名与会话 ID 不匹配', error['error'])
        self.assertFalse(self.zip.exists())

    def test_orphan_collision_is_refused(self):
        self.export()
        orphan = self.dst / 'archived_sessions' / ('rollout-' + SID + '.jsonl')
        orphan.parent.mkdir()
        orphan.write_text('other')
        error = self.cli('preview', '--home', self.dst, '--input', self.zip, ok=False)
        self.assertIn('额外 rollout', error['error'])
        self.assertEqual(orphan.read_text(), 'other')

    def test_manifest_path_traversal_rejected(self):
        self.export()
        with zipfile.ZipFile(self.zip) as z:
            data = {name: z.read(name) for name in z.namelist()}
        manifest = json.loads(data['manifest.json'])
        manifest['sessions'][0]['path'] = 'sessions/../../outside.jsonl'
        data['manifest.json'] = json.dumps(manifest).encode()
        output = io.BytesIO()
        with zipfile.ZipFile(output, 'w') as z:
            for name, content in data.items():
                z.writestr(name, content)
        self.zip.write_bytes(output.getvalue())
        self.cli('preview', '--home', self.dst, '--input', self.zip, ok=False)
        self.assertFalse((self.root / 'outside.jsonl').exists())

    def test_failed_database_write_restores_file(self):
        con = sqlite3.connect(self.dst / 'state_5.sqlite')
        con.execute("CREATE TRIGGER reject_insert BEFORE INSERT ON threads BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        con.commit()
        con.close()
        self.export()
        target = self.dst / REL
        target.parent.mkdir(parents=True)
        target.write_text('original')
        preview = self.preview()
        error = self.cli('import', '--home', self.dst, '--input', self.zip, '--preview-token', preview['preview_token'], ok=False)
        self.assertIn('回滚快照', error['error'])
        self.assertEqual(target.read_text(), 'original')
        con = sqlite3.connect(self.dst / 'state_5.sqlite')
        self.assertEqual(con.execute('SELECT count(*) FROM threads').fetchone()[0], 0)
        con.close()

    def test_large_compressed_roundtrip_bounded_memory(self):
        source = self.src / REL
        with source.open('wb') as f:
            f.write(('{"type":"session_meta","payload":{"id":"' + SID + '","cwd":"/old"}}\n').encode())
            line = b'{"type":"event_msg","payload":{"data":"' + b'x' * (1024 * 1024) + b'"}}\n'
            for _ in range(370):
                f.write(line)
            f.write(b'{"type":"event_msg","payload":{"data":"' + b'y' * (20 * 1024 * 1024) + b'"}}\n')
        compressed = Path(str(source) + '.zst')
        subprocess.run(['zstd', '-q', '-o', str(compressed), str(source)], check=True)
        source.unlink()
        wrapper = ('import resource,runpy,sys; '
                   'sys.argv=sys.argv[1:]; runpy.run_path(sys.argv[0],run_name="__main__"); '
                   'print(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,file=sys.stderr)')
        def limited_cli(*args):
            result = subprocess.run([sys.executable, '-c', wrapper, str(SCRIPT), *map(str, args)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            rss = int(result.stderr.strip().splitlines()[-1])
            if sys.platform != 'darwin':
                rss *= 1024
            self.assertLess(rss, 256 * 1024 * 1024)
            return json.loads(result.stdout)
        limited_cli('export', '--home', self.src, '--output', self.zip, '--id', SID)
        preview = limited_cli('preview', '--home', self.dst, '--input', self.zip, '--map', '/old', '/new')
        limited_cli('import', '--home', self.dst, '--input', self.zip, '--map', '/old', '/new', '--preview-token', preview['preview_token'])
        self.assertEqual(limited_cli('preview', '--home', self.dst, '--input', self.zip, '--map', '/old', '/new')['sessions'][0]['action'], 'skip')
        with (self.dst / REL).open('rb') as f:
            self.assertEqual(json.loads(f.readline())['payload']['cwd'], '/new')
        self.assertGreater((self.dst / REL).stat().st_size, 256 * 1024 * 1024)

    def test_missing_default_input(self):
        result = subprocess.run([sys.executable, str(SCRIPT), 'export'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
