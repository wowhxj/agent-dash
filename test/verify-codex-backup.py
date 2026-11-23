#!/usr/bin/env python3
"""Opt-in macOS check using real Codex and a local mock model only.

Run with python3 test/verify-codex-backup.py. Requires Codex and sandbox-exec.
"""
import http.server
import json
import os
from pathlib import Path
import queue
import shutil
import sqlite3
import sys
import tempfile
import subprocess
import threading
import time

REPO = Path(__file__).resolve().parents[1]
CODEX = shutil.which('codex')
REQUESTS = []


class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        REQUESTS.append((self.path, data))
        assert self.path == '/v1/responses'
        number = len(REQUESTS)
        message = {'id': f'msg_{number}', 'type': 'message', 'status': 'completed',
                   'role': 'assistant', 'content': [{'type': 'output_text', 'text': f'LOCAL_REPLY_{number}', 'annotations': []}]}
        response = {'id': f'resp_{number}', 'object': 'response', 'created_at': 1,
                    'status': 'completed', 'model': 'gpt-5.4', 'output': [message],
                    'usage': {'input_tokens': 10, 'output_tokens': 5, 'total_tokens': 15}}
        events = [('response.created', {'response': {**response, 'status': 'in_progress', 'output': []}}),
                  ('response.output_item.added', {'output_index': 0, 'item': {**message, 'status': 'in_progress', 'content': []}}),
                  ('response.output_text.delta', {'item_id': message['id'], 'output_index': 0, 'content_index': 0, 'delta': f'LOCAL_REPLY_{number}'}),
                  ('response.output_item.done', {'output_index': 0, 'item': message}),
                  ('response.completed', {'response': response})]
        body = ''.join(f'event: {event}\ndata: {json.dumps({"type": event, **payload})}\n\n' for event, payload in events).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)



def prepare(name):
    home = ROOT / name
    home.mkdir(exist_ok=False)
    (home / 'config.toml').write_text(f'''model = "gpt-5.4"
model_provider = "fixture"
approval_policy = "never"
sandbox_mode = "read-only"
web_search = "disabled"
[model_providers.fixture]
name = "Fixture"
base_url = "http://127.0.0.1:{PORT}/v1"
wire_api = "responses"
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
[analytics]
enabled = false
''')
    return home


def isolated(home, program):
    return ['/usr/bin/sandbox-exec', '-p', PROFILE, '/usr/bin/env', '-i',
            f'HOME={home}', f'CODEX_HOME={home}', f'TMPDIR={ROOT}',
            f'PATH={Path(CODEX).parent}:/usr/bin:/bin', 'NO_PROXY=127.0.0.1,localhost',
            f'HTTP_PROXY=http://127.0.0.1:{PORT}', f'HTTPS_PROXY=http://127.0.0.1:{PORT}',
            'RUST_LOG=warn', *program]


class Client:
    def __init__(self, home, cwd):
        self.home = home
        self.stderr = (home / 'server.stderr').open('a')
        self.proc = subprocess.Popen(isolated(home, [CODEX, 'app-server', '--stdio']), cwd=cwd,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr, text=True)
        self.messages = queue.Queue()
        self.counter = 0
        self.seen = []
        threading.Thread(target=self.receive, daemon=True).start()

    def receive(self):
        for line in self.proc.stdout:
            self.messages.put(json.loads(line))
        self.messages.put(None)

    def __enter__(self):
        self.call('initialize', {'clientInfo': {'name': 'rollout_fixture', 'version': '1'}, 'capabilities': {'experimentalApi': True}})
        self.send({'method': 'initialized'})
        return self

    def __exit__(self, *_):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        self.stderr.close()

    def send(self, message):
        self.proc.stdin.write(json.dumps(message) + '\n')
        self.proc.stdin.flush()

    def wait(self, predicate):
        deadline = time.monotonic() + 15
        while True:
            try:
                item = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            except queue.Empty as error:
                raise RuntimeError((self.seen[-15:], len(REQUESTS))) from error
            if item is None:
                raise RuntimeError(f'app-server exited {self.proc.poll()}')
            self.seen.append(item)
            if predicate(item):
                return item

    def call(self, method, params=None, allow_error=False):
        self.counter += 1
        request_id = self.counter
        self.send({'id': request_id, 'method': method, 'params': params or {}})
        response = self.wait(lambda response: response.get('id') == request_id)
        if 'error' in response:
            if allow_error:
                return response
            raise RuntimeError(f'{method}: {response}')
        return response['result']

    def turn(self, thread_id, message):
        self.call('turn/start', {'threadId': thread_id, 'input': [{'type': 'text', 'text': message, 'text_elements': []}]})
        done = self.wait(lambda x: x.get('method') == 'turn/completed')
        assert done['params']['turn']['status'] == 'completed', done



