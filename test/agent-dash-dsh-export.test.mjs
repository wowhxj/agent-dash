import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const cli = fileURLToPath(new URL('../agent-dash-dsh-export.mjs', import.meta.url));
const converter = fileURLToPath(new URL('../agent-dash-convert.mjs', import.meta.url));
const timestamp = '2026-01-01T00:00:00Z';
const native = (type, content) => ({ type, message: { role: type, content }, sessionId: 'example', timestamp });
const claude = [native('user', 'unique question'), native('assistant', [{ type: 'text', text: 'before call' },
  { type: 'tool_use', id: 'c1', name: 'Read', input: { path: 'example.txt' } }]),
  native('user', [{ type: 'tool_result', tool_use_id: 'c1', content: 'unique tool output' }]), native('assistant', 'unique answer'),
  native('user', 'follow-up question'), native('assistant', 'follow-up answer')];
const codex = [{ type: 'session_meta', payload: { id: 'example' } },
  { type: 'response_item', payload: { type: 'message', role: 'user', content: 'unique question' } },
  { type: 'response_item', payload: { type: 'message', role: 'assistant', content: 'unique answer' } }].map(row => ({ ...row, timestamp }));

function setup(t, backend, rows) {
  const root = mkdtempSync(join(tmpdir(), 'agent-dash-export-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const source = join(root, 'source.jsonl'), pi = join(root, 'pi'), archives = join(root, 'archives');
  writeFileSync(source, rows.map(row => JSON.stringify(row)).join('\n') + '\n');
  const run = (script = cli, target = archives) => JSON.parse(execFileSync(process.execPath,
    [script, backend, source, 'example', root, pi, target], { encoding: 'utf8' }));
  return { source, root, run, pi };
}

function unzip(file) {
  return JSON.parse(execFileSync('python3', ['-c', `import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    print(json.dumps({p: json.loads(z.read(p)) for p in z.namelist()}))`, file], { encoding: 'utf8' }));
}

for (const [backend, rows] of [['claude', claude], ['codex', codex]]) test(`${backend} ZIP preserves source history and isolates Pi continuations`, t => {
  const { source, run, pi } = setup(t, backend, rows);
  const result = run();
  assert.equal(existsSync(pi), false);
  assert.deepEqual(readFileSync(result.archive), readFileSync(source));
  const continued = run(converter).file;
  appendFileSync(continued, JSON.stringify({ type: 'message', message: { role: 'user', content: 'later Pi secret' } }) + '\n');
  const before = readFileSync(continued);
  assert.deepEqual(run(), result);
  assert.deepEqual(readFileSync(continued), before);
  const zip = unzip(result.file), key = `chat_sessions/${result.id}.json`;
  assert.deepEqual(Object.keys(zip), ['manifest.json', 'chat_session_index.json', key]);
  assert.equal(zip['manifest.json'].export_format_version, 3);
  const { messages } = zip[key];
  assert.deepEqual(messages.map(m => m.role), backend === 'claude' ? ['USER','ASSISTANT','USER','ASSISTANT'] : ['USER','ASSISTANT']);
  assert.match(messages[0].fragments[0].content, /Source history: .*example/);
  for (const [i, m] of messages.entries()) {
    assert.equal(m.parent_id, i ? messages[i - 1].id : null);
    assert.ok(m.fragments.every(f => f.type === (m.role === 'USER' ? 'REQUEST' : 'RESPONSE')));
  }
  const contents = messages.flatMap(m => m.fragments.map(f => f.content)).join('\n');
  assert.doesNotMatch(contents, /later Pi secret/);
  assert.match(contents, /unique question/);
  assert.match(contents, /unique answer/);
  if (backend === 'claude') {
    assert.match(contents, /before call[\s\S]*Source tool call: Read; id=c1[\s\S]*example.txt[\s\S]*Source tool result: Read; id=c1[\s\S]*unique tool output[\s\S]*unique answer/);
    assert.ok(result.warnings.some(w => w.includes('historical text')));
  }
});

test('reports image, source-model accounting and unfinished turn degradation', t => {
  const assistant = native('assistant', 'partial answer');
  assistant.message.stop_reason = 'max_tokens';
  const image = { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'cGljdHVyZQ==' } };
  const { run } = setup(t, 'claude', [assistant, native('user', [image])]);
  const { file, id, archive, warnings } = run();
  for (const warning of ['provenance-only', 'token usage', 'image stored only', 'no-reply'])
    assert.ok(warnings.some(w => w.includes(warning)), warning);
  const doc = unzip(file)[`chat_sessions/${id}.json`];
  assert.match(JSON.stringify(doc.messages), /output token limit/);
  assert.doesNotMatch(JSON.stringify(doc), /cGljdHVyZQ==/);
  assert.match(readFileSync(archive, 'utf8'), /cGljdHVyZQ==/);
});

// Runs inside the installed DSH Node/Electron runtime. Strip types only in the
// importer's shipped TS sources: its public JS entry exports the host service.
async function verifyInstalledImporter() {
  const assert = require('node:assert/strict'), fs = require('node:fs'), mod = require('node:module');
  const { dirname, join } = require('node:path'), { fileURLToPath, pathToFileURL } = require('node:url');
  const [file, workspace] = process.argv.slice(1);
  const anchor = { paths: [process.env.DSH_INSTALL_DIR] };
  const importerRoot = dirname(require.resolve('@deepseek-ai/dsh-deepseek-chat-import/package.json', anchor));
  const sourceUrl = pathToFileURL(join(importerRoot, 'src') + '/').href;
  mod.registerHooks({ load(url, context, next) {
    if (url.startsWith(sourceUrl) && url.endsWith('.ts')) return { shortCircuit: true, format: 'module',
      source: mod.stripTypeScriptTypes(fs.readFileSync(fileURLToPath(url), 'utf8'), { mode: 'transform' }) };
    return next(url, context);
  } });
  const { importDeepseekChatExport } = await import(sourceUrl + 'importer.ts');
  const { Session } = require(require.resolve('@deepseek-ai/dsh-session', anchor));
  let header, events, attached;
  const outcome = await importDeepseekChatExport({
    persistence: { create: async value => {
      header = value;
      return { append: async batch => { events = batch; }, flush: async () => {}, close: async () => {} };
    } }, workspaceRegistered: () => true, createId: require('node:crypto').randomUUID, warn: msg => assert.fail(msg),
  }, { archive: fs.readFileSync(file), workspace: { id: 'isolated', path: workspace, attachSession: async id => { attached = id; } },
    limits: { maxSessions: 1, maxEntryBytes: 256 * 1024 * 1024, maxTitleBytes: 80 }, onProgress: () => {} }, new AbortController().signal);
  assert.deepEqual(outcome.skipped, []);
  assert.deepEqual(outcome.sessionIds, [attached]);
  assert.equal(header.id, attached);
  const session = Session.create(header.id, events, header);
  const messages = session.deriveMessages(); // dsh-agent-loop passes this list as request.messages.
  assert.deepEqual(messages.map(m => m.role), ['user', 'assistant', 'user', 'assistant']);
  assert.match(messages[0].content[0].text, /\]\nunique question$/);
  assert.match(JSON.stringify(messages[1].content), /unique tool output[\s\S]*unique answer/);
  assert.match(JSON.stringify(messages[3].content), /follow-up answer/);
  assert.ok(events.every(e => e.type !== 'tool/call' && e.type !== 'tool/result'));
}

test('installed DSH importer validates the ZIP and projects native Session model history', {
  skip: !process.env.DSH_INSTALL_DIR || !process.env.DSH_NODE_EXECUTABLE ? 'installed DSH runtime is not configured' : false,
}, t => {
  const { root, run } = setup(t, 'claude', claude);
  execFileSync(process.env.DSH_NODE_EXECUTABLE, ['-e', `(${verifyInstalledImporter.toString()})().catch(e => { console.error(e); process.exitCode = 1 })`, run().file, root],
    { env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' }, stdio: ['ignore', 'pipe', 'pipe'] });
});
