// Offline import of a native transcript snapshot into a Pi v3 session.
import { constants as F, closeSync, fstatSync, linkSync, lstatSync, mkdirSync, openSync,
  mkdtempSync, readFileSync, realpathSync, renameSync, rmdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { execFileSync, spawnSync } from 'node:child_process';
import * as zlib from 'node:zlib';

const digest = data => createHash('sha256').update(data).digest('hex');
const text = value => ({ type: 'text', text: value });
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const nonempty = value => typeof value === 'string' && value.length > 0;
const claudeAdministration = new Set(['last-prompt', 'mode', 'permission-mode', 'atis-latch', 'file-history-snapshot',
  'api-request-shape', 'api-request-blob', 'api-request', 'cost-state', 'session-owner', 'ai-title', 'tools-used',
  'file-history-delta', 'worktree-state', 'relocated']);
const claudeSystemAdministration = new Set(['turn_duration', 'compact_boundary', 'stop_hook_summary']);
const claudeContextAttachments = new Set(['hook_success', 'environment', 'model', 'output_style_instructions',
  'deferred_tools_delta', 'agent_listing_delta', 'mcp_instructions_delta', 'skill_listing', 'total_tokens_reminder',
  'output_style', 'hook_additional_context', 'instructions', 'session_context', 'date', 'credential_org',
  'remote_session_change', 'prompt_snapshot', 'auto_mode', 'silent_turn_reminder', 'deferred_tools_record',
  'command_permissions']);

export const openRegular = path => openSync(path, F.O_RDONLY | F.O_NOFOLLOW | F.O_NONBLOCK);
function regularFile(path, pinnedFd) {
  const fd = pinnedFd ?? openRegular(path);
  try {
    const before = fstatSync(fd, { bigint: true });
    if (!before.isFile()) throw new Error(`Expected a regular file: ${path}`);
    const bytes = readFileSync(fd), after = fstatSync(fd, { bigint: true });
    // Publishing with link/unlink changes ctime and link count, even when the bytes stay identical.
    if (before.size !== BigInt(bytes.length) || before.size !== after.size || before.mtimeNs !== after.mtimeNs)
      throw new Error(`File changed while reading, retry import: ${path}`);
    return bytes;
  } finally { if (pinnedFd === undefined) closeSync(fd); }
}

// link() publishes a complete file atomically and cannot replace a concurrent import or Pi edits.
function publish(path, bytes, matches = existing => existing.equals(bytes)) {
  const tmp = join(dirname(path), `.agent-dash-${randomUUID()}.tmp`);
  const fd = openSync(tmp, 'wx', 0o600);
  try {
    writeFileSync(fd, bytes);
    try { linkSync(tmp, path); }
    catch (err) {
      if (err.code !== 'EEXIST') throw err;
      const existing = regularFile(path);
      if (!matches(existing))
        throw new Error(`Existing file differs from the import: ${path}`);
    }
  } finally { closeSync(fd); unlinkSync(tmp); }
}

// Only the diagnostics in the import marker may differ between converter versions.
function matchesImport(existing, entries) {
  let offset = 0;
  for (const entry of entries) {
    const end = existing.indexOf(10, offset);
    if (end < 0) return false;
    const line = existing.subarray(offset, end);
    let expected = entry;
    if (entry.type === 'custom') {
      let warnings;
      try { warnings = JSON.parse(line).data.warnings; } catch { return false; }
      if (!Array.isArray(warnings) || !warnings.every(w => typeof w === 'string')) return false;
      expected = { ...entry, data: { ...entry.data, warnings } };
    }
    if (!line.equals(Buffer.from(JSON.stringify(expected)))) return false;
    offset = end + 1;
  }
  return true;
}

function directory(path) {
  mkdirSync(path, { recursive: true, mode: 0o700 });
  if (!lstatSync(path).isDirectory()) throw new Error(`Expected a directory: ${path}`);
  return realpathSync(path);
}

function blocks(value, warn, role) {
  if (typeof value === 'string') return value ? [text(value)] : [];
  if (!Array.isArray(value)) { warn('missing message content'); return []; }
  return value.flatMap(b => {
    if (['text', 'input_text', 'output_text', 'summary_text'].includes(b?.type) && typeof b.text === 'string') return [text(b.text)];
    if (role === 'assistant' && b?.type === 'thinking' && typeof b.thinking === 'string')
      return [{ type: 'thinking', thinking: b.thinking }];
    if (role !== 'assistant') {
      const url = b?.type === 'input_image' && typeof b.image_url === 'string' && /^data:(image\/[\w.+-]+);base64,([\s\S]+)$/.exec(b.image_url);
      if (url) return [{ type: 'image', data: url[2], mimeType: url[1] }];
      if (b?.type === 'image' && b.source?.type === 'base64' && nonempty(b.source.data) && /^image\//.test(b.source.media_type))
        return [{ type: 'image', data: b.source.data, mimeType: b.source.media_type }];
    }
    warn(`archived content block ${b?.type ?? '(missing type)'}`);
    return [];
  });
}

function toolCall(id, name, args, warn) {
  if (typeof args === 'string') { try { args = JSON.parse(args); } catch { args = null; } }
  if (!nonempty(id) || !nonempty(name) || !object(args)) { warn('archived malformed tool call'); return []; }
  return [{ type: 'toolCall', id, name, arguments: args }];
}

function usage(native = {}) {
  const number = key => Number.isFinite(native?.[key]) ? native[key] : 0;
  const input = number('input_tokens'), output = number('output_tokens');
  const cacheRead = number('cache_read_input_tokens'), cacheWrite = number('cache_creation_input_tokens');
  return { input, output, cacheRead, cacheWrite, totalTokens: input + output + cacheRead + cacheWrite,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
}

// Pi providers expect one assistant tool-call group followed by its result messages.
// Native Codex records serialize parallel calls separately. Only emit proven pairs.
function pairTools(messages, warn) {
  const out = [], used = new Set();
  for (let i = 0; i < messages.length;) {
    const m = messages[i++];
    if (m.role === 'toolResult') { warn('archived orphan tool result'); continue; }
    if (m.role !== 'assistant' || !m.content.some(b => b.type === 'toolCall')) { out.push(m); continue; }
    while (messages[i]?.role === 'assistant' && messages[i].content.some(b => b.type === 'toolCall')) {
      m.content.push(...messages[i++].content);
    }
    const calls = new Map(), paired = new Map();
    for (const b of m.content) if (b.type === 'toolCall' && !used.has(b.id) && !calls.has(b.id)) calls.set(b.id, b);
    while (messages[i]?.role === 'toolResult') {
      const r = messages[i++], call = calls.get(r.toolCallId);
      if (!call || paired.has(call.id)) { warn('archived orphan or duplicate tool result'); continue; }
      r.toolName = call.name;
      paired.set(call.id, r);
    }
    m.content = m.content.filter(b => {
      if (b.type !== 'toolCall') return true;
      if (calls.get(b.id) !== b || !paired.has(b.id)) { warn('archived unpaired or duplicate tool call'); return false; }
      used.add(b.id);
      return true;
    });
    m.stopReason = paired.size ? 'toolUse' : 'stop';
    if (m.content.length) out.push(m, ...paired.values());
  }
  return out;
}

function claudeBranch(rows, warn) {
  const turns = rows.filter(r => !r.isSidechain && ['user', 'assistant'].includes(r.type));
  if (!turns.some(r => 'parentUuid' in r)) return rows;
  if (turns.some(r => !nonempty(r.uuid) || !('parentUuid' in r))) throw new Error('Incomplete Claude branch identifiers');
  const nodes = new Map();
  for (const r of rows) if (nonempty(r.uuid)) {
    if (nodes.has(r.uuid) && nodes.get(r.uuid).parentUuid !== r.parentUuid) throw new Error('Conflicting Claude branch identifiers');
    nodes.set(r.uuid, r);
  }
  const active = new Set();
  let node = turns.at(-1);
  while (node) {
    if (active.has(node.uuid)) throw new Error('Cycle in Claude branch');
    active.add(node.uuid);
    if (node.parentUuid == null) break;
    node = nodes.get(node.parentUuid);
    if (!node) throw new Error('Missing Claude branch parent');
  }
  const compacted = rows.some(r => r.type === 'system' && r.subtype === 'compact_boundary');
  return rows.filter(r => {
    if (!['assistant', 'user'].includes(r.type) || r.isSidechain || active.has(r.uuid)) return true;
    warn('archived Claude message outside the final parentUuid chain' + (compacted ? ' (source contains compact_boundary)' : ''));
    return false;
  });
}

// Check the whole source so an ordinary prompt outside the selected chain still counts.
function claudeCommandOnly(rows) {
  let foundCommand = false;
  for (const r of rows) {
    if (r.type === 'system' && r.subtype === 'local_command') { foundCommand = true; continue; }
    if (!['user', 'assistant'].includes(r.type)) continue;
    const content = r.message?.content;
    const parts = Array.isArray(content) ? content : [text(content)];
    for (const b of parts) {
      const value = b?.type === 'text' && typeof b.text === 'string' ? b.text.trim() : undefined;
      if (value?.startsWith('<') && !value.replace(/<(command-name|command-message|command-args|local-command-stdout|local-command-stderr|local-command-caveat)>[\s\S]*?<\/\1>/g, '').trim()) {
        if (/<(?:command-name|local-command-stdout)>/.test(value)) foundCommand = true;
      } else if (!r.isMeta && value !== '') return false;
    }
  }
  return foundCommand;
}

function codexBranch(rows, warn, archive) {
  let active = [], metadata = [], checkpoint = false, pendingMarker = false;
  const reject = reason => { throw new Error(`Codex ${reason}. Original archived at ${archive}`); };
  // A later full checkpoint supersedes all previous rewrites, including rollbacks.
  let start = -1;
  for (let i = 0; i < rows.length; i++) {
    const p = rows[i].payload;
    if (rows[i].type === 'compacted' && Array.isArray(p?.replacement_history)) start = i;
  }
  if (start >= 0) {
    const r = rows[start], history = r.payload.replacement_history;
    if (!history.every(item => object(item) && nonempty(item.type))) reject('invalid compaction replacement_history');
    metadata = rows.slice(0, start).filter(row => ['session_meta', 'turn_context'].includes(row.type));
    active = history.map(payload => ({ type: 'response_item', timestamp: r.timestamp, payload }));
    warn(`earlier Codex history archived; active context restored from replacement_history (${history.length} items, checkpoint timestamp used)`);
    checkpoint = true;
  }
  for (const r of rows.slice(start + 1)) {
    const type = r.payload?.type;
    if (['thread_rolled_back', 'rollback'].includes(type) || ['thread_rolled_back', 'rollback'].includes(r.type)) reject('rollback changes active history');
    if (r.type === 'compacted' || r.payload?.replacement_history != null) reject('unsupported compaction checkpoint');
    if (r.type === 'context_compacted' || type === 'context_compacted') {
      if (!checkpoint) pendingMarker = true;
      continue;
    }
    if (r.type === 'response_item' || (r.type === 'event_msg' && ['user_message', 'agent_message', 'task_started'].includes(type))) {
      if (pendingMarker) reject('context_compacted without replacement_history');
      checkpoint = false;
    }
    active.push(r);
  }
  if (pendingMarker) reject('context_compacted without replacement_history');
  return [...metadata, ...active];
}

// Match the two representations within each native turn, once per occurrence.
function codexEchoes(rows) {
  const echoes = new Set();
  let available = new Map(), events = [];
  function flush() {
    for (const [r, key] of events) if (available.get(key) > 0) {
      echoes.add(r);
      available.set(key, available.get(key) - 1);
    }
    events = [];
    available = new Map();
  }
  for (const r of rows) {
    const p = r.payload ?? {};
    if (r.type === 'turn_context' || (r.type === 'event_msg' && p.type === 'task_started')) flush();
    if (r.type === 'response_item' && p.type === 'message') {
      const value = typeof p.content === 'string' ? p.content : Array.isArray(p.content) ? p.content.map(b => b?.text ?? '').join('') : '';
      const key = JSON.stringify([p.role, value]);
      available.set(key, (available.get(key) ?? 0) + 1);
    } else if (r.type === 'event_msg' && ['agent_message', 'user_message'].includes(p.type)) {
      events.push([r, JSON.stringify([p.type === 'agent_message' ? 'assistant' : 'user', p.message])]);
    }
  }
  flush();
  return echoes;
}

// ACP replays saved messages and only the tool fields exposed by the agent.
function replayAgy(rows, id, emit, assistant, warn, note) {
  function content(block, role) {
    if (block?.type === 'text' && typeof block.text === 'string') return [text(block.text)];
    if (block?.type === 'image' && nonempty(block.data) && /^image\//.test(block.mimeType) && role !== 'assistant')
      return [{ type: 'image', data: block.data, mimeType: block.mimeType }];
    warn(`archived Antigravity content ${block?.type ?? '(missing type)'}`);
    return [];
  }
  let pending = [], kind;
  const flush = () => {
    if (kind === 'user') emit('user', pending);
    if (kind === 'assistant') assistant(pending);
    pending = [];
  };
  for (const row of rows) {
    if (row.type === 'agy_session') continue;
    if (row.method !== 'session/update' || row.params?.sessionId !== id)
      throw new Error('Antigravity replay contains an unexpected session or record');
    const u = row.params.update;
    switch (u?.sessionUpdate) {
      case 'user_message_chunk':
      case 'agent_message_chunk':
      case 'agent_thought_chunk': {
        const role = u.sessionUpdate === 'user_message_chunk' ? 'user' : 'assistant';
        if (role !== kind) { flush(); kind = role; }
        const parts = u.sessionUpdate === 'agent_thought_chunk' && typeof u.content?.text === 'string'
          ? [{ type: 'thinking', thinking: u.content.text }] : content(u.content, role);
        for (const part of parts) {
          const last = pending.at(-1);
          const field = part.type === 'text' ? 'text' : part.type === 'thinking' ? 'thinking' : null;
          if (field && last?.type === part.type) last[field] += part[field];
          else pending.push(part);
        }
        break;
      }
      case 'tool_call':
      case 'tool_call_update':
        flush(); kind = undefined;
        note('Antigravity tool calls and results retained in the replay archive');
        break;
      case 'available_commands_update': case 'session_info_update': case 'config_option_update':
      case 'current_mode_update': case 'usage_update': case 'plan':
        note(`archived Antigravity ${u.sessionUpdate}`);
        break;
      default: warn(`archived Antigravity update ${u?.sessionUpdate ?? '(missing type)'}`);
    }
  }
  flush();
}

function requireCanonical(path) {
  if (realpathSync(path) !== path) throw new Error(`Unexpected path or symbolic link: ${path}`);
}

export function validateMigrationPaths(source, sourceId, piRoot, archiveRoot) {
  const config = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
  const projects = join(resolve(config), 'projects');
  if (source !== resolve(source) || dirname(dirname(source)) !== projects || basename(source) !== `${sourceId}.jsonl`)
    throw new Error('Expected the configured Claude projects/<project>/<sourceId>.jsonl');
  requireCanonical(source);
  for (const root of [piRoot, archiveRoot].map(p => resolve(p))) {
    if (root === projects || root.startsWith(projects + sep)) throw new Error('Migration output must be outside Claude projects');
    let parent = root;
    while (!lstatSync(parent, { throwIfNoEntry: false })) parent = dirname(parent);
    requireCanonical(parent);
  }
}

function checkWriters(path) {
  const check = spawnSync('lsof', ['-nP', '-Ffa', '--', path], { encoding: 'utf8', timeout: 5000 });
  if (check.error || check.stderr || !(check.status === 0 || (check.status === 1 && !check.stdout)))
    throw new Error(`Cannot check for writers: ${check.error?.message ?? (check.stderr.trim() || `lsof exit ${check.status}`)}`);
  if (/^a[wu]/m.test(check.stdout)) throw new Error('Claude transcript is open for writing');
}

const sameInode = (a, b) => a.dev === b.dev && a.ino === b.ino;
const inspect = path => lstatSync(path, { bigint: true });

export function retireClaude(source, initial, raw, archive, file, targetMatches, notes) {
  function verify(path, staged = false) {
    for (const p of [path, archive, file]) requireCanonical(p);
    const current = inspect(path), saved = inspect(archive), published = inspect(file);
    if (!sameInode(current, initial) || current.size !== initial.size || current.mtimeNs !== initial.mtimeNs ||
        (!staged && current.ctimeNs !== initial.ctimeNs)) throw new Error('Claude transcript changed or was replaced');
    if (sameInode(current, saved) || sameInode(current, published) || sameInode(saved, published))
      throw new Error('Claude source, archive and Pi target must be distinct files');
    if (!regularFile(archive).equals(raw) || !regularFile(path).equals(raw)) throw new Error('Archive differs from the current Claude transcript');
    if (!targetMatches(regularFile(file))) throw new Error('Published import is incomplete or changed');
  }
  checkWriters(source);
  verify(source);
  // Claim the directory entry first. Never unlink the user-visible name after a path-based check.
  const stage = mkdtempSync(join(dirname(source), '.agent-dash-migration-'));
  const held = join(stage, basename(source));
  try {
    renameSync(source, held);
    try {
      checkWriters(held);
      verify(held, true);
      if (lstatSync(source, { throwIfNoEntry: false })) throw new Error('A new Claude transcript appeared during migration');
      unlinkSync(held);
    } catch (err) {
      // Restore without overwriting a concurrent replacement. Report the recovery copy if occupied.
      try { linkSync(held, source); unlinkSync(held); }
      catch (restore) { throw new Error(`${err.message}. Recover the retained transcript from ${held} (${restore.message})`); }
      throw err;
    }
  } finally {
    // Cleanup cannot change whether the native transcript moved or hide a recovery path.
    try { rmdirSync(stage); } catch (err) { notes.push(`Migration staging directory remains at ${stage} (${err.code})`); }
  }
}

function convert(backend, source, sourceId, cwd, piRoot, archiveRoot, pinnedFd) {
  if (!['claude', 'codex', 'agy'].includes(backend)) throw new Error('Expected claude, codex or agy');
  if (!/^[A-Za-z0-9][A-Za-z0-9_.-]{0,199}$/.test(sourceId)) throw new Error('Invalid source session ID');
  const zipped = backend === 'codex' && source.endsWith('.jsonl.zst');
  if (!zipped && !source.endsWith('.jsonl')) throw new Error('Expected a native JSONL transcript');
  const initial = pinnedFd === undefined ? null : fstatSync(pinnedFd, { bigint: true });
  const raw = regularFile(source, pinnedFd);
  const decoded = !zipped ? raw : typeof zlib.zstdDecompressSync === 'function' ? zlib.zstdDecompressSync(raw)
    : execFileSync('zstd', ['-dcq'], { input: raw, maxBuffer: 1024 * 1024 * 1024 });
  const warningCounts = new Map(), noteCounts = new Map();
  const count = (counts, msg) => counts.set(msg, (counts.get(msg) || 0) + 1);
  const warn = msg => count(warningCounts, msg), note = msg => count(noteCounts, msg);
  let identified = false;
  const rows = [];
  for (const line of new TextDecoder('utf-8', { fatal: true }).decode(decoded).split('\n')) {
    if (!line.trim()) continue;
    let r;
    try { r = JSON.parse(line); } catch { warn('archived malformed JSONL line'); continue; }
    if (!object(r)) { warn('archived invalid JSONL record'); continue; }
    const nativeId = backend === 'claude' || r.type === 'agy_session' ? r.sessionId : r.type === 'session_meta' ? r.payload?.id : undefined;
    if (nativeId !== undefined) {
      if (nativeId !== sourceId) throw new Error('Native source session ID mismatch');
      identified = true;
    }
    rows.push(r);
  }
  if (!identified) throw new Error('Missing native source session ID');
  const agyHeader = backend === 'agy' ? rows[0] : null;
  if (backend === 'agy' && (agyHeader?.type !== 'agy_session' || agyHeader.sessionId !== sourceId))
    throw new Error('Missing Antigravity replay header');
  const firstTime = rows.find(r => Number.isFinite(Date.parse(r.timestamp)))?.timestamp;
  let timestamp = firstTime ? Date.parse(firstTime) : 0;
  const start = new Date(timestamp).toISOString();
  let model = agyHeader?.model;
  let provider = { claude: 'anthropic', codex: 'openai', agy: 'google' }[backend];
  const api = { claude: 'anthropic-messages', codex: 'openai-responses', agy: 'google-generative-ai' }[backend];
  const messages = [], missingTime = new Map();
  let unstampedRecord;
  function emit(role, content, extra = {}) {
    if (!content.length && role !== 'toolResult') return;
    const message = { role, content, timestamp, ...extra };
    if (unstampedRecord) missingTime.set(message, unstampedRecord);
    messages.push(message);
  }
  function assistant(content, native = {}) {
    if (!content.length) return;
    if (!native.model && !model) warn('missing assistant model');
    if (!native.usage) warn('missing assistant token usage (zero placeholder)');
    emit('assistant', content, { api,
      provider, model: native.model || model || 'unknown', usage: usage(native.usage),
      stopReason: native.stop_reason === 'max_tokens' ? 'length' : 'stop' });
  }
  cwd = resolve(cwd);
  const sha256 = digest(raw);
  const key = digest(JSON.stringify([backend, sourceId, cwd, sha256, ...(backend === 'agy' ? [2] : [])]));
  const id = `${key.slice(0, 8)}-${key.slice(8, 12)}-8${key.slice(13, 16)}-a${key.slice(17, 20)}-${key.slice(20, 32)}`;
  const pi = directory(resolve(piRoot)), archives = directory(resolve(archiveRoot));
  if (initial && (pi !== resolve(piRoot) || archives !== resolve(archiveRoot))) throw new Error('Migration output directory was redirected');
  if (archives === pi || archives.startsWith(pi + sep)) throw new Error('Archive directory must be outside the Pi sessions directory');
  const archive = join(archives, `${backend}-${id}.jsonl${zipped ? '.zst' : ''}`);
  publish(archive, raw);
  let active = rows;
  if (backend === 'claude') {
    try { active = claudeBranch(rows, warn); }
    catch (error) { throw new Error(`${error.message}. Original archived at ${archive}`); }
  } else if (backend === 'codex') {
    active = codexBranch(rows, warn, archive);
  } else {
    active = [];
  }
  const echoes = backend === 'codex' ? codexEchoes(active) : new Set();
  if (backend === 'agy') {
    warn('Antigravity replay does not expose per-message timestamps or token usage');
    replayAgy(rows, sourceId, emit, assistant, warn, note);
  }
  for (const r of active) {
    const time = Date.parse(r.timestamp);
    unstampedRecord = Number.isFinite(time) ? undefined : r;
    if (!unstampedRecord) timestamp = time;
    if (backend === 'claude') {
      if (r.type === 'attachment') {
        const type = nonempty(r.attachment?.type) ? r.attachment.type : '(missing type)';
        const report = claudeContextAttachments.has(type) ? note : warn;
        report(`Claude attachment ${type} is available only in the original archive`);
        continue;
      }
      if (r.type === 'system') {
        const subtype = nonempty(r.subtype) ? r.subtype : '(missing subtype)';
        const hookFailure = subtype === 'stop_hook_summary' && (r.hookErrors?.length || r.preventedContinuation);
        const report = claudeSystemAdministration.has(subtype) && !hookFailure ? note : warn;
        report(`archived Claude system ${subtype} record`);
        continue;
      }
      if (claudeAdministration.has(r.type) || (r.type === 'user' && r.isMeta === true)) {
        note(`archived Claude ${r.type === 'user' ? 'metadata user' : r.type} record`);
        continue;
      }
      if (!['assistant', 'user'].includes(r.type) || r.isSidechain || r.isMeta) {
        warn(`archived Claude ${r.isSidechain ? 'sidechain' : r.type ?? '(missing type)'} record`);
        continue;
      }
      const m = r.message ?? {};
      if (m.role && m.role !== r.type) { warn('archived conflicting Claude message role'); continue; }
      if (r.type === 'assistant') {
        const content = Array.isArray(m.content) ? m.content.flatMap(b => b?.type === 'tool_use' ? toolCall(b.id, b.name, b.input, warn) : blocks([b], warn, 'assistant')) : blocks(m.content, warn, 'assistant');
        assistant(content, m);
      } else {
        const parts = Array.isArray(m.content) ? m.content : [text(m.content)];
        for (const b of parts) if (b?.type === 'tool_result') emit('toolResult', blocks(b.content, warn, 'toolResult'), { toolCallId: b.tool_use_id, isError: b.is_error === true });
        emit('user', blocks(parts.filter(b => b?.type !== 'tool_result'), warn, 'user'));
      }
      continue;
    }
    const p = r.payload ?? {};
    if (r.type === 'session_meta') { provider = p.model_provider || provider; continue; }
    if (r.type === 'turn_context') { model = p.model ?? model; continue; }
    if (r.type === 'event_msg' && ['user_message', 'agent_message'].includes(p.type)) {
      const role = p.type === 'user_message' ? 'user' : 'assistant';
      if (!echoes.has(r)) {
        const content = blocks(p.message, warn, role);
        if (role === 'user') emit(role, content); else assistant(content);
      }
      continue;
    }
    if (r.type !== 'response_item') { warn(`archived Codex ${r.type} record`); continue; }
    if (p.type === 'message' && ['user', 'assistant'].includes(p.role)) {
      const content = blocks(p.content, warn, p.role);
      if (p.role === 'user') emit('user', content); else assistant(content);
    } else if (p.type === 'function_call' || p.type === 'custom_tool_call') {
      assistant(toolCall(p.call_id, p.name, p.type === 'custom_tool_call' ? { input: p.input } : p.arguments, warn));
    } else if (p.type === 'function_call_output' || p.type === 'custom_tool_call_output') {
      emit('toolResult', blocks(p.output, warn, 'toolResult'), { toolCallId: p.call_id, isError: p.is_error === true });
    } else if (p.type === 'reasoning') {
      const summary = blocks(p.summary ?? [], warn, 'assistant').map(b => ({ type: 'thinking', thinking: b.text }));
      assistant(summary);
      if (p.encrypted_content) warn('archived encrypted reasoning');
    } else if (p.type === 'compaction' && p.encrypted_content) warn('archived opaque encrypted compaction content');
    else warn(`archived Codex ${p.type} ${p.role || 'item'}`);
  }
  const history = pairTools(messages, warn);
  if (backend === 'claude' && claudeCommandOnly(rows)) {
    const reason = 'Claude 源记录包含本地命令，未发现普通问答';
    if (!history.length) throw new Error(`${reason}。没有可导入的消息。原始记录已归档至 ${archive}`);
    note(reason);
  }
  if (!history.length) throw new Error(`No convertible conversation in native source. Original archived at ${archive}`);
  const targetPath = join(pi, `--${cwd.replace(/^[/\\]/, '').replace(/[/\\:]/g, '-')}--`);
  const target = directory(targetPath);
  if (initial && target !== targetPath) throw new Error('Pi session directory was redirected');
  const file = join(target, `${start.replace(/[:.]/g, '-')}_${id}.jsonl`);
  const fallbackRecords = new Set(history.map(message => missingTime.get(message)).filter(Boolean));
  if (fallbackRecords.size) warningCounts.set('missing timestamp (previous or first known time used, otherwise Unix epoch)', fallbackRecords.size);
  const format = counts => Array.from(counts, ([reason, count]) => `${reason} (${count})`);
  const warnings = format(warningCounts), notes = format(noteCounts);
  const entries = [{ type: 'session', version: 3, id, cwd, timestamp: start }];
  function append(type, data, time) {
    const index = entries.length;
    entries.push({ type, id: index.toString(16).padStart(8, '0'), parentId: index === 1 ? null : entries[index - 1].id,
      timestamp: time, ...data });
  }
  append('custom', { customType: 'agent-dash-import', data: { backend, sourceId, sha256, warnings } }, start);
  for (const message of history) append('message', { message }, new Date(message.timestamp).toISOString());
  publish(file, Buffer.from(entries.map(e => JSON.stringify(e)).join('\n') + '\n'), existing => matchesImport(existing, entries));
  const report = { file, id, warnings, notes, archive };
  if (initial) {
    try {
      retireClaude(source, initial, raw, archive, file, bytes => matchesImport(bytes, entries), notes);
      report.migration = 'moved';
    }
    catch (err) { report.migration = 'retained'; report.migrationError = err.message; }
  }
  return report;
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) try {
  const args = process.argv.slice(2);
  const migrate = args.length === 7 && args[6] === '--migrate-claude';
  if ((!migrate && args.length !== 6) || args.some(s => !s)) throw new Error('Usage: node agent-dash-convert.mjs BACKEND SOURCE_PATH SOURCE_ID PROJECT_ROOT PI_SESSIONS_DIR ARCHIVE_DIR [--migrate-claude]');
  if (migrate) {
    const [backend, source, sourceId, , piRoot, archiveRoot] = args;
    if (backend !== 'claude') throw new Error('--migrate-claude requires a native Claude transcript');
    validateMigrationPaths(source, sourceId, piRoot, archiveRoot);
    const fd = openRegular(source);
    try { console.log(JSON.stringify(convert(...args.slice(0, 6), fd))); } finally { closeSync(fd); }
  } else console.log(JSON.stringify(convert(...args)));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
