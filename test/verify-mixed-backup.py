"""Opt-in mixed Hub backup check with the installed DSH runtime and synthetic histories."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
from tempfile import TemporaryDirectory
from uuid import uuid4

REPO = Path(__file__).resolve().parents[1]
BACKENDS = ('codex', 'pi', 'dsh', 'hermes')


def cli(*args):
    result = subprocess.run([sys.executable, '-B', str(REPO / 'agent-dash-session-backup.py'), *map(str, args)],
                            capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return json.loads(result.stdout)


def dsh(operation, home, sid):
    env = dict(os.environ, ELECTRON_RUN_AS_NODE='1', HOME=str(home), DSH_HOME=str(home))
    result = subprocess.run([env['DSH_NODE_EXECUTABLE'], str(REPO / 'test/agent-dash-dsh-backup-fixture.mjs'),
                             operation, str(home), sid, str(home / 'project')], env=env,
                            check=True, capture_output=True, text=True, timeout=40)
    return json.loads(result.stdout) if operation == 'read' else None


def setup(home, sid, seed):
    project = home / 'project'
    project.mkdir()
    roots = {'codex': home / 'codex', 'pi': home / 'pi-sessions', 'dsh': home, 'hermes': home / 'hermes'}
    roots['codex'].mkdir()
    roots['pi'].mkdir()
    roots['hermes'].mkdir()
    hermes_install = Path(os.getenv('HERMES_AGENT_DIR', Path.home() / '.hermes/hermes-agent'))
    hermes_python = os.getenv('HERMES_PYTHON')
    if not hermes_python:
        runtimes = list((hermes_install.parent / 'installs').glob('*/environments/*/venv/bin/python'))
        if len(runtimes) != 1:
            raise RuntimeError('Set HERMES_PYTHON to the installed Hermes runtime Python.')
        hermes_python = runtimes[0]
    fixture = """import sys
from pathlib import Path
from hermes_state import SessionDB
db = SessionDB(Path(sys.argv[1]) / 'state.db')
try:
    if sys.argv[4] == 'seed':
        db.create_session(sys.argv[2], 'cli', cwd=sys.argv[3])
        db.append_message(sys.argv[2], 'user', 'Hermes fixture')
finally:
    db.close()
