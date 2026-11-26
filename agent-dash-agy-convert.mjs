// Capture a saved Antigravity conversation through ACP, then use the shared converter.
import { spawn, execFileSync } from 'node:child_process';
import { linkSync, lstatSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

const backupTool = fileURLToPath(new URL('./agent-dash-agy-backup.py', import.meta.url));

function backup(home, id, file) {
  execFileSync('python3', ['-B', backupTool, 'export', '--home', home, '--id', id, '--output', file],
    { stdio: ['ignore', 'pipe', 'pipe'] });
}

function compareBackups(a, b) {
  execFileSync('python3', ['-c', `
import json, sys, zipfile
def manifest(path):
    with zipfile.ZipFile(path) as z:
        if z.testzip() is not None: raise ValueError('Invalid native backup')
        return json.loads(z.read('manifest.json'))
if manifest(sys.argv[1]) != manifest(sys.argv[2]):
    sys.exit('Antigravity source or its native backup changed; source retained')
`, a, b], { stdio: ['ignore', 'pipe', 'pipe'] });
}

async function snapshot(executable, home, id, cwd) {
  const child = spawn(executable, ['acp', '--gemini-dir', dirname(home), '--app-data-dir', basename(home)], { cwd, stdio: ['pipe', 'pipe', 'ignore'] });
  const closed = new Promise(resolve => child.once('close', resolve));
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
    await closed;
  }
}

const scripts = { pi: './agent-dash-convert.mjs', export: './agent-dash-dsh-export.mjs',
  dsh: './agent-dash-dsh-migrate.mjs' };
try {
  const args = process.argv.slice(2);
  const move = args.at(-1) === '--move';
  if (move) args.pop();
  const [destination, executable, homeArg, id, cwd, pi, archives] = args;
  if (args.length !== 7 || !Object.hasOwn(scripts, destination) || (move && destination === 'export'))
    throw new Error('Usage: node agent-dash-agy-convert.mjs pi|dsh|export AGY HOME SESSION_ID PROJECT PI_DIR ARCHIVE_DIR [--move]');
  const home = resolve(homeArg);
  const temp = mkdtempSync(join(tmpdir(), 'agent-dash-agy-'));
  try {
    const original = join(temp, 'original.zip');
    let backupError;
    if (move) {
      try { backup(home, id, original); }
      catch (error) { backupError = error; }
    }
    const records = await snapshot(executable, home, id, cwd);
    const file = join(temp, 'snapshot.jsonl');
    writeFileSync(file, records.map(record => JSON.stringify(record)).join('\n') + '\n', { mode: 0o600 });
    const script = fileURLToPath(new URL(scripts[destination], import.meta.url));
    const output = execFileSync(process.execPath, [script, 'agy', file, id, cwd, pi, archives], {
      input: destination === 'dsh' ? readFileSync(0) : undefined, stdio: ['pipe', 'pipe', 'pipe'],
      maxBuffer: 16 * 1024 * 1024,
    });
    const report = JSON.parse(output);
    if (move) {
      report.migrationBackend = 'agy';
      try {
        if (backupError) throw backupError;
        const archive = report.archive.replace(/\.jsonl$/, '-native.zip');
        const stage = join(dirname(archive), `.agy-backup-${randomUUID()}.zip`);
        try {
          backup(home, id, stage);
          compareBackups(original, stage);
          try { linkSync(stage, archive); }
          catch (error) { if (error.code !== 'EEXIST') throw error; }
          if (!lstatSync(archive).isFile()) throw new Error('Expected a regular native backup');
          compareBackups(original, archive);
          report.nativeBackup = archive;
        } finally { rmSync(stage, { force: true }); }
        const retired = execFileSync('python3', ['-B', backupTool, 'retire', '--home', home,
          '--id', id, '--input', archive], { stdio: ['ignore', 'pipe', 'pipe'] });
        report.nativeHolding = JSON.parse(retired).holding;
        report.migration = 'moved';
      } catch (error) {
        report.migration = 'retained';
        report.migrationError = error.stderr?.toString().trim() || error.message;
      }
    }
    console.log(JSON.stringify(report));
  } finally { rmSync(temp, { recursive: true, force: true }); }
} catch (error) {
  console.error(error.stderr?.toString().trim() || error.message);
  process.exitCode = 1;
}