def backup(command, home, *args):
    result = subprocess.run([sys.executable, str(REPO / 'agent-dash-backup.py'), command,
                             '--home', str(home), *args], capture_output=True, text=True, timeout=40)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout)


def verify():
    origin = ROOT / 'old-project'
    target = ROOT / 'new-project'
    origin.mkdir()
    target.mkdir()
    old_home, new_home = prepare('old-home'), prepare('new-home')
    with Client(old_home, origin) as client:
        thread_id = client.call('thread/start', {'cwd': str(origin)})['thread']['id']
        client.turn(thread_id, 'ORIGINAL_FIXTURE')
    with Client(new_home, target) as client:
        client.call('thread/list')
    package = ROOT / 'backup.zip'
    assert backup('export', old_home, '--output', str(package), '--id', thread_id)['count'] == 1
    args = ('--input', str(package), '--map', str(origin), str(target))
    plan = backup('preview', new_home, *args)
    assert [r['action'] for r in plan['sessions']] == ['create'], plan
    backup('import', new_home, *args, '--preview-token', plan['preview_token'])
    plan = backup('preview', new_home, *args)
    assert [r['action'] for r in plan['sessions']] == ['skip'], plan
    with Client(new_home, target) as client:
        listed = client.call('thread/list', {'useStateDbOnly': True, 'modelProviders': []})['data']
        assert any(row['id'] == thread_id and row['cwd'] == str(target) for row in listed), listed
        resumed = client.call('thread/resume', {'threadId': thread_id})
        assert resumed['thread']['id'] == thread_id and resumed['cwd'] == str(target), resumed
        client.turn(thread_id, 'CONTINUED_FIXTURE')
        request = json.dumps(REQUESTS[-1][1])
        assert all(part in request for part in ['ORIGINAL_FIXTURE', 'LOCAL_REPLY_1', 'CONTINUED_FIXTURE']), request
    with Client(new_home, target) as client:
        client.call('thread/resume', {'threadId': thread_id, 'cwd': str(target)})
        turns = json.dumps(client.call('thread/turns/list', {'threadId': thread_id, 'itemsView': 'full'}))
        assert all(part in turns for part in ['ORIGINAL_FIXTURE', 'LOCAL_REPLY_1', 'CONTINUED_FIXTURE', 'LOCAL_REPLY_2']), turns
    plan = backup('preview', new_home, *args)
    assert [r['action'] for r in plan['sessions']] == ['overwrite'], plan
    report = backup('import', new_home, *args, '--preview-token', plan['preview_token'])
    rollback = Path(report['rollback_path'])
    assert rollback.is_dir() and any(b'CONTINUED_FIXTURE' in file.read_bytes() for file in rollback.glob('*.jsonl'))
    plan = backup('preview', new_home, *args)
    assert [r['action'] for r in plan['sessions']] == ['skip'], plan
    restore_args = ('--input', report['rollback_archive_path'])
    restore = backup('preview', new_home, *restore_args)
    assert [r['action'] for r in restore['sessions']] == ['overwrite'], restore
    backup('import', new_home, *restore_args, '--preview-token', restore['preview_token'])
    with Client(new_home, target) as client:
        client.call('thread/resume', {'threadId': thread_id})
        restored = json.dumps(client.call('thread/turns/list', {'threadId': thread_id, 'itemsView': 'full'}))
        assert 'CONTINUED_FIXTURE' in restored and 'LOCAL_REPLY_2' in restored, restored
    print('Verified native ID, mapped cwd, resume, reopen, duplicate skip, overwrite and rollback.')


if __name__ == '__main__':
    if not CODEX or not Path('/usr/bin/sandbox-exec').is_file():
        raise SystemExit('This opt-in test requires macOS sandbox-exec and Codex.')
    with tempfile.TemporaryDirectory(prefix='agent-dash-verify-codex-') as root:
        ROOT = Path(root).resolve()
        with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Model) as server:
            PORT = server.server_address[1]
            PROFILE = f'''(version 1)
(allow default)
(deny file-read* (subpath {json.dumps(str(Path.home()))}))
(deny file-write*)
(allow file-write* (subpath {json.dumps(str(ROOT))}))
(allow file-write* (literal "/dev/null"))
(deny network*)
(allow network-outbound (remote ip "localhost:{PORT}"))'''
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                verify()
            finally:
                server.shutdown()
