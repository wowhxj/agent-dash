#!/usr/bin/env python3
"""Opt-in macOS backup check with an installed Hermes runtime and a loopback model.

Run with --hermes-root CHECKOUT --hermes-python PYTHON_FROM_INSTALLED_VENV.
The venv must already have the Hermes gateway and ACP dependencies installed.
"""
import argparse
from contextlib import closing, contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
from queue import Empty, Queue
import signal
import sqlite3
import subprocess
import sys
from tempfile import TemporaryDirectory
from threading import Event, Thread
import time

REPO = Path(__file__).resolve().parents[1]
SANDBOX = Path('/usr/bin/sandbox-exec')
MODEL = 'agent-dash-hermes-fixture'
ORIGINAL = 'Backup fixture original turn.'
CONTINUED = 'Backup fixture continued turn.'
REPLY = 'Synthetic model reply.'
FALLBACK = {'role': 'assistant', 'content': 'Synthetic JSONL recovery record.'}


class Model(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path != '/v1/models':
            self.send_error(404)
            return
        self.send_body({'object': 'list', 'data': [{'id': MODEL, 'object': 'model'}]})

    def do_POST(self):
        if self.path != '/v1/chat/completions':
            self.send_error(404)
            return
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if request.get('model') != MODEL:
            self.send_error(400, 'Unexpected fixture model')
            return
        if any(m.get('role') == 'user' and m.get('content') == CONTINUED for m in request['messages']):
            self.server.continuation.put(request['messages'])
            if not self.server.release.wait(45):
                self.send_error(504)
                return
        base = {'id': 'chatcmpl-fixture', 'created': 1, 'model': MODEL}
        if request.get('stream'):
            events = [{'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': REPLY}, 'finish_reason': None}]},
                      {'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]}]
            body = ''.join('data: ' + json.dumps({**base, **event, 'object': 'chat.completion.chunk'}) + '\n\n'
                           for event in events) + 'data: [DONE]\n\n'
            self.send_body(body, 'text/event-stream')
        else:
            self.send_body({**base, 'object': 'chat.completion',
                            'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': REPLY}, 'finish_reason': 'stop'}],
                            'usage': {'prompt_tokens': 15, 'completion_tokens': 5, 'total_tokens': 20}})

    def send_body(self, response, content_type='application/json'):
        body = (json.dumps(response) if isinstance(response, dict) else response).encode()
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@contextmanager
def process(command, *, stderr, **kwargs):
    with stderr.open('w+') as log:
        child = subprocess.Popen(command, stderr=log, start_new_session=True, **kwargs)
        try:
            yield child
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)


class ACP:
    def __init__(self, child, log):
        self.child, self.log = child, log
        self.results = Queue()
        self.last_id = 0
        Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.child.stdout:
            self.results.put(line)
        self.results.put(None)

    def send(self, method, **params):
        self.last_id += 1
        request = {'jsonrpc': '2.0', 'id': self.last_id, 'method': method, 'params': params}
        self.child.stdin.write(json.dumps(request) + '\n')
        self.child.stdin.flush()
        return self.last_id

    def receive(self, request_id):
        updates = []
        deadline = time.monotonic() + 40
        while True:
            try:
                line = self.results.get(timeout=max(0, deadline - time.monotonic()))
            except Empty as exc:
                raise RuntimeError(f'ACP response {request_id} timed out. {self.log.read_text()}') from exc
            if line is None:
                raise RuntimeError(f'ACP closed before response {request_id}. {self.log.read_text()}')
            event = json.loads(line)
            if event.get('id') == request_id and 'method' not in event:
                if 'error' in event:
                    raise RuntimeError(event['error'])
                return event['result'], updates
            if event.get('method') == 'session/update':
                updates.append(event['params'])
            elif 'method' in event and 'id' in event:
                raise RuntimeError(f'Unexpected ACP callback {event["method"]}')

    def call(self, method, **params):
        return self.receive(self.send(method, **params))


