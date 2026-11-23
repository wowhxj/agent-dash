// Run with ELECTRON_RUN_AS_NODE=1 "$DSH_NODE_EXECUTABLE" test/verify-dsh-tree.mjs.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdir, mkdtempDisposable, readFile, realpath } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { resolveSessionTree } from '../agent-dash-dsh-tree.mjs';

const require = createRequire(join(process.env.DSH_INSTALL_DIR, 'package.json'));
assert.equal(require('./package.json').version, '0.2.2-rc.5');
const { Context } = require('@deepseek-ai/cordis');
const { Session, SESSION_FORMAT_VERSION, buildForkSeed } = require('@deepseek-ai/dsh-session');
const persistence = require('@deepseek-ai/dsh-session-persistence-jsonl');
const { SessionPersistenceNotFoundError } = require('@deepseek-ai/dsh-session-persistence');
await using fixture = await mkdtempDisposable(join(await realpath(tmpdir()), 'agent-dash-dsh-tree-'));
const fibers = [];

async function backend(name) {
  const ctx = new Context();
  const fiber = ctx.plugin(persistence.default ?? persistence, { root: join(fixture.path, name, 'sessions') });
  fibers.push(fiber);
  await fiber.await();
  return ctx.sessionPersistence;
}

function create({ id = randomUUID(), prefix = [], parent, historicalParent, depth = 0 } = {}) {
  const header = { id, version: SESSION_FORMAT_VERSION, createdAt: Date.now(), cwd: fixture.path,
    isSeeded: prefix.length > 0, delegationDepth: depth };
  if (parent) Object.assign(header, { origin: 'subagent', parentSession: parent });
  if (historicalParent) header.parentSession = historicalParent;
  return Session.create(id, prefix.length ? buildForkSeed(prefix, prefix.length - 1) : undefined, header, prefix.length);
}

function message(session, text) {
  session.append('user/message', { role: 'user', id: randomUUID(), content: [{ type: 'text', text }],
    source: { kind: 'user' } }, { surfaceOp: 'append' });
}

function catalogue(parent, child, name, mode = 'continuable') {
  parent.append('subagent/catalog', { version: 3, childId: child, childCreatedAt: Date.now(),
    mode, label: name, name });
}

async function write(store, { header, events, inherited }) {
  const handle = await store.create(header, { inheritedEventCount: inherited });
  try {
    await handle.append(events);
    await handle.flush();
  } finally {
    await handle.close();
  }
}

async function snapshot(store, id) {
  const before = await store.stat(id);
  if (!before) throw new SessionPersistenceNotFoundError(id);
  const handle = await store.open(id, 'read');
  try {
    const { events } = await handle.read();
    assert.equal((await store.stat(id)).revision, before.revision);
    return { header: handle.header, events, inherited: handle.inheritedEventCount };
  } finally {
    await handle.close();
  }
}

function backup(command, home, ...args) {
  const helper = fileURLToPath(new URL('../agent-dash-dsh-backup.py', import.meta.url));
  return JSON.parse(execFileSync('python3', ['-B', helper, command, '--home', join(fixture.path, home), ...args], { encoding: 'utf8' }));
}

