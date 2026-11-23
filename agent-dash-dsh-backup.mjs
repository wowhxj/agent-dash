// The Python adapter runs this helper with the installed DSH Node runtime.
// Real session storage is read-only. All writes go into the private staging root.
import { readFileSync, writeFileSync, realpathSync, statSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
const request = JSON.parse(readFileSync(0, 'utf8'));
const require = createRequire(join(process.env.DSH_INSTALL_DIR, 'package.json'));
const pkg = require('./package.json');
if (pkg.name !== '@deepseek-ai/dsh' || pkg.version !== '0.2.2-rc.5') throw Error('DSH adapter requires the verified 0.2.2-rc.5 release');
const sdk = name => require(`@deepseek-ai/${name}`);
const { Context, Service } = sdk('cordis');
const { Session } = sdk('dsh-session');
const fibers = [];
async function mount(ctx, name, config) {
  const pkg = sdk(name), fiber = ctx.plugin(pkg.default ?? pkg, config);
  fibers.push(fiber); await fiber.await();
}
async function backend(root) {
  const ctx = new Context();
  await mount(ctx, 'dsh-session-persistence-jsonl', { root });
  return ctx.sessionPersistence;
}
async function snapshot(store, id) {
  const before = await store.stat(id);
  const file = before?.location?.path;
  if (!file || realpathSync(file) !== file || !statSync(file).isFile() || statSync(file).size > 256 * 1024 * 1024) throw Error('DSH 日志位置或大小无效');
  const h = await store.open(id, 'read');
  try {
    const { events } = await h.read();
    if ((await store.stat(id)).revision !== before.revision) throw Error('DSH session changed during export');
    return { header: h.header, events, inherited: h.inheritedEventCount };
  } finally { await h.close(); }
}
async function run() {
  const real = await backend(join(request.home, 'sessions'));
  if (request.op === 'headers') {
    const headers = {};
    for (const id of request.ids) headers[id] = (await real.stat(id))?.header;
    return headers;
  }
  if (request.op === 'tree') {
    const { resolveSessionTree } = await import('./agent-dash-dsh-tree.mjs');
    let index = 0;
    const tree = await resolveSessionTree(real, request.ids, async (store, id) => {
      const row = await snapshot(store, id);
      const file = String(index++);
      writeFileSync(join(request.stage, file), JSON.stringify(row), { flag: 'wx', mode: 0o600 });
      return { ...row, file, events: row.events.filter(e => e.type === 'subagent/catalog') };
    });
    return { ...tree, rows: tree.rows.map(({file, header, selected, owners}) => ({file, id:header.id, selected, owners})) };
  }
  if (request.op === 'export') {
    const rows = [];
    for (const id of request.ids) rows.push(await snapshot(real, id));
    return rows;
  }
  const stage = await backend(join(request.stage, 'sessions'));
  const selected = new Set();
  const paths = [];
  for (const { header, events, inherited } of request.rows) {
    Session.fromRestore(header.id, events, header, inherited, 'detached');
    const h = await stage.create(header, { inheritedEventCount: inherited });
    try { await h.append(events); await h.flush(); } finally { await h.close(); }
    const check = await snapshot(stage, header.id);
    if (JSON.stringify(check.events) !== JSON.stringify(events)) throw Error('DSH staged event verification failed');
    paths.push((await stage.stat(header.id)).location.path);
    selected.add(header.id);
  }
  // The workspace registry validates *all* of an existing workspace's members
  // when attaching. Feed it the actual target headers with staged IDs overlaid.
  const snapshots = [...(await real.list()).filter(s => !selected.has(s.header.id)),
    ...(await stage.list()).filter(s => s.header.origin !== 'subagent')];
  const ctx = new Context();
  Object.assign(new Service(ctx, 'sessionPersistence'), { list: async () => snapshots });
  await mount(ctx, 'dsh-storage');
  await mount(ctx, 'dsh-storage-json', { root: join(request.stage, 'storages') });
  await mount(ctx, 'dsh-storage-domain', { backend: 'json' });
  await mount(ctx, 'dsh-workspace');
  for (const { header } of request.rows) {
    if (header.origin === 'subagent') continue;
    const w = await ctx.workspaceRegistry.create(header.cwd);
    await w.attachSession(header.id);
    if (!w.sessionIds.includes(header.id)) throw Error('DSH workspace attachment failed');
  }
  return paths;
}
try { const result = await run(); process.stdout.write(JSON.stringify(result)); }
catch (e) { console.error(e.message); process.exitCode = 1; }
finally { for (const f of fibers.reverse()) await f.dispose(); }
