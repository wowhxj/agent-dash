"""Exercise the native DSH adapter against the installed release in two disposable homes."""
from contextlib import ExitStack
import json
import fcntl
import socket
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
cli = root/'agent-dash-dsh-backup.py'
fixture = root/'test/agent-dash-dsh-backup-fixture.mjs'
node = os.environ['DSH_NODE_EXECUTABLE']
sid = str(uuid.uuid4())
with ExitStack() as stack:
    source, target = [Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='agent-dash-dsh-fixture-'))).resolve() for _ in range(2)]
    src, dst = source/'project', target/'project'
    src.mkdir(); dst.mkdir()
    env = {**os.environ, 'HOME': str(target), 'ELECTRON_RUN_AS_NODE':'1'}
    def fixture_call(op, home, cwd):
        return subprocess.check_output([node, fixture, op, home, sid, cwd], env=env)
    def call(*args, ok=True):
        clean = {k:v for k,v in env.items() if k not in ('DSH_INSTALL_DIR','DSH_NODE_EXECUTABLE')}
        r = subprocess.run([sys.executable, '-I', cli, *args], env=clean, capture_output=True)
        if not ok:
            assert r.returncode != 0
            return json.loads(r.stderr)
        assert r.returncode == 0, r.stderr.decode()
        return json.loads(r.stdout)
    fixture_call('seed',source,src)
    archive = source/'source.zip'
    call('export','--home',source,'--output',archive,'--id',sid)
    opts=['--home',target,'--input',archive,'--map',src,dst]
    plan=call('preview',*opts); assert plan['sessions'][0]['action']=='create'
    with socket.socket() as host:
        host.bind(('127.0.0.1',0)); host.listen()
        bridge=target/'emacs-dsh-bridge.json'
        bridge.write_text(json.dumps({'launch':{'value':f'http://127.0.0.1:{host.getsockname()[1]}/'}}))
        assert '停止目标 DSH Host' in call('import',*opts,'--preview-token',plan['preview_token'],ok=False)['error']
    call('import',*opts,'--preview-token',plan['preview_token'])
    assert json.loads(fixture_call('read',target,dst))==dict(id=sid,cwd=str(dst),messages=['fixture initial message'])
    assert call('preview',*opts)['sessions'][0]['action']=='skip'
    with next((target/'sessions').glob('*/' + sid + '/session.lock')).open('rb') as lease:
        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        busy = call('preview',*opts)
        assert busy['sessions'][0]['action']=='busy'
        assert call('import',*opts,'--preview-token',busy['preview_token'])['sessions'][0]['action']=='busy'
    fixture_call('append',target,dst)
    assert json.loads(fixture_call('read',target,dst))['messages'][-1]=='fixture appended message'
    assert call('preview',*opts,'--active-id',sid)['sessions'][0]['action']=='busy'
    # Existing native identity keeps its target workspace even without a mapping.
    opts=['--home',target,'--input',archive]
    plan=call('preview',*opts); assert plan['sessions'][0]['action']=='overwrite'
    assert any(str(dst) in warning for warning in plan['warnings'])
    cache = target/'storages/session_projcache/sessions'; cache.mkdir(parents=True)
    stale = cache/f'{sid}.json'; stale.write_text('stale checkpoint')
    unrelated = cache/'unrelated.json'; unrelated.write_text('untouched')
    imported=call('import',*opts,'--preview-token',plan['preview_token']); rollback=imported['rollback_archive_path']
    assert not stale.exists() and unrelated.read_text() == 'untouched'
    assert json.loads(fixture_call('read',target,dst))['messages']==['fixture initial message']
    ropts=['--home',target,'--input',rollback]
    call('import',*ropts,'--preview-token',call('preview',*ropts)['preview_token'])
    assert json.loads(fixture_call('read',target,dst))['messages']==['fixture initial message','fixture appended message']
    print('DSH 0.2.2-rc.5 native restore, mapped cwd, workspace membership, restart, append, overwrite and rollback passed:',sid)
