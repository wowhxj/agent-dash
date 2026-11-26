// Capture a saved Antigravity conversation through ACP, then use the shared converter.
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

async function snapshot(executable, home, id, cwd) {
  const child = spawn(executable, ['acp', '--gemini-dir', dirname(home), '--app-data-dir', basename(home)], { cwd, stdio: ['pipe', 'pipe', 'ignore'] });
  const lines = createInterface({ input: child.stdout });
  const records = [];
  let pending, requestId = 0, replayBytes = 0;
  const fail = error => pending?.reject(error);
  child.on('error', fail);
  child.stdin.on('error', fail);
  child.stdout.on('error', fail);
  child.on('exit', code => fail(new Error(`agy ACP exited (${code}) before replying`)));
  lines.on('line', line => {
    if (!pending || !line.trim()) return;
    try {
      const record = JSON.parse(line);
      if (record.id === pending.id && !record.method) {
        if (record.error) throw new Error(`agy ACP: ${record.error.message}`);
        pending.resolve(record.result);
      } else if (record.method === 'session/update' && record.params?.sessionId === id && pending.replay) {
        replayBytes += Buffer.byteLength(line) + 1;
        if (replayBytes > 256 * 1024 * 1024) throw new Error('Antigravity replay exceeds 256 MiB');
        records.push(record);
      } else if (record.method && record.id != null) {
        child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: record.id,
          error: { code: -32601, message: 'Session export is read only' } }) + '\n');
      }
    } catch (error) { fail(error); }
  });
  async function rpc(method, params, replay = false) {
    const id = String(++requestId);
    let timer;
    try {
      return await new Promise((resolve, reject) => {
        pending = { id, resolve, reject, replay };
        timer = setTimeout(() => reject(new Error(`agy ACP did not answer ${method}`)), 30000);
        child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
      });
    } finally { clearTimeout(timer); pending = undefined; }
  }
  try {
    await rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
    let cursor, row;
    const cursors = new Set();
    do {
      const page = await rpc('session/list', cursor ? { cursor } : {});
      row = page?.sessions?.find(session => session.sessionId === id);
      cursor = page?.nextCursor;
      if (cursor && cursors.has(cursor)) throw new Error('agy ACP repeated a session list cursor');
      cursors.add(cursor);
    } while (!row && cursor);
    if (!row) throw new Error(`Antigravity session not found: ${id}`);
    const result = await rpc('session/load', { sessionId: id, cwd, mcpServers: [] }, true);
    if (result?.sessionId !== id) throw new Error('Antigravity history returned a different session ID');
    const model = result.configOptions?.find(option => option.category === 'model')?.currentValue;
    return [{ type: 'agy_session', sessionId: id, cwd: row.cwd, title: row.title,
      timestamp: row.updatedAt, model: model ?? result.models?.currentModelId }, ...records];
  } finally {
    lines.close();
    child.stdin.end();
    child.kill();
  }
}

const scripts = { pi: './agent-dash-convert.mjs', export: './agent-dash-dsh-export.mjs',
  dsh: './agent-dash-dsh-migrate.mjs' };
try {
  const [destination, executable, home, id, cwd, pi, archives] = process.argv.slice(2);
  if (process.argv.length !== 9 || !Object.hasOwn(scripts, destination))
    throw new Error('Usage: node agent-dash-agy-convert.mjs pi|dsh|export AGY HOME SESSION_ID PROJECT PI_DIR ARCHIVE_DIR');
  const records = await snapshot(executable, home, id, cwd);
  const temp = mkdtempSync(join(tmpdir(), 'agent-dash-agy-'));
  try {
    const file = join(temp, 'snapshot.jsonl');
    writeFileSync(file, records.map(record => JSON.stringify(record)).join('\n') + '\n', { mode: 0o600 });
    const script = fileURLToPath(new URL(scripts[destination], import.meta.url));
    const output = execFileSync(process.execPath, [script, 'agy', file, id, cwd, pi, archives], {
      input: destination === 'dsh' ? readFileSync(0) : undefined, stdio: ['pipe', 'pipe', 'pipe'],
      maxBuffer: 16 * 1024 * 1024,
    });
    process.stdout.write(output);
  } finally { rmSync(temp, { recursive: true, force: true }); }
} catch (error) {
  console.error(error.stderr?.toString().trim() || error.message);
  process.exitCode = 1;
}