class Fixture:
    def __init__(self, root, checkout, python, server):
        self.root, self.checkout, self.python, self.server = root, checkout, python, server
        # User installations commonly put both the venv and its base interpreter under $HOME.
        # Allow their code while fencing off real profiles, credentials, and working directories.
        venv = python.parent.parent
        probe = subprocess.run([str(SANDBOX), '-p', '(version 1) (allow default) (deny file-write*) (deny network*)',
                                str(python), '-IBc', 'import sys; print(sys.base_prefix)'],
                               env={'HOME': str(root), 'PATH': '/usr/bin:/bin'}, capture_output=True,
                               check=True, text=True, cwd=root, timeout=10)
        code_paths = (checkout, venv, Path(probe.stdout.strip()), REPO, Path(sys.base_prefix), Path(sys.prefix))
        allowed = ' '.join(f'(subpath {json.dumps(str(path))})' for path in code_paths)
        local = json.dumps(str(root))
        self.sandbox = [str(SANDBOX), '-p', f'''(version 1)
(allow default)
(deny file-read* (subpath {json.dumps(str(Path.home().resolve()))}))
(allow file-read* {allowed})
(deny file-write*)
(allow file-write* (subpath {local}) (literal "/dev/null"))
(deny network*)
(allow network* (local ip "localhost:*") (remote ip "localhost:*")
    (local unix-socket (subpath {local})) (remote unix-socket (subpath {local})))''']

    def env(self, home):
        return dict(HOME=str(home), HERMES_HOME=str(home), TMPDIR=str(home), PATH='/usr/bin:/bin',
                    PYTHONPATH=str(self.checkout), PYTHONDONTWRITEBYTECODE='1', HERMES_DISABLE_LAZY_INSTALLS='1',
                    NO_PROXY='127.0.0.1,localhost')

    def prepare(self, name):
        home = self.root / name
        (home / 'project').mkdir(parents=True)
        (home / 'config.yaml').write_text(json.dumps({
            '_config_version': 53,
            'model': {'default': MODEL, 'provider': 'custom', 'context_length': 128000,
                      'base_url': f'http://127.0.0.1:{self.server.server_port}/v1'},
            'memory': {'memory_enabled': False, 'user_profile_enabled': False},
            'telemetry': {'enabled': False},
        }))
        (home / '.env').write_text('CUSTOM_API_KEY=fixture-key\n')
        return home

    def native(self, home, *args):
        return subprocess.run(self.sandbox + [str(self.python), '-B', *args], env=self.env(home), cwd=home,
                              capture_output=True, text=True, timeout=40, check=True).stdout

    @contextmanager
    def acp(self, home):
        launch = self.sandbox + [str(self.python), '-B', '-m', 'hermes_cli.main']
        gateway_log, acp_log = home / 'gateway.stderr', home / 'acp.stderr'
        kwargs = dict(env=self.env(home), cwd=home / 'project', text=True)
        with process(launch + ['gateway', 'run'], stderr=gateway_log, stdout=subprocess.DEVNULL, **kwargs) as gateway:
            deadline = time.monotonic() + 25
            while not (home / 'gateway.sock').is_socket():
                if gateway.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError('Isolated Hermes gateway did not start. ' + gateway_log.read_text())
                time.sleep(0.1)
            with process(launch + ['acp'], stderr=acp_log, stdin=subprocess.PIPE, stdout=subprocess.PIPE, **kwargs) as client:
                acp = ACP(client, acp_log)
                result, _ = acp.call('initialize', protocolVersion=1, clientCapabilities={},
                                     clientInfo={'name': 'agent-dash native fixture', 'version': '1'})
                assert result['agentCapabilities']['loadSession'], result
                try:
                    yield acp
                except Exception:
                    for path in (acp_log, gateway_log):
                        print(f'{path.name}\n{path.read_text()[-6000:]}', file=sys.stderr)
                    raise
                finally:
                    client.stdin.close()
                    client.wait(timeout=10)

    def cli(self, *args, allow_error=False):
        proc = subprocess.run(self.sandbox + [sys.executable, '-IB', str(REPO / 'agent-dash-session-backup.py'),
                                              *map(str, args)], env=self.env(self.root), cwd=self.root,
                              capture_output=True, text=True, timeout=40)
        if proc.returncode and not allow_error:
            raise RuntimeError(proc.stderr or proc.stdout)
        return json.loads(proc.stdout or proc.stderr), proc.returncode