"""
    subprocess.run([str(hermes_python), '-B', '-c', fixture, str(roots['hermes']), sid,
                    str(project), 'seed' if seed else 'empty'], cwd=home, env=dict(HOME=str(home), PATH='/usr/bin:/bin',
                   HERMES_DISABLE_LAZY_INSTALLS='1', PYTHONPATH=str(hermes_install),
                   HERMES_HOME=str(roots['hermes'])), check=True)
    with sqlite3.connect(roots['codex'] / 'state_5.sqlite') as db:
        db.execute('CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, cwd TEXT, title TEXT)')
        if seed:
            file = roots['codex'] / 'sessions/2026/01/02' / f'rollout-2026-01-02T00-00-00-{sid}.jsonl'
            file.parent.mkdir(parents=True)
            file.write_text(json.dumps({'type': 'session_meta', 'payload': {'id': sid, 'cwd': str(project)}}) + '\n')
            db.execute('INSERT INTO threads VALUES (?,?,?,?)', (sid, str(file), str(project), 'mixed fixture'))
    if seed:
        directory = roots['pi'] / ('--' + str(project).strip('/').replace('/', '-') + '--')
        directory.mkdir()
        stamp = '2026-01-02T00:00:00.000Z'
        records = [{'type': 'session', 'version': 3, 'id': sid, 'timestamp': stamp, 'cwd': str(project)},
                   {'type': 'message', 'id': 'a1234567', 'parentId': None, 'timestamp': stamp,
                    'message': {'role': 'user', 'content': [{'type': 'text', 'text': 'Pi fixture'}], 'timestamp': 1767312000000}}]
        file = directory / f'2026-01-02T00-00-00-000Z_{sid}.jsonl'
        file.write_text(''.join(json.dumps(row) + '\n' for row in records))
        dsh('seed', home, sid)
    return [value for backend, root in roots.items() for value in ('--home', backend, root)]


def hub_export(source, sid):
    """Exercise M and the selected-export command, substituting only the save dialog."""
    form = r'''(let* ((sid (getenv "FIXTURE_ID")) (root (getenv "FIXTURE_ROOT"))
                     (pattern "\\`agent-dash-backup-[0-9]\\{15\\}\\.zip\\'") (deadline (+ (float-time) 90))
                     (agent-dash-summary-enable nil) (agent-dash-backends '(codex pi dsh hermes))
                     (agent-dash-codex-directory (expand-file-name "codex" root))
                     (agent-dash-pi-sessions-directory (expand-file-name "pi-sessions" root))
                     (agent-dash-hub-dsh-backup-directory root)
                     (agent-dash-hermes-directory (expand-file-name "hermes" root))
                     (agent-dash-hub--sources (make-hash-table)))
                (dolist (b agent-dash-backends)
                  (puthash b (list :status 'ok :rows (list (list :backend b :id sid
                              :key (format "%s:%s" b sid) :root (expand-file-name "project" root))))
                           agent-dash-hub--sources))
                (with-temp-buffer
                  (agent-dash-hub-mode) (agent-dash-hub--render)
                  (call-interactively (lookup-key agent-dash-hub-mode-map "M"))
                  (unless (= 4 (hash-table-count (agent-dash-hub--selection))) (error "M selection"))
                  (cl-letf (((symbol-function 'read-directory-name) (lambda (&rest _) root)))
                    (call-interactively #'agent-dash-hub-backup-export-selected))
                  (while (and (not (directory-files root nil pattern)) (< (float-time) deadline))
                    (accept-process-output nil 0.05))
                  (unless (directory-files root nil pattern) (error "Hub export failed"))))'''
    elpa = os.getenv('ELPA', str(Path.home() / '.emacs.d.default/elpa'))
    env = dict(os.environ, FIXTURE_ROOT=str(source), FIXTURE_ID=sid, ELPA=elpa)
    subprocess.run(['emacs', '-Q', '--batch', '--eval',
                    '(setq package-user-dir (getenv "ELPA") agent-dash-summary-enable nil load-prefer-newer t)',
                    '-f', 'package-initialize', '-L', str(REPO), '-l', 'agent-dash', '--eval', form],
                   env=env, check=True, timeout=100)


def verify(source, dest):
    sid = str(uuid4())  # Intentionally use one ID for all four backends.
    setup(source, sid, True)
    new = setup(dest, sid, False)
    hub_export(source, sid)
    bundle, = source.glob('agent-dash-backup-*.zip')
    assert set(cli('inspect', '--input', bundle)['backends']) == set(BACKENDS)
    args = ['--input', bundle, *new, '--map', source / 'project', dest / 'project']

    def preview(expected):
        plan = cli('preview', *args)
        actions = {(r['backend'], r['id']): r['action'] for r in plan['sessions']}
        assert actions == {(b, sid): expected[b] for b in BACKENDS}, (actions, expected)
        return plan['preview_token']

    token = preview(dict.fromkeys(BACKENDS, 'create'))
    cli('import', *args, '--preview-token', token)
    preview(dict.fromkeys(BACKENDS, 'skip'))
    state = dsh('read', dest, sid)
    assert state == {'id': sid, 'cwd': str(dest / 'project'), 'messages': ['fixture initial message']}, state
    with sqlite3.connect(dest / 'codex/state_5.sqlite') as db:
        cwd, rollout = db.execute('SELECT cwd,rollout_path FROM threads WHERE id=?', (sid,)).fetchone()
        assert cwd == str(dest / 'project') and Path(rollout).is_file()
    pi_files = list((dest / 'pi-sessions').rglob('*.jsonl'))
    assert len(pi_files) == 1
    header = json.loads(pi_files[0].read_text().splitlines()[0])
    assert (header['cwd'], header['id']) == (str(dest / 'project'), sid)
    with sqlite3.connect(dest / 'hermes/state.db') as db:
        assert db.execute('SELECT cwd FROM sessions WHERE id=?', (sid,)).fetchone() == (str(dest / 'project'),)
        assert db.execute('SELECT content FROM messages WHERE session_id=?', (sid,)).fetchone() == ('Hermes fixture',)
    dsh('append', dest, sid)
    token = preview({'codex': 'skip', 'pi': 'skip', 'hermes': 'skip', 'dsh': 'overwrite'})
    imported = cli('import', *args, '--preview-token', token)
    assert dsh('read', dest, sid)['messages'] == ['fixture initial message']
    rollback = imported['backends']['dsh']['rollback_archive_path']
    recovery = ['--input', rollback, *new]
    plan = cli('preview', *recovery)
    cli('import', *recovery, '--preview-token', plan['preview_token'])
    assert dsh('read', dest, sid)['messages'] == ['fixture initial message', 'fixture appended message']
    print('One ZIP, four native sessions sharing an ID: create, map, cold open, skip, selective overwrite and rollback verified.')


if __name__ == '__main__':
    with TemporaryDirectory(prefix='agent-dash-dsh-fixture-') as source, TemporaryDirectory(prefix='agent-dash-dsh-fixture-') as dest:
        verify(Path(source).resolve(), Path(dest).resolve())
