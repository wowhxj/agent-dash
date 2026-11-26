// Build one DeepSeek chat export v3 ZIP from an isolated Pi conversion.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, realpathSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const converter = fileURLToPath(new URL('./agent-dash-convert.mjs', import.meta.url));

// Atomically publish a deterministic ZIP beside the original (never overwrite a file).
const zip = `
import json, os, sys, tempfile, zipfile
root, name = sys.argv[1:]
fd, stage = tempfile.mkstemp(dir=root)
try:
    with os.fdopen(fd, 'w+b') as stream, zipfile.ZipFile(stream, 'w') as archive:
        for path, value in json.load(sys.stdin).items():
            data = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()
            if len(data) > 256 * 1024 * 1024:
                raise ValueError('conversation exceeds the DSH default 256 MiB entry limit')
            archive.writestr(zipfile.ZipInfo(path), data, compress_type=zipfile.ZIP_DEFLATED)
    target = os.path.join(root, name)
    try:
        os.link(stage, target)
    except FileExistsError:
        import filecmp, stat
        if not stat.S_ISREG(os.lstat(target).st_mode) or not filecmp.cmp(stage, target, shallow=False):
            raise ValueError('existing ZIP differs: ' + target)
finally:
    os.unlink(stage)
`;

function canonical(path) {
  path = resolve(path);
  if (existsSync(path)) return realpathSync(path);
  return join(canonical(dirname(path)), basename(path));
}

function exportHistory(backend, source, sourceId, project, pi, archives) {
  const archiveRoot = canonical(archives), piRoot = canonical(pi);
  if (archiveRoot === piRoot || archiveRoot.startsWith(piRoot + sep)) throw new Error('Archive directory must be outside Pi sessions');
  const temp = mkdtempSync(join(tmpdir(), 'agent-dash-dsh-'));
  try {
    const { id, file: snapshot, archive, warnings, notes: archiveNotes = [] } = JSON.parse(execFileSync(process.execPath,
      [converter, backend, source, sourceId, project, join(temp, 'pi'), archiveRoot], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
    const entries = readFileSync(snapshot, 'utf8').trimEnd().split('\n').map(line => JSON.parse(line));
    const origin = entries.find(e => e.customType === 'agent-dash-import').data;
    const title = `${{ claude: 'Claude Code', codex: 'Codex', agy: 'Antigravity' }[backend]} · ${sourceId}`;
    const provenance = `[Source history: ${title}${backend === 'agy' ? ' (dialogue v2)' : ''}; SHA-256 ${origin.sha256}]`;
    const messages = [];
    const notes = new Set();
    function append(role, time) {
      const id = messages.length + 1;
      messages.push({ id, parent_id: id === 1 ? null : id - 1, role, status: 'FINISHED', inserted_at: time, fragments: [] });
      return messages.at(-1);
    }
    for (const { message: m, timestamp } of entries.filter(e => e.type === 'message')) {
      if (Date.parse(timestamp) < 0) throw new Error(`DSH requires a timestamp on or after the Unix epoch. Original archived at ${archive}`);
      if (backend === 'agy') {
        const dialogue = m.content.filter(block => block.type === 'text').map(block => block.text);
        for (const block of m.content) if (block.type !== 'text')
          notes.add(`Antigravity ${block.type} retained in the replay archive`);
        if (!dialogue.length) continue;
        const role = m.role === 'user' ? 'USER' : 'ASSISTANT';
        if (role === 'ASSISTANT' && !messages.length) append('USER', timestamp);
        let current = messages.at(-1);
        if (role === 'USER' || current.role !== role) current = append(role, timestamp);
        current.fragments.push({ type: role === 'USER' ? 'REQUEST' : 'RESPONSE',
          content: (current.fragments.length ? '\n\n' : '') + dialogue.join('\n') });
        continue;
      }
      let current = messages.at(-1);
      if (m.role === 'user') current = append('USER', timestamp);
      else {
        if (!current) {
          append('USER', timestamp);
          notes.add('Initial source assistant history uses a provenance-only user header');
        }
        if (messages.at(-1).role !== 'ASSISTANT') current = append('ASSISTANT', timestamp);
        else notes.add('Consecutive assistant/tool entries grouped into one DSH reply, with source boundaries');
      }
      const lines = [];
      if (m.role === 'assistant') {
        lines.push(`[Source assistant: ${m.provider}/${m.model}; ${timestamp}]`);
        notes.add('DSH attributes imported replies to deepseek-chat-export; original provider/model are recorded as text. Original API, token usage, costs and stop reason are not native DSH fields');
        if (m.stopReason === 'length') lines.push('[Source reply ended at the output token limit]');
      }
      if (m.role === 'toolResult') {
        lines.push(`[Source tool result: ${m.toolName}; id=${m.toolCallId}; error=${m.isError === true}]`);
        notes.add('Source tool calls and results rendered as historical text');
      }
      for (const block of m.content) {
        if (block.type === 'text') lines.push(block.text);
        else if (block.type === 'toolCall') {
          lines.push(`[Source tool call: ${block.name}; id=${block.id}]\n${JSON.stringify(block.arguments)}`);
          notes.add('Source tool calls and results rendered as historical text');
        } else if (block.type === 'thinking') {
          lines.push(`[Source reasoning]\n${block.thinking}`);
          notes.add('Source reasoning rendered as historical text');
        } else {
          lines.push(`[Source ${block.type} retained in original archive]`);
          notes.add(`Source ${block.type} stored only in original archive`);
        }
      }
      const type = current.role === 'USER' ? 'REQUEST' : 'RESPONSE';
      current.fragments.push({ type, content: (current.fragments.length ? '\n\n' : '') + lines.join('\n') });
    }
    if (!messages.length) throw new Error(`No DSH-compatible dialogue; source archived at ${archive}`);
    messages[0].fragments.unshift({ type: 'REQUEST', content: provenance });
    if (messages.some((m, i) => m.role === 'USER' && messages[i + 1]?.role !== 'ASSISTANT'))
      notes.add('Source user turn without a reply imports with DSH no-reply status');
    const inserted_at = messages[0].inserted_at;
    const index = { id, inserted_at, updated_at: messages.at(-1).inserted_at };
    const payload = { 'manifest.json': { export_format_version: 3 }, 'chat_session_index.json': [index],
      [`chat_sessions/${id}.json`]: { id, title, inserted_at, current_message_id: messages.at(-1).id, messages } };
    const name = `${backend}-${id}-dsh.zip`;
    execFileSync('python3', ['-c', zip, archiveRoot, name], { input: JSON.stringify(payload), stdio: ['pipe', 'ignore', 'pipe'] });
    return { file: join(archiveRoot, name), id, archive, warnings: [...warnings, ...notes], notes: archiveNotes };
  } finally { rmSync(temp, { recursive: true, force: true }); }
}

try {
  const args = process.argv.slice(2);
  if (args.length !== 6 || args.some(s => !s)) throw new Error('Usage: node agent-dash-dsh-export.mjs BACKEND SOURCE SOURCE_ID PROJECT_ROOT PI_DIR ARCHIVE_DIR');
  console.log(JSON.stringify(exportHistory(...args)));
} catch (error) {
  console.error(error.stderr?.toString().trim() || error.message);
  process.exitCode = 1;
}