def replay_text(updates, sid):
    return ''.join(update['update'].get('content', {}).get('text', '') for update in updates
                   if update.get('sessionId') == sid)


def load(acp, sid, cwd, *expected):
    _, updates = acp.call('session/load', sessionId=sid, cwd=str(cwd), mcpServers=[])
    replay = replay_text(updates, sid)
    assert all(text in replay for text in expected), replay
    return replay


def append_recovery(fixture, home, sid, record):
    fixture.native(home, '-c', 'import json, sys; from hermes_state import divert_session_transcript_jsonl as write; '
                   'write(sys.argv[1], [json.loads(sys.argv[2])])', sid, json.dumps(record))


def restore_legacy_desktop(fixture, source, target):
    sid = '20260102_030405_f1a2b3'
    prompt = 'Synthetic legacy Desktop history.'
    fixture.native(source, '-c', '''import sys
from hermes_state import SessionDB
sid, cwd, model, prompt = sys.argv[1:]
with SessionDB() as db:
    db.create_session(sid, source='desktop', cwd=cwd, model=model, user_id='nous:fixture-owner')
    db.append_message(sid, 'user', prompt)
    db.end_session(sid, 'fixture')
''', sid, str(source / 'project'), MODEL, prompt)
    archive = fixture.root / 'legacy.zip'
    fixture.cli('export', '--home', 'hermes', source, '--session', f'hermes:{sid}', '--output', archive)
    args = ('--input', archive, '--home', 'hermes', target, '--map', source / 'project', target / 'project')
    plan, _ = fixture.cli('preview', *args)
    assert [(s['id'], s['action']) for s in plan['sessions']] == [(sid, 'create')], plan['sessions']
    fixture.cli('import', *args, '--preview-token', plan['preview_token'])
    return sid, prompt


