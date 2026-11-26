// Import one agent-dash export into a local DSH Host. Credentials arrive only on stdin.
import { execFileSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
function requireValue(ok, message) { if (!ok) throw new Error(message); }

// Inspect the exact bytes to be posted. The exporter already uses Python's zipfile.
const inspect = `
import hashlib, io, json, re, sys, zipfile
with zipfile.ZipFile(io.BytesIO(sys.stdin.buffer.read())) as z:
    if len(z.infolist()) != 3 or any(f.file_size > 256*1024*1024 for f in z.infolist()):
        raise ValueError('expected one agent-dash conversation')
    if json.loads(z.read('manifest.json'))['export_format_version'] != 3:
        raise ValueError('expected export version 3')
    row, = json.loads(z.read('chat_session_index.json'))
    chat = json.loads(z.read('chat_sessions/' + row['id'] + '.json'))
messages = chat['messages']
if not messages or chat['id'] != row['id'] or chat['current_message_id'] != len(messages):
    raise ValueError('expected a complete conversation')
marker = messages[0]['fragments'][0]['content']
match = re.fullmatch(r'\\[Source history: .+; SHA-256 ([0-9a-f]{64})\\]', marker, re.S)
if not match or messages[0]['role'] != 'USER':
    raise ValueError('missing agent-dash source identity')
expected = []
for i, m in enumerate(messages):
    user = m['role'] == 'USER'
    if (m['id'] != i+1 or m['parent_id'] != (i or None) or m['status'] != 'FINISHED'
        or not user and (m['role'] != 'ASSISTANT' or messages[i-1]['role'] != 'USER')):
        raise ValueError('unsupported message chain')
    if any(f['type'] != ('REQUEST' if user else 'RESPONSE') for f in m['fragments']):
        raise ValueError('unsupported message fragment')
    text = ('\\n' if user else '').join(f['content'] for f in m['fragments'])
    if user and not text.strip(): text = ''
    expected.append([m['role'].lower(), hashlib.sha256(text.encode()).hexdigest()])
print(json.dumps(dict(source=match[1], marker=marker, exportId=chat['id'], messages=expected)))`;

function uploadId(text, workspaceId, cwd) {
  const lines = text.trimEnd().split('\n').map(s => JSON.parse(s));
  const last = lines.pop();
  requireValue(lines.every(l => l.type === 'progress' && Number.isSafeInteger(l.done) && Number.isSafeInteger(l.total)), 'Invalid DSH import progress');
  requireValue(last?.type === 'outcome' && last.outcome?.ok === true, `DSH import outcome: ${last?.outcome?.error?.reason || 'missing'}`);
  const v = last.outcome.value;
  requireValue(v?.workspaceId === workspaceId && v.workspacePath === cwd && v.conversationCount === 1 && v.omittedByLimit === 0 && v.skipped?.length === 0 && v.sessionIds?.length === 1 && typeof v.sessionIds[0] === 'string' && v.sessionIds[0], 'DSH did not confirm exactly one imported session in the selected workspace');
  return v.sessionIds[0];
}

async function run(zip, directory, { base, cookie }) {
  requireValue(/^http:\/\/127\.0\.0\.1:\d+\/$/.test(base) && /^dsh-auth-[\w-]+=[^;\s\x00-\x1f\x7f]+$/.test(cookie), 'Expected local DSH owner connection on stdin');
  const cwd = realpathSync(directory);
  requireValue(statSync(cwd).isDirectory(), 'Expected a workspace directory');
  async function post(path, type, body) {
    const response = await fetch(base + 'api/' + path, { method: 'POST', headers: { cookie, 'content-type': type }, body, redirect: 'error', signal: AbortSignal.timeout(120000) });
    requireValue(response.status === 200, `DSH ${path.split('?')[0]}: HTTP ${response.status}`);
    return response;
  }
  async function rpc(method, args) {
    const rpcId = randomUUID();
    const body = JSON.stringify({ type: 'client-request', rpcId, method, payload: { args } });
    const reply = await (await post(method, 'application/json', body)).json();
    requireValue(reply.rpcId === rpcId && reply.result?.ok === true, `DSH ${method}: ${reply.result?.error?.code || 'invalid response'}`);
    return reply.result.value;
  }
  const bytes = readFileSync(zip);
  const { source, marker, messages, exportId } = JSON.parse(execFileSync('python3', ['-I', '-c', inspect], { input: bytes, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }));
  const getWorkspace = async () => {
    const { workspace } = await rpc('workspace/create', { request: { path: cwd } });
    requireValue(workspace?.path === cwd && typeof workspace.workspaceId === 'string' && workspace.workspaceId && Array.isArray(workspace.sessionIds), 'DSH workspace path or identity mismatch');
    return workspace;
  };
  const workspace = await getWorkspace();
  const { workspaceId } = workspace;
  // The text-only importer writes five events per user turn, one per assistant,
  // plus the initial system head and title. Read only this initial window on reuse.
  const end = 2 + messages.reduce((n, [role]) => n + (role === 'user' ? 5 : 1), 0);
  const list = async () => (await rpc('session/list', { _request: {} })).items;
  const prefix = (id, count) => rpc('session/events', { request: { address: { kind: 'session', sessionId: id }, beforeSeq: count, maxMessages: count + 1 } });
  async function verify(id, ws) {
    requireValue(id !== exportId && ws.workspaceId === workspaceId && ws.sessionIds.includes(id), 'DSH session is outside the selected workspace or has no native identity');
    const items = await list();
    requireValue(items.some(s => s.sessionId === id && s.cwd === cwd && !s.origin && s.formatStatus !== 'migration-required'), 'DSH session cwd or persisted format mismatch');
    const { records, hasMore } = await prefix(id, end);
    requireValue(hasMore === false && records.length === end && records.every((r, i) => r.type === 'event' && r.event?.seq === i), 'Incomplete DSH durable history');
    const actual = [];
    for (const { event } of records) {
      if (!['user/message', 'assistant/message'].includes(event.type)) continue;
      const m = event.type === 'user/message' ? event.data : event.data.message;
      requireValue(event.type === `${m.role}/message` && m.content.every(b => b.type === 'text' && typeof b.text === 'string'), 'Unexpected DSH message type');
      actual.push([m.role, hash(m.content.map(b => b.text).join(''))]);
    }
    requireValue(JSON.stringify(actual) === JSON.stringify(messages), 'DSH history does not match source messages');
    return { id, workspaceId, cwd, zipSha256: hash(bytes) };
  }

  // Also recognize a ZIP previously imported by hand. An ambiguous search or
  // an interrupted upload without a verifiable result must never start a POST.
  const state = join(process.env.XDG_STATE_HOME || join(homedir(), '.local', 'state'), 'agent-dash', 'dsh-imports');
  mkdirSync(state, { recursive: true, mode: 0o700 });
  const claim = join(state, hash(JSON.stringify(marker.includes(' (dialogue v2); SHA-256 ') ? [cwd, source, marker] : [cwd, source])));
  const prior = statSync(claim, { throwIfNoEntry: false });
  if (prior) {
    const id = readFileSync(claim, 'utf8');
    if (id) return verify(id, workspace);
  }
  // session/search needs an enabled full-text index. The official importer puts
  // its first user event at seq 3, even after a rename or a later continuation.
  const items = await list();
  requireValue(workspace.sessionIds.every(id => items.some(s => s.sessionId === id)), 'DSH workspace membership and session list disagree');
  const candidates = [];
  for (const item of items) {
    if (item.cwd !== cwd || item.origin === 'subagent') continue;
    const { records, hasMore, cursor } = await prefix(item.sessionId, 4);
    requireValue(hasMore === false && Number.isSafeInteger(cursor) && records.length === Math.min(cursor + 1, 4) && records.every((r, i) => r.type === 'event' && r.event?.seq === i), 'Incomplete DSH source lookup');
    const first = records[3]?.event;
    if (first?.type === 'user/message' && first.data?.content?.some(b => b.type === 'text' && (b.text === marker || b.text.startsWith(marker + '\n')))) candidates.push(item.sessionId);
  }
  requireValue(candidates.length <= 1, 'Multiple DSH sessions match this source; check the workspace');
  if (candidates.length) {
    const result = await verify(candidates[0], workspace);
    if (!prior) {
      try { writeFileSync(claim, result.id, { flag: 'wx', mode: 0o600, flush: true }); }
      catch (error) { if (error.code !== 'EEXIST') throw error; }
    }
    return result;
  }
  requireValue(!prior, 'Earlier DSH import has no confirmed outcome; upload was not repeated');
  let limits;
  try { limits = await rpc('deepseekChatImport/limits', {}); }
  catch (e) { throw new Error(`${e.message}. Check owner login and enable DeepSeek chat import in DSH Plugins → More.`); }
  requireValue(Number.isSafeInteger(limits?.maxUploadBytes) && bytes.length <= limits.maxUploadBytes, 'ZIP exceeds DSH owner upload limit');
  let fd;
  try { fd = openSync(claim, 'wx', 0o600); }
  catch (e) { if (e.code === 'EEXIST') throw new Error('Another DSH import already claimed this source'); throw e; }
  try {
    const dir = openSync(state, 'r');
    try { fsyncSync(dir); } finally { closeSync(dir); }
    const response = await post('deepseek-chat-import/archive?workspaceId=' + encodeURIComponent(workspaceId), 'application/octet-stream', bytes);
    requireValue(response.headers.get('content-type')?.startsWith('application/x-ndjson'), 'Unexpected DSH import response');
    const id = uploadId(await response.text(), workspaceId, cwd);
    writeFileSync(fd, id); fsyncSync(fd);
    return await verify(id, await getWorkspace());
  } catch (e) {
    throw new Error(`${e.message}. DSH upload may already have written a session. Keep the source; a repeat call only checks the existing import.`);
  } finally { closeSync(fd); }
}

try {
  const args = process.argv.slice(2);
  requireValue(args.length === 2 && args.every(Boolean), 'Usage: node agent-dash-dsh-import.mjs ZIP CWD < owner-connection.json');
  console.log(JSON.stringify(await run(...args, JSON.parse(readFileSync(0, 'utf8')))));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