try {
  await mkdir(join(fixture.path, 'source'));
  await mkdir(join(fixture.path, 'target'));
  const source = await backend('source');
  const parent = create();
  message(parent, 'parent history');
  const child = create({ parent: parent.id, depth: 1, prefix: parent.snapshotEvents() });
  catalogue(parent, child.id, 'child');
  const missingChild = randomUUID();
  const externalId = 'remote/external';
  catalogue(parent, missingChild, 'missing');
  catalogue(parent, externalId, 'external', 'external');
  child.append('subagent/descriptor', { version: 3, mode: 'continuable', provider: 'fork', label: 'child' });
  message(child, 'child history');
  // A persisted child can predate its parent's discovery event (e.g. a crash).
  const grandchild = create({ parent: child.id, depth: 2 });
  message(grandchild, 'grandchild history');
  const missingParent = randomUUID();
  const orphan = create({ parent: missingParent, depth: 1 });
  message(orphan, 'orphan history');
  const fork = create({ id: `session-${randomUUID()}`, prefix: parent.snapshotEvents() });
  message(fork, 'ordinary fork history');
  const historical = create({ id: `session-${randomUUID()}`, prefix: parent.snapshotEvents(), historicalParent: parent.id });
  message(historical, 'older fork history');

  const sessions = [parent, child, grandchild, orphan, fork, historical];
  for (const session of sessions) {
    await write(source, { header: session.header, events: session.snapshotEvents(), inherited: session.inheritedEventCount });
  }
  assert.equal((await resolveSessionTree(source, [fork.id], snapshot)).rows.length, 1);
  assert.equal((await resolveSessionTree(source, [historical.id], snapshot)).rows.length, 1);
  await assert.rejects(resolveSessionTree(source, [missingChild], snapshot), SessionPersistenceNotFoundError);
  const fallback = await resolveSessionTree({ async list() { throw Error('fixture scan failed'); } },
    [parent.id], (_store, id) => snapshot(source, id));
  assert.deepEqual(fallback.rows.map(row => row.header.id), [parent.id, child.id]);
  assert.ok(fallback.warnings.some(warning => warning.includes('fixture scan failed')));

  const selected = [parent.id, child.id, fork.id, orphan.id];
  const { rows, warnings } = await resolveSessionTree(source, selected, snapshot);
  assert.deepEqual(rows.map(row => row.header.id), [...selected, grandchild.id]);
  assert.deepEqual(rows.map(row => row.selected), [true, true, true, true, false]);
  assert.deepEqual(rows.map(row => row.owners), [[parent.id, child.id], [parent.id, child.id], [fork.id],
    [orphan.id], [parent.id, child.id]]);
  assert.equal(warnings.length, 2);
  assert.ok(warnings.some(warning => warning.includes(missingChild)));
  assert.ok(warnings.some(warning => warning.includes(missingParent)));
  assert.equal(rows.find(row => row.header.id === fork.id).inherited, parent.snapshotEvents().length);
  assert.equal(rows.find(row => row.header.id === child.id).inherited, 1);

  const archive = join(fixture.path, 'sessions.zip');
  const input = ['--input', archive];
  const exported = backup('export', 'source', '--output', archive, ...selected.flatMap(id => ['--id', id]));
  assert.equal(exported.count, selected.length);
  for (const id of [missingChild, missingParent]) {
    assert.ok(exported.warnings.some(warning => warning.includes(id) && warning.includes('已保留现存历史')));
  }
  const busy = backup('preview', 'target', ...input, '--active-id', grandchild.id);
  const busyActions = new Map(busy.sessions.map(item => [item.id, item.action]));
  assert.equal(busyActions.get(parent.id), 'busy');
  assert.equal(busyActions.get(child.id), 'busy');
  assert.equal(busyActions.get(fork.id), 'create');
  const preview = backup('preview', 'target', ...input);
  backup('import', 'target', ...input, '--preview-token', preview.preview_token);
  const membership = JSON.parse(await readFile(join(fixture.path, 'target', 'storages', 'workspace.json'), 'utf8'));
  const attached = Object.values(membership.tables.workspaces).flatMap(workspace => workspace.sessionIds);
  assert.deepEqual(new Set(attached), new Set([parent.id, fork.id]));
  const reopened = await backend('target');
  assert.deepEqual(await resolveSessionTree(reopened, selected, snapshot), { rows, warnings });
  const restoredFork = await snapshot(reopened, fork.id);
  const restored = Session.fromRestore(fork.id, restoredFork.events, restoredFork.header, restoredFork.inherited, 'detached');
  assert.deepEqual(restored.deriveMessages().map(message => message.content[0].text), ['parent history', 'ordinary fork history']);
  console.log('DSH tree fixture passed');
} finally {
  for (const fiber of fibers.reverse()) await fiber.dispose();
}
