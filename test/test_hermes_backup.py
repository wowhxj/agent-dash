import json
import os
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'agent-dash-hermes-backup.py'


def run(*args, ok=True):
    p = subprocess.run(['python3', str(SCRIPT), *map(str, args)], capture_output=True, text=True)
    if ok and p.returncode:
        raise AssertionError(p.stderr)
    if not ok and not p.returncode:
        raise AssertionError(p.stdout)
    return json.loads(p.stdout if ok else p.stderr)


def database(home):
    home.mkdir()
    db = sqlite3.connect(home / 'state.db')
    db.executescript('''
        PRAGMA foreign_keys=ON;
        CREATE TABLE system_prompts(hash TEXT PRIMARY KEY, prompt TEXT NOT NULL);
        CREATE TABLE sessions(id TEXT PRIMARY KEY, parent_session_id TEXT REFERENCES sessions(id), system_prompt_hash TEXT REFERENCES system_prompts(hash), cwd TEXT, git_repo_root TEXT, model_config TEXT);
        CREATE TABLE messages(id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES sessions(id), content TEXT, display_identity BLOB);
        CREATE TABLE session_model_usage(session_id TEXT REFERENCES sessions(id), model TEXT, count INTEGER);
        CREATE TABLE session_turn_leases(conversation_id TEXT, expires_at REAL);
    ''')
    return db


class HermesBackup(unittest.TestCase):
    def test_roundtrip_branch_mapping_busy_rollback_and_isolation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src, dst = root / 'src', root / 'dst'
            a, b = database(src), database(dst)
            a.execute('INSERT INTO system_prompts VALUES (?,?)', ('hash', 'prompt'))
            a.execute('INSERT INTO sessions VALUES (?,?,?,?,?,?)', ('parent', None, 'hash', '/old/proj', '/old/proj', '{"cwd":"/old/proj"}'))
            a.execute('INSERT INTO sessions VALUES (?,?,?,?,?,?)', ('child', 'parent', 'hash', None, None, None))
            a.execute('INSERT INTO messages VALUES (?,?,?,?)', (1, 'child', 'all messages', b'\x00\xff'))
            a.execute('INSERT INTO session_model_usage VALUES (?,?,?)', ('child', 'model', 7))
            a.commit()
            b.execute('INSERT INTO sessions VALUES (?,?,?,?,?,?)', ('unrelated', None, None, None, None, None))
            b.execute('INSERT INTO messages VALUES (?,?,?,?)', (1, 'unrelated', 'keep', None))
            b.commit()
            (src / 'sessions').mkdir()
            original_file = b'{"content":"recovery only"}\r\n'
            (src / 'sessions/child.jsonl').write_bytes(original_file)
            package = root / 'archive.zip'
            self.assertEqual(run('export', '--home', src, '--id', 'child', '--output', package)['count'], 2)
            args = ['--home', dst, '--input', package, '--map', '/old', '/new']
            preview = run('preview', *args)
            self.assertEqual([r['action'] for r in preview['sessions']], ['create', 'create'])
            run('import', *args, '--preview-token', preview['preview_token'])
            self.assertEqual(b.execute('SELECT content FROM messages WHERE session_id=?', ('unrelated',)).fetchone()[0], 'keep')
            self.assertEqual(b.execute('SELECT content,display_identity FROM messages WHERE session_id=?', ('child',)).fetchone(), ('all messages', b'\x00\xff'))
            self.assertEqual(b.execute('SELECT cwd,model_config FROM sessions WHERE id=?', ('parent',)).fetchone(), ('/new/proj', '{"cwd":"/new/proj"}'))
            self.assertEqual([r['action'] for r in run('preview', *args)['sessions']], ['skip', 'skip'])
            self.assertEqual((dst / 'sessions/child.jsonl').read_bytes(), original_file)
            changed_file = b'{"content":"target recovery"}\n'
            (dst / 'sessions/child.jsonl').write_bytes(changed_file)
            b.execute('UPDATE messages SET content=? WHERE session_id=?', ('later', 'child'))
            b.commit()
            busy = run('preview', *args, '--active-id', 'child')
            self.assertEqual(busy['sessions'][0]['action'], 'busy')
            run('import', *args, '--preview-token', busy['preview_token'], ok=False)
            preview = run('preview', *args)
            result = run('import', *args, '--preview-token', preview['preview_token'])
            rollback = result['rollback_archive_path']
            self.assertTrue(Path(rollback).is_file())
            args = ['--home', dst, '--input', rollback]
            preview = run('preview', *args)
            run('import', *args, '--preview-token', preview['preview_token'])
            self.assertEqual(b.execute('SELECT content FROM messages WHERE session_id=?', ('child',)).fetchone()[0], 'later')
            self.assertEqual((dst / 'sessions/child.jsonl').read_bytes(), changed_file)
            a.close(); b.close()

    def test_native_registry_blocks_and_corruption_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src, dst = root / 'src', root / 'dst'
            a, b = database(src), database(dst)
            a.executemany('INSERT INTO sessions(id) VALUES (?)', [('x',), ('y',)])
            a.commit()
            package = root / 'a.zip'
            run('export', '--home', src, '--id', 'x', '--id', 'y', '--output', package)
            runtime = dst / 'runtime'
            runtime.mkdir()
            (runtime / 'active_sessions.lock').touch()
            state = runtime / 'active_sessions.json'
            state.write_text(json.dumps({'entries': [{'session_id': 'x', 'lease_id': 'a', 'pid': os.getpid()}]}))
            args = ['--home', dst, '--input', package]
            preview = run('preview', *args)
            self.assertEqual(preview['sessions'][0]['action'], 'busy')
            run('import', *args, '--preview-token', preview['preview_token'])
            self.assertEqual(b.execute('SELECT id FROM sessions').fetchall(), [('y',)])
            state.write_text('{broken')
            run('preview', *args, ok=False)
            a.close(); b.close()

    def test_stale_preview_and_transaction_rollback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src, dst = root / 'src', root / 'dst'
            a, b = database(src), database(dst)
            a.execute('INSERT INTO sessions(id) VALUES (?)', ('x',))
            a.execute('INSERT INTO messages(session_id,content) VALUES (?,?)', ('x', 'source'))
            a.commit()
            package = root / 'a.zip'
            run('export', '--home', src, '--id', 'x', '--output', package)
            args = ['--home', dst, '--input', package]
            token = run('preview', *args)['preview_token']
            b.execute('INSERT INTO sessions(id) VALUES (?)', ('x',))
            b.commit()
            run('import', *args, '--preview-token', token, ok=False)
            self.assertEqual(b.execute('SELECT count(*) FROM messages').fetchone()[0], 0)
            b.execute("CREATE TRIGGER reject_message BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'reject'); END")
            b.commit()
            token = run('preview', *args)['preview_token']
            run('import', *args, '--preview-token', token, ok=False)
            self.assertEqual(b.execute('SELECT count(*) FROM messages').fetchone()[0], 0)
            a.close(); b.close()


if __name__ == '__main__':
    unittest.main()
