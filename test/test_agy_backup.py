from contextlib import closing
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

MODULE = Path(__file__).resolve().parents[1] / 'agent-dash-agy-backup.py'
SPEC = importlib.util.spec_from_file_location('agy_backup', MODULE)
backup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backup)
SID = '00000000-0000-4000-8000-000000000001'


class AgyBackupTest(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        root = Path(work.name)
        self.src = root / 'source'
        self.dest = root / 'destination'
        self.dest.mkdir()
        self.archive = root / 'archive.zip'
        self.dbname = f'conversations/{SID}.db'
        dbpath = self.src / self.dbname
        dbpath.parent.mkdir(parents=True)
        writer = sqlite3.connect(dbpath)
        self.addCleanup(writer.close)
        writer.executescript('pragma journal_mode=wal; pragma wal_autocheckpoint=0; '
                             'pragma user_version=1; create table trajectory_meta(cascade_id text);')
        writer.execute('insert into trajectory_meta values (?)', (SID,))
        writer.commit()
        self.assertTrue(Path(str(dbpath) + '-wal').is_file())
        with closing(sqlite3.connect(self.src / 'conversation_summaries.db')) as index:
            index.execute('create table conversation_summaries(conversation_id text, workspace_uris text)')
            index.execute('insert into conversation_summaries values (?,?)', (SID, json.dumps(['file:///example/project%20with%20spaces'])))
            index.commit()
        self.files = {f'annotations/{SID}.pbtxt': b'fixture annotation',
                      f'brain/{SID}/nested/artifact': b'fixture artifact'}
        for rel, data in self.files.items():
            path = self.src / rel
            path.parent.mkdir(parents=True)
            path.write_bytes(data)
        backup.export(self.src, [SID], self.archive)

    def plan(self, **kwargs):
        a = SimpleNamespace(home=self.dest, input=self.archive, map=[], active_id=[], command='preview')
        vars(a).update(kwargs)
        return backup.restore(a)

    def install(self, token):
        return self.plan(command='import', preview_token=token)

    def test_snapshot_preserves_wal_and_sidecars_without_replacing_index(self):
        self.assertEqual(list(backup.project_dirs(self.archive)), ['/example/project with spaces'])
        plan = self.plan()
        self.assertEqual(plan['sessions'][0]['action'], 'create')
        self.assertEqual(list(self.dest.iterdir()), [])
        self.install(plan['preview_token'])
        for rel, data in self.files.items():
            self.assertEqual((self.dest / rel).read_bytes(), data)
        with closing(sqlite3.connect(self.dest / self.dbname)) as db:
            self.assertEqual(db.execute('select cascade_id from trajectory_meta').fetchone(), (SID,))
        self.assertFalse((self.dest / 'conversation_summaries.db').exists())
        self.assertEqual(self.plan()['sessions'][0]['action'], 'skip')
        (self.dest / self.dbname).write_bytes(b'different')
        self.assertEqual(self.plan()['sessions'][0]['action'], 'conflict')

    def test_existing_target_invalidates_preview_and_active_id_is_busy(self):
        plan = self.plan()
        self.assertEqual(self.plan(active_id=[SID])['sessions'][0]['action'], 'busy')
        target = self.dest / self.dbname
        target.parent.mkdir()
        target.write_bytes(b'existing database')
        with self.assertRaisesRegex(ValueError, '预览已失效'):
            self.install(plan['preview_token'])
        self.assertEqual(target.read_bytes(), b'existing database')

    def test_move_and_traversal_are_rejected(self):
        with self.assertRaisesRegex(ValueError, '改写'):
            self.plan(map=[('/example', '/another')])
        self.assertEqual(self.plan(map=[('/unrelated', '/another')])['sessions'][0]['action'], 'create')
        copied = {}
        with zipfile.ZipFile(self.archive) as source:
            for name in source.namelist():
                copied[name] = source.read(name)
        manifest = json.loads(copied['manifest.json'])
        name = f'brain/{SID}/../../outside'
        copied[name] = data = b'fixture'
        manifest['files'][name] = backup.digest(data)
        copied['manifest.json'] = backup.canonical(manifest)
        with zipfile.ZipFile(self.archive, 'w') as target:
            for name, value in copied.items():
                target.writestr(name, value)
        with self.assertRaisesRegex(ValueError, '无效归档路径'):
            self.plan()

    def test_retire_is_verified_and_recoverable_with_a_stale_index_row(self):
        self.install(self.plan()['preview_token'])
        other = self.dest / self.dbname.replace(SID, 'other')
        other.write_bytes(b'unrelated')
        index_path = self.dest / 'conversation_summaries.db'
        with closing(sqlite3.connect(index_path)) as index:
            index.execute('create table conversation_summaries(conversation_id text)')
            index.execute('insert into conversation_summaries values (?)', (SID,))
            index.commit()
        changed = self.dest / f'annotations/{SID}.pbtxt'
        changed.write_bytes(b'changed after export')
        # Take the same kind of backup as the migration command, in the destination profile.
        native = self.dest.parent / 'native.zip'
        with closing(sqlite3.connect(index_path)) as index:
            index.execute('alter table conversation_summaries add column workspace_uris text')
            index.commit()
        backup.export(self.dest, [SID], native)
        changed.write_bytes(b'changed again')
        with self.assertRaisesRegex(ValueError, '源会话已变化'):
            backup.retire(self.dest, SID, native)
        self.assertTrue((self.dest / self.dbname).is_file())
        changed.write_bytes(b'changed after export')
        moved = Path(backup.retire(self.dest, SID, native)['holding'])
        self.assertFalse((self.dest / self.dbname).exists())
        self.assertTrue((moved / self.dbname).is_file())
        self.assertEqual(other.read_bytes(), b'unrelated')
        self.assertEqual(self.plan()['sessions'][0]['action'], 'conflict')
        plan = self.plan(input=native)
        self.assertEqual(plan['sessions'][0]['action'], 'create')
        self.plan(input=native, command='import', preview_token=plan['preview_token'])
        self.assertEqual(changed.read_bytes(), b'changed after export')

    def test_install_rollback_with_racing_target(self):
        plan = self.plan()
        real_link = backup.os.link

        def race(source, target):
            if target.suffix == '.db':
                target.write_bytes(b'existing database')
            return real_link(source, target)

        with patch.object(backup.os, 'link', side_effect=race):
            with self.assertRaises(FileExistsError):
                self.install(plan['preview_token'])
        self.assertEqual((self.dest / self.dbname).read_bytes(), b'existing database')
        self.assertFalse((self.dest / 'brain' / SID).exists())
        self.assertFalse((self.dest / 'annotations' / f'{SID}.pbtxt').exists())


if __name__ == '__main__':
    unittest.main()
