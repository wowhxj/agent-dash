import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { migrate } from '../agent-dash-dsh-migrate.mjs';

const helper = fileURLToPath(new URL('../agent-dash-agy-convert.mjs', import.meta.url));
const fixture = `#!/usr/bin/env node
const lines = require('node:readline').createInterface({ input: process.stdin });
const send = value => console.log(JSON.stringify({ jsonrpc: '2.0', ...value }));
const update = (sessionId, payload) => send({ method: 'session/update', params: { sessionId, update: payload } });
lines.on('line', line => {
  const { id, method, params } = JSON.parse(line);
  if (method === 'initialize') return send({ id, result: { protocolVersion: 1 } });
  if (method === 'session/list') return send({ id, result: params.cursor ? { sessions: [
    { sessionId: process.env.AGY_FIXTURE_ID || 'source', cwd: '/old/project', title: 'conversation', updatedAt: '2026-11-26T00:00:00Z' }
  ] } : { sessions: [], nextCursor: 'next' } });
  if (method !== 'session/load') throw new Error('unexpected method');
  const { sessionId } = params;
  update('another-session', { sessionUpdate: 'user_message_chunk', content: { type: 'text', text: 'unrelated' } });
  update(sessionId, { sessionUpdate: 'user_message_chunk', content: { type: 'text', text: 'Hello ' } });
  update(sessionId, { sessionUpdate: 'user_message_chunk', content: { type: 'text', text: 'world' } });
  update(sessionId, { sessionUpdate: 'user_message_chunk', content: { type: 'image', mimeType: 'image/png', data: 'uw==' } });
  update(sessionId, { sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: 'Think' } });
  update(sessionId, { sessionUpdate: 'tool_call', toolCallId: 'tool-1', name: 'read', args: { file: 'fixture' } });
  update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: 'tool-1', status: 'completed', rawOutput: { result: 'done' } });
  update(sessionId, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Done' } });
  send({ id, result: { sessionId, models: { currentModelId: 'gemini-test' } } });
});
`;

test('Antigravity ACP replay converts to Pi and a verifiable DSH import without retiring its source', t => {
  const base = realpathSync(mkdtempSync(join(tmpdir(), 'dash-agy-conversion-')));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const executable = join(base, 'fake-agy');
  const project = join(base, 'new project');
  const native = join(base, 'home with spaces'), pi = join(base, 'pi'), archives = join(base, 'archives');
  mkdirSync(project);
  writeFileSync(executable, fixture, { mode: 0o700 });
  const run = destination => JSON.parse(execFileSync(process.execPath,
    [helper, destination, executable, native, 'source', project, pi, archives]));
  const out = run('pi');
  assert.equal(run('pi').id, out.id);
  const entries = readFileSync(out.file, 'utf8').trim().split('\n').map(line => JSON.parse(line));
  assert.equal(entries[0].cwd, project);
  assert.equal(entries[1].data.backend, 'agy');
  const messages = entries.slice(2).map(entry => entry.message);
  assert.deepEqual(messages.map(message => message.role), ['user', 'assistant', 'assistant']);
  assert.deepEqual(messages[0].content, [{ type: 'text', text: 'Hello world' },
    { type: 'image', mimeType: 'image/png', data: 'uw==' }]);
  assert.equal(messages[1].content[0].thinking, 'Think');
  assert.equal(messages[2].model, 'gemini-test');
  assert.equal(messages[2].content[0].text, 'Done');
  const exported = run('export');
  const source = readFileSync(out.archive);
  assert.doesNotMatch(source.toString(), /unrelated/);
  assert.match(source.toString(), /rawOutput/);
  const zip = JSON.parse(execFileSync('python3', ['-c',
    'import sys, zipfile; z=zipfile.ZipFile(sys.argv[1]); print(z.read(sys.argv[2]).decode())',
    exported.file, `chat_sessions/${exported.id}.json`]));
  assert.deepEqual(zip.messages[1].fragments, [{ type: 'RESPONSE', content: 'Done' }]);
  assert.equal(zip.messages[0].fragments[1].content, 'Hello world');
  const imported = migrate(['agy', out.archive, 'source', project, pi, archives], '', zip => ({
    id: 'native-target', workspaceId: 'workspace', cwd: project,
    zipSha256: createHash('sha256').update(readFileSync(zip)).digest('hex'),
  }));
  assert.equal(imported.id, 'native-target');
  assert.equal(imported.file, exported.file);
  assert.equal(imported.migration, undefined);
  assert.deepEqual(readFileSync(out.archive), source);
});


test('Antigravity migration keeps its source on DSH failure and retires it after Pi publication', t => {
  const base = realpathSync(mkdtempSync(join(tmpdir(), 'dash-agy-move-')));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const executable = join(base, 'fake-agy');
  const home = join(base, 'profile'), pi = join(base, 'pi'), archives = join(base, 'archives');
  const id = '00000000-0000-4000-8000-000000000001';
  mkdirSync(join(home, 'conversations'), { recursive: true });
  writeFileSync(executable, fixture, { mode: 0o700 });
  const db = join(home, 'conversations', `${id}.db`);
  execFileSync('python3', ['-c', `
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.executescript('pragma user_version=1; create table trajectory_meta(cascade_id text);')
    db.execute('insert into trajectory_meta values (?)', (sys.argv[2],))`, db, id]);
  const run = destination => JSON.parse(execFileSync(process.execPath,
    [helper, destination, executable, home, id, base, pi, archives, '--move'],
    { env: { ...process.env, AGY_FIXTURE_ID: id }, input: '{}' }));
  assert.throws(() => run('dsh'), /local DSH owner connection/);
  assert.ok(existsSync(db));
  const report = run('pi');
  assert.equal(report.migration, 'moved', report.migrationError);
  assert.ok(!existsSync(db));
  assert.ok(existsSync(report.file));
  assert.ok(existsSync(report.nativeBackup));
  assert.ok(existsSync(join(report.nativeHolding, 'conversations', `${id}.db`)));
});