def verify(fixture):
    source, target = fixture.prepare('source'), fixture.prepare('target')
    source_cwd, target_cwd = source / 'project', target / 'project'
    version = fixture.native(source, '-m', 'hermes_cli.main', '--version').splitlines()[0]
    deps = fixture.native(source, '-m', 'hermes_cli.main', 'acp', '--check').strip()
    with fixture.acp(source) as acp:
        result, _ = acp.call('session/new', cwd=str(source_cwd), mcpServers=[])
        sid = result['sessionId']
        result, updates = acp.call('session/prompt', sessionId=sid, prompt=[{'type': 'text', 'text': ORIGINAL}])
        assert result['stopReason'] == 'end_turn' and REPLY in replay_text(updates, sid), (result, updates)
    fallback = source / 'sessions' / f'{sid}.jsonl'
    append_recovery(fixture, source, sid, FALLBACK)
    assert json.loads(fallback.read_text()) == FALLBACK
    with fixture.acp(target):
        pass  # Initialize a separate native state.db and shut its writer down before restore.
    bundle = fixture.root / 'backup.zip'
    assert fixture.cli('export', '--home', 'hermes', source, '--session', f'hermes:{sid}', '--output', bundle)[0]['count'] == 1
    assert fixture.cli('inspect', '--input', bundle)[0]['backends'] == ['hermes']
    args = ('--input', bundle, '--home', 'hermes', target, '--map', source_cwd, target_cwd)

    def preview(expected, *extra):
        plan, _ = fixture.cli('preview', *args, *extra)
        assert [(s['backend'], s['id'], s['action']) for s in plan['sessions']] == [('hermes', sid, expected)], plan
        return plan['preview_token']

    fixture.cli('import', *args, '--preview-token', preview('create'))
    preview('skip')
    restored = target / 'sessions' / fallback.name
    assert restored.read_bytes() == fallback.read_bytes()
    with closing(sqlite3.connect(f'{(target / "state.db").as_uri()}?mode=ro', uri=True)) as db:
        row = db.execute('SELECT cwd, session_key FROM sessions WHERE id=?', (sid,)).fetchone()
        assert row and row[0] == str(target_cwd) and row[1], row
        session_key = row[1]
        receipt = db.execute('SELECT value FROM state_meta WHERE key=?', (f'gateway.local_policy.v1:{sid}',)).fetchone()
        policy = json.loads(receipt[0])['policy']
        assert policy['cwd'] == str(target_cwd), policy['cwd']
        assert json.loads(policy['request_json'])['cwd'] == str(target_cwd)
        assert json.loads(policy['terminal_json'])['TERMINAL_CWD'] == str(target_cwd)
        schema = db.execute('SELECT version FROM schema_version').fetchone()[0]
    # A JSONL-only change makes this session an overwrite before the runtime starts.
    append_recovery(fixture, target, sid, {'role': 'assistant', 'content': 'Target-only recovery record.'})
    target_recovery = restored.read_bytes()
    preview('busy', '--active-session', f'hermes:{sid}')
    idle_token = preview('overwrite')
    with fixture.acp(target) as acp:
        load(acp, sid, target_cwd, ORIGINAL, REPLY)
        request_id = acp.send('session/prompt', sessionId=sid, prompt=[{'type': 'text', 'text': CONTINUED}])
        try:
            context = fixture.server.continuation.get(timeout=35)
            assert any(message.get('content') == ORIGINAL for message in context), context
            assert any(message.get('content') == REPLY for message in context), context
            registry = json.loads((target / 'runtime/active_sessions.json').read_text())
            assert any(entry['session_id'] == session_key for entry in registry['entries']), registry
            preview('busy')
            active_bundle = fixture.root / 'active.zip'
            blocked, code = fixture.cli('export', '--home', 'hermes', target, '--output', active_bundle,
                                        '--session', f'hermes:{sid}', allow_error=True)
            assert code and 'busy' in blocked.get('error', '') and not active_bundle.exists(), blocked
            blocked, code = fixture.cli('import', *args, '--preview-token', idle_token, allow_error=True)
            assert code and blocked.get('errors', {}).get('hermes') == '预览已失效，请重新预览', blocked
            assert restored.read_bytes() == target_recovery
        finally:
            fixture.server.release.set()
        result, _ = acp.receive(request_id)
        assert result['stopReason'] == 'end_turn', result
    with fixture.acp(target) as acp:
        load(acp, sid, target_cwd, ORIGINAL, REPLY, CONTINUED)
    report, _ = fixture.cli('import', *args, '--preview-token', preview('overwrite'))
    rollback = report['backends']['hermes']['rollback_archive_path']
    assert restored.read_bytes() == fallback.read_bytes()
    with fixture.acp(target) as acp:
        assert CONTINUED not in load(acp, sid, target_cwd, ORIGINAL, REPLY)
    recovery = ('--input', rollback, '--home', 'hermes', target)
    plan, _ = fixture.cli('preview', *recovery)
    assert [s['action'] for s in plan['sessions']] == ['overwrite'], plan['sessions']
    fixture.cli('import', *recovery, '--preview-token', plan['preview_token'])
    legacy_sid, legacy_prompt = restore_legacy_desktop(fixture, source, target)
    with fixture.acp(target) as acp:
        load(acp, sid, target_cwd, ORIGINAL, REPLY, CONTINUED)
        load(acp, legacy_sid, target_cwd, legacy_prompt)
    assert restored.read_bytes() == target_recovery
    print(f'{version}\n{deps}\nSQLite schema {schema}: verified ACP replay and continuation, mapped cwd, JSONL, '
          'active protection, overwrite, rollback, and legacy Desktop adoption.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hermes-root', type=Path, required=True)
    parser.add_argument('--hermes-python', type=Path, required=True)
    args = parser.parse_args()
    if not SANDBOX.is_file():
        parser.error('macOS sandbox-exec is required to restrict file writes and network access')
    if not (args.hermes_root / 'hermes_cli/main.py').is_file() or not args.hermes_python.is_file():
        parser.error('provide an installed Hermes checkout and its existing venv interpreter')
    with TemporaryDirectory(prefix='ad-hm-') as directory, ThreadingHTTPServer(('127.0.0.1', 0), Model) as server:
        server.continuation, server.release = Queue(), Event()
        Thread(target=server.serve_forever, daemon=True).start()
        try:
            verify(Fixture(Path(directory).resolve(), args.hermes_root.resolve(), args.hermes_python.absolute(), server))
        finally:
            server.release.set()
            server.shutdown()


if __name__ == '__main__':
    main()
