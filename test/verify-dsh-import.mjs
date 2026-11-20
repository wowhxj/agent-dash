// Optional integration check: node test/verify-dsh-import.mjs inside a DSH installation.
import assert from 'node:assert/strict';
import { execFile, execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { basename, dirname, join, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(import.meta.url);
const exporter = fileURLToPath(new URL('../agent-dash-dsh-export.mjs', import.meta.url));
const question = 'Synthetic original question';
const answer = 'Synthetic original answer';
const followup = 'Synthetic following turn';

async function checkStore(phase) {
  // The driver supplies a fresh cwd and a clean environment to each process.
  const root = realpathSync(process.cwd());
  assert.equal(process.env.HOME, root);
  assert.ok(basename(root).startsWith('agent-dash-verify-dsh-'));
  const project = join(root, 'project');
  const req = createRequire(join(process.env.DSH_INSTALL_DIR, 'package.json'));
  const sdk = name => req(`@deepseek-ai/${name}`);
  const { Context, Service } = sdk('cordis');
  const ctx = new Context();
  const mounts = [];
  async function mount(name, config) {
    const pkg = sdk(name);
    const fiber = ctx.plugin(pkg.default ?? pkg, config);
    mounts.push(fiber);
    await fiber.await();
  }
  try {
    await mount('dsh-session-persistence-jsonl', { root: join(root, 'sessions') });
    await mount('dsh-storage');
    await mount('dsh-storage-json', { root: join(root, 'registry') });
    await mount('dsh-storage-domain', { backend: 'json' });
    await mount('dsh-workspace');
    const persistence = ctx.sessionPersistence;
    const identity = join(root, 'identity.json');
    if (phase === 'import') {
      const workspace = await ctx.workspaceRegistry.create(project);
      let route;
      // Capture the official handler at the connection transport boundary. No server or model runs.
      new Service(ctx, 'typert');
      Object.assign(new Service(ctx, 'connection'), { fetch: { register(value) { route = value; return () => {}; } } });
      await mount('dsh-deepseek-chat-import');
      const source = JSON.parse(readFileSync(join(root, 'export.json'), 'utf8'));
      const importer = fileURLToPath(new URL('../agent-dash-dsh-import.mjs', import.meta.url));
      const cookie = 'dsh-auth-test=synthetic';
      // A loopback transport adapter serves the shipped upload handler and reads
      // its real temporary store for the helper's post-import RPC verification.
      const server = createServer(async (req, res) => {
        try {
          assert.equal(req.headers.cookie, cookie);
          const chunks = []; for await (const chunk of req) chunks.push(chunk);
          const body = Buffer.concat(chunks), url = new URL(req.url, 'http://test.invalid');
          if (url.pathname === route.path) {
            const result = await route.fetch(new Request(url, { method: 'POST', headers: req.headers, body }));
            res.writeHead(result.status, Object.fromEntries(result.headers));
            return res.end(await result.text());
          }
          const { method, rpcId, payload: { args } } = JSON.parse(body);
          let value;
          if (method === 'deepseekChatImport/limits') value = { maxUploadBytes: 536870912 };
          else if (method === 'workspace/create') {
            const w = await ctx.workspaceRegistry.resolveByPath(args.request.path);
            value = { workspace: { workspaceId: w.id, path: w.path, sessionIds: w.sessionIds } };
          } else if (method === 'session/list') {
            value = { items: (await persistence.list()).map(({ header }) => ({ sessionId: header.id, cwd: header.cwd, formatStatus: 'current' })) };
          } else if (method === 'session/events') {
            const handle = await persistence.open(args.request.address.sessionId, 'read');
            try {
              const { events } = await handle.read();
              value = { cursor: events.length - 1, hasMore: false, records: events.slice(0, args.request.beforeSeq).map(event => ({ type: 'event', event })) };
            } finally { await handle.close(); }
          } else throw new Error(`Unexpected test RPC ${method}`);
          res.end(JSON.stringify({ rpcId, result: { ok: true, value } }));
        } catch { res.writeHead(500); res.end(); }
      });
      await new Promise(r => server.listen(0, '127.0.0.1', r));
      try {
        const result = await new Promise((resolve, reject) => {
          const proc = execFile(process.execPath, [importer, source.file, project], { env: process.env }, (error, stdout, stderr) => error ? reject(new Error(stderr)) : resolve(JSON.parse(stdout)));
          proc.stdin.end(JSON.stringify({ base: `http://127.0.0.1:${server.address().port}/`, cookie }));
        });
        assert.notEqual(result.id, source.id);
        assert.equal(result.cwd, project);
        assert.equal(result.workspaceId, workspace.id);
        assert.deepEqual(workspace.sessionIds, [result.id]);
        writeFileSync(identity, JSON.stringify({ workspace: workspace.id, id: result.id }));
      } finally { await new Promise(r => server.close(r)); }
      return;
    }
    const { workspace, id } = JSON.parse(readFileSync(identity, 'utf8'));
    assert.deepEqual(ctx.workspaceRegistry.get(workspace).sessionIds, [id]);
    const [stored] = await persistence.list();
    assert.equal(stored.header.id, id);
    assert.equal(stored.header.cwd, project);
    assert.ok(stored.location.path.startsWith(join(root, 'sessions') + sep));
    assert.ok(statSync(stored.location.path).size > 0);
    const handle = await persistence.open(id, phase === 'append' ? 'write' : 'read');
    try {
      const { events, eventState } = await handle.read();
      const session = sdk('dsh-session').Session.fromRestore(id, events, handle.header, handle.inheritedEventCount, eventState);
      const history = session.deriveMessages();
      assert.deepEqual(history.map(m => m.role), phase === 'append' ? ['user', 'assistant'] : ['user', 'assistant', 'user']);
      const texts = history.map(m => m.content.map(b => b.text).join(''));
      assert.ok(texts[0].includes(question));
      assert.ok(texts[1].includes(answer));
      if (phase === 'append') {
        const message = { role: 'user', id: randomUUID(), content: [{ type: 'text', text: followup }], source: { kind: 'user' } };
        const event = session.append('user/message', message, { surfaceOp: 'append' });
        // Cold restore can emit a lifecycle marker before the new user message.
        const appended = session.snapshotEvents(events.length);
        assert.equal(appended.at(-1).seq, event.seq);
        await handle.append(appended);
        await handle.flush();
      } else {
        assert.equal(texts[2], followup);
        console.log(`DSH ${req('./package.json').version}, ${basename(stored.location.path)}, ${events.length} events, restored roles: ${history.map(m => m.role).join(', ')}`);
      }
    } finally { await handle.close(); }
  } finally {
    for (const fiber of mounts.reverse()) await fiber.dispose();
  }
}

if (process.argv.length === 2) {
  const { DSH_INSTALL_DIR, DSH_NODE_EXECUTABLE, PATH } = process.env;
  assert.ok(DSH_INSTALL_DIR && DSH_NODE_EXECUTABLE, 'Run with DSH_INSTALL_DIR and DSH_NODE_EXECUTABLE from the installed DSH runtime');
  const tmp = realpathSync(tmpdir());
  const root = mkdtempSync(join(tmp, 'agent-dash-verify-dsh-'));
  const env = { PATH, HOME: root, TMPDIR: root, DSH_INSTALL_DIR, ELECTRON_RUN_AS_NODE: '1' };
  try {
    const project = join(root, 'project'), source = join(root, 'synthetic.jsonl');
    mkdirSync(project);
    const rows = [['user', question], ['assistant', answer]].map(([role, content]) => ({ type: role, timestamp: '2026-01-01T00:00:00Z', sessionId: 'synthetic', message: { role, content } }));
    writeFileSync(source, rows.map(r => JSON.stringify(r)).join('\n') + '\n');
    const exported = execFileSync(DSH_NODE_EXECUTABLE, [exporter, 'claude', source, 'synthetic', project, join(root, 'pi'), join(root, 'archives')], { cwd: root, env });
    writeFileSync(join(root, 'export.json'), exported);
    for (const phase of ['import', 'append', 'verify']) {
      execFileSync(DSH_NODE_EXECUTABLE, [script, phase], { cwd: root, env, stdio: 'inherit' });
    }
  } finally {
    assert.equal(dirname(realpathSync(root)), tmp);
    assert.ok(basename(root).startsWith('agent-dash-verify-dsh-'));
    rmSync(root, { recursive: true });
  }
} else {
  assert.ok(['import', 'append', 'verify'].includes(process.argv[2]));
  await checkStore(process.argv[2]);
}
