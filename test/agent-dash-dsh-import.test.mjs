import assert from 'node:assert/strict';
import { execFile, execFileSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const importer = fileURLToPath(new URL('../agent-dash-dsh-import.mjs', import.meta.url));
const exporter = fileURLToPath(new URL('../agent-dash-dsh-export.mjs', import.meta.url));

test('owner HTTP import, verified history, and at-most-once recovery', async t => {
  const temp = realpathSync(tmpdir());
  const cwd = mkdtempSync(join(temp, 'agent-dash-import-test-'));
  t.after(() => {
    assert.equal(dirname(realpathSync(cwd)), temp);
    assert.ok(basename(cwd).startsWith('agent-dash-import-test-'));
    rmSync(cwd, { recursive: true });
  });
  const src = join(cwd, 'synthetic.jsonl');
  const rows = [['user', 'question'], ['user', 'next'], ['assistant', '终答 ✅']].map(([role, content]) => ({ type: role, timestamp: '2026-01-01T00:00:00Z', sessionId: 'fixture', message: { role, content } }));
  const raw = rows.map(JSON.stringify).join('\n') + '\n';
  writeFileSync(src, raw);
  const sha = data => createHash('sha256').update(data).digest('hex');
  const archive = JSON.parse(execFileSync(process.execPath, [exporter, 'claude', src, 'fixture', cwd, join(cwd, 'pi'), join(cwd, 'archives')]));
  const bytes = readFileSync(archive.file);
  const workspaceId = 'ws-1', id = randomUUID(), cookie = 'dsh-auth-fixture=synthetic';
  const roleEvent = (role, text) => {
    const m = { role, content: [{ type: 'text', text }] };
    return { type: role + '/message', data: role === 'user' ? m : { message: m } };
  };
  const events = [ 'turn/start', 'step/start', 'system/message', roleEvent('user', `[Source history: Claude Code · fixture; SHA-256 ${sha(raw)}]\nquestion`), 'step/end', 'turn/end', 'session/title', 'turn/start', 'step/start', roleEvent('user', 'next'), roleEvent('assistant', '[Source assistant: anthropic/unknown; 2026-01-01T00:00:00.000Z]\n终答 ✅'), 'step/end', 'turn/end' ];
  let mode, uploaded, uploads, damaged, searchHit;
  const server = createServer(async (req, res) => {
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    assert.equal(req.headers.cookie, cookie);
    if (req.url.startsWith('/api/deepseek-chat-import/archive?')) {
      assert.equal(req.url, '/api/deepseek-chat-import/archive?workspaceId=ws-1');
      assert.equal(req.headers['content-type'], 'application/octet-stream');
      assert.deepEqual(body, bytes); uploads++; uploaded = true;
      if (mode === 'disconnect') return req.socket.destroy();
      res.setHeader('content-type', 'application/x-ndjson');
      return res.end(JSON.stringify({ type: 'outcome', outcome: { ok: true, value: { workspaceId, workspacePath: cwd, conversationCount: 1, omittedByLimit: 0, skipped: [], sessionIds: [id] } } }) + '\n');
    }
    const { rpcId, method, payload } = JSON.parse(body);
    assert.equal(req.url, '/api/' + method);
    let value;
    switch (method) {
      case 'deepseekChatImport/limits':
        if (mode === 'disabled') { res.statusCode = 404; return res.end(); }
        value = { maxUploadBytes: bytes.length }; break;
      case 'workspace/create': assert.equal(payload.args.request.path, cwd); value = { workspace: { workspaceId, path: cwd, sessionIds: uploaded && (mode !== 'disconnect' || searchHit) ? [id] : [] } }; break;
      case 'session/list': assert.deepEqual(payload.args, { _request: {} }); value = { items: uploaded && (mode !== 'disconnect' || searchHit) ? [{ sessionId: id, cwd, formatStatus: 'current' }] : [] }; break;
      case 'session/events': {
        assert.equal(payload.args.request.address.sessionId, id);
        const records = events.map((e, seq) => ({ type: 'event', event: { ...(typeof e === 'string' ? { type: e } : e), seq } }));
        if (damaged) records[9].event = { ...roleEvent('user', 'wrong content'), seq: 9 };
        value = { records: records.slice(0, payload.args.request.beforeSeq), hasMore: false, cursor: records.length - 1 }; break;
      }
      default: assert.fail(method);
    }
    res.end(JSON.stringify({ rpcId, result: { ok: true, value } }));
  });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise(r => server.close(r)));
  const base = `http://127.0.0.1:${server.address().port}/`;
  function call(state) {
    return new Promise((resolve, reject) => {
      const proc = execFile(process.execPath, [importer, archive.file, cwd], { env: { PATH: process.env.PATH, HOME: cwd, XDG_STATE_HOME: join(cwd, state) } }, (err, stdout, stderr) => err ? reject(new Error(stderr.trim())) : resolve(JSON.parse(stdout)));
      proc.stdin.end(JSON.stringify({ base, cookie }));
    });
  }
  await t.test('disabled bundle is detected before any upload', async () => {
    mode = 'disabled'; uploads = 0;
    await assert.rejects(call('a'), /enable DeepSeek chat import/);
    assert.equal(uploads, 0);
  });
  await t.test('one concurrent writer, durable result and strict repeat verification', async () => {
    mode = 'success'; uploaded = false; uploads = 0;
    const results = await Promise.allSettled([call('b'), call('b')]);
    assert.ok(results.some(r => r.status === 'fulfilled'), JSON.stringify(results.map(r => r.reason?.message)));
    assert.deepEqual(await call('b'), { cwd, workspaceId, id, zipSha256: sha(bytes) });
    damaged = true;
    await assert.rejects(call('b'), /does not match source/);
    assert.equal(uploads, 1); damaged = false;
  });
  await t.test('lost response prevents another POST, later exact match recovers', async () => {
    mode = 'disconnect'; uploaded = false; uploads = 0; searchHit = false;
    await assert.rejects(call('c'), /may already have written/);
    await assert.rejects(call('c'), /not repeated/);
    searchHit = true;
    assert.equal((await call('c')).id, id);
    assert.equal(uploads, 1);
  });
  await t.test('a verified manual import is reused', async () => {
    uploads = 0; searchHit = true; uploaded = true;
    assert.equal((await call('d')).id, id); assert.equal(uploads, 0);
  });
});
