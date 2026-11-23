// Synthetic DSH fixture, using the installed distribution and isolated roots only.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdirSync, realpathSync, statSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { basename, dirname, join, sep } from 'node:path';

const [operation, homeArg, id, cwdArg] = process.argv.slice(2);
assert.ok(['seed', 'append', 'read'].includes(operation));
assert.ok(process.env.DSH_INSTALL_DIR);
const home = realpathSync(homeArg);
assert.equal(dirname(home), realpathSync(tmpdir()));
assert.ok(basename(home).startsWith('agent-dash-dsh-fixture-'));
assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
const cwd = realpathSync(cwdArg);
assert.ok(cwd.startsWith(home + sep) && statSync(cwd).isDirectory());
const req = createRequire(join(process.env.DSH_INSTALL_DIR, 'package.json'));
const sdk = name => req(`@deepseek-ai/${name}`);
const { Context } = sdk('cordis');
const { Session, SESSION_FORMAT_VERSION } = sdk('dsh-session');
const ctx = new Context(), fibers = [];
async function mount(name, config) {
  const pkg = sdk(name), fiber = ctx.plugin(pkg.default ?? pkg, config);
  fibers.push(fiber); await fiber.await();
}
try {
  mkdirSync(join(home, 'sessions'), { recursive: true });
  await mount('dsh-session-persistence-jsonl', { root: join(home, 'sessions') });
  await mount('dsh-storage');
  await mount('dsh-storage-json', { root: join(home, 'storages') });
  await mount('dsh-storage-domain', { backend: 'json' });
  await mount('dsh-workspace');
  const p = ctx.sessionPersistence;
  if (operation === 'seed') {
    const header = { version: SESSION_FORMAT_VERSION, id, createdAt: Date.now(), cwd, isSeeded: false, delegationDepth: 0 };
    const handle = await p.create(header);
    try {
      const session = Session.create(id, [], header);
      session.append('user/message', { role: 'user', id: randomUUID(), content: [{ type: 'text', text: 'fixture initial message' }], source: { kind: 'user' } }, { surfaceOp: 'append' });
      await handle.append(session.snapshotEvents(0)); await handle.flush();
    } finally { await handle.close(); }
    const workspace = await ctx.workspaceRegistry.create(cwd);
    await workspace.attachSession(id);
  } else {
    const handle = await p.open(id, operation === 'append' ? 'write' : 'read');
    try {
      const { events, eventState } = await handle.read();
      const session = Session.fromRestore(id, events, handle.header, handle.inheritedEventCount, eventState);
      if (operation === 'append') {
        session.append('user/message', { role: 'user', id: randomUUID(), content: [{ type: 'text', text: 'fixture appended message' }], source: { kind: 'user' } }, { surfaceOp: 'append' });
        await handle.append(session.snapshotEvents(events.length)); await handle.flush();
      } else {
        const workspace = await ctx.workspaceRegistry.resolveByPath(cwd);
        assert.ok(workspace?.sessionIds.includes(id));
        console.log(JSON.stringify({ id: handle.header.id, cwd: handle.header.cwd, messages: session.deriveMessages().map(m => m.content.map(b => b.text).join('')) }));
      }
    } finally { await handle.close(); }
  }
} finally { for (const fiber of fibers.reverse()) await fiber.dispose(); }
