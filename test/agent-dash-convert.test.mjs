import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile, spawnSync } from 'node:child_process';
import { promisify } from 'node:util';
import { appendFileSync, closeSync, copyFileSync, existsSync, linkSync, mkdirSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, statSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as zlib from 'node:zlib';

const cli = fileURLToPath(new URL('../agent-dash-convert.mjs', import.meta.url));
const stamp = '2026-01-02T03:04:05.123Z';
const sourceId = 'source-123';
const txt = value => ({ type: 'text', text: value });
const claude = (role, content) => ({ type: role, timestamp: stamp, sessionId: sourceId, message: { role, content } });
const meta = { type: 'session_meta', timestamp: stamp, payload: { id: sourceId } };
const item = payload => ({ type: 'response_item', timestamp: stamp, payload });
const call = n => item({ type: 'function_call', call_id: n, name: `tool_${n}`, arguments: '{"n":1}' });
const result = n => item({ type: 'function_call_output', call_id: n, output: `done ${n}` });
const entries = file => readFileSync(file, 'utf8').trimEnd().split('\n').map(line => JSON.parse(line));
function fixture(t, backend, rows, zip = false) {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'agent-dash-import-')));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const source = join(dir, `source.jsonl${zip ? '.zst' : ''}`), cwd = join(dir, 'project with spaces');
  mkdirSync(cwd);
  const pi = join(dir, 'pi'), archive = join(dir, 'archives');
  const bytes = Buffer.from(rows.map(r => typeof r === 'string' ? r : JSON.stringify(r)).join('\r\n') + '\r\n');
  writeFileSync(source, zip ? zlib.zstdCompressSync(bytes) : bytes);
  const args = [cli, backend, source, sourceId, cwd, pi, archive];
  const run = (argv = args) => spawnSync(process.execPath, argv, { encoding: 'utf8' });
  const ok = () => { const r = run(); assert.equal(r.status, 0, r.stderr); assert.equal(r.stderr, ''); return JSON.parse(r.stdout); };
  return { dir, cwd, source, pi, args, run, ok };
}

const hasLsof = !spawnSync('lsof', ['-v']).error;
function migrationFixture(t) {
  const f = fixture(t, 'claude', [claude('user', 'synthetic migration')]);
  const home = join(f.dir, 'home'), config = join(home, '.claude');
  const project = join(config, 'projects', '-synthetic');
  mkdirSync(project, { recursive: true });
  const source = join(project, `${sourceId}.jsonl`);
  copyFileSync(f.source, source);
  const args = [...f.args]; args[2] = source;
  const env = { ...process.env, HOME: home, CLAUDE_CONFIG_DIR: config };
  if (!hasLsof) {
    // Exercise publication/rollback on minimal CI images using a synthetic no-writers result.
    const bin = join(f.dir, 'bin'); mkdirSync(bin);
    writeFileSync(join(bin, 'lsof'), '#!/bin/sh\nexit 1\n', { mode: 0o700 });
    env.PATH = bin;
  }
  const migrate = (argv = args, extra = {}) => spawnSync(process.execPath, [...argv, '--migrate-claude'], {
    encoding: 'utf8', env: { ...env, ...extra }
  });
  return { ...f, source, config, args, migrate };
}

const report = r => { assert.equal(r.status, 0, r.stderr); return JSON.parse(r.stdout); };

test('explicit migration reuses a completed Pi import including its continuation and preserves restore bytes', t => {
  const f = migrationFixture(t), raw = readFileSync(f.source);
  const first = report(f.run(f.args));
  assert.equal(first.migration, undefined);
  appendFileSync(first.file, '{"type":"session_info","name":"continued"}\n');
  const continued = readFileSync(first.file);
  const migrated = report(f.migrate(f.args, { CLAUDE_CONFIG_DIR: '' }));
  assert.equal(migrated.migration, 'moved', migrated.migrationError);
  assert.equal(migrated.id, first.id);
  assert.equal(existsSync(f.source), false);
  assert.deepEqual(readFileSync(first.archive), raw);
  assert.deepEqual(readFileSync(first.file), continued);
  copyFileSync(first.archive, f.source);
  assert.deepEqual(readFileSync(f.source), raw);
});

test('migration rejects alternate paths, links, unrelated backends and incomplete publication', t => {
  const f = migrationFixture(t), raw = readFileSync(f.source);
  for (const path of [join(f.dir, 'source.jsonl'), join(f.config, 'projects', `${sourceId}.jsonl`),
    `${dirname(f.source)}/../-synthetic/${sourceId}.jsonl`]) {
    const args = [...f.args]; args[2] = path;
    assert.match(f.migrate(args).stderr, /Expected the configured Claude/);
  }
  const alias = join(f.config, 'projects', 'alias'); symlinkSync(dirname(f.source), alias);
  const args = [...f.args]; args[2] = join(alias, basename(f.source));
  assert.match(f.migrate(args).stderr, /symbolic link/);
  args[1] = 'codex'; assert.match(f.migrate(args).stderr, /native Claude/);
  const legacy = report(f.run(f.args));
  writeFileSync(legacy.file, readFileSync(legacy.file).subarray(0, 50));
  assert.match(f.migrate().stderr, /differs/);
  assert.deepEqual(readFileSync(f.source), raw);
});

test('migration retains a transcript with an open writer', { skip: !hasLsof }, t => {
  const f = migrationFixture(t), fd = openSync(f.source, 'a');
  let active;
  try { active = report(f.migrate()); } finally { closeSync(fd); }
  assert.equal(active.migration, 'retained');
  assert.match(active.migrationError, /open for writing/);
  assert.deepEqual(readFileSync(active.archive), readFileSync(f.source));
  assert.equal(report(f.migrate()).migration, 'moved');
});

test('migration rejects a hard-linked archive', t => {
  const f = migrationFixture(t), legacy = report(f.run(f.args));
  unlinkSync(legacy.archive); linkSync(f.source, legacy.archive);
  const alias = report(f.migrate());
  assert.equal(alias.migration, 'retained'); assert.match(alias.migrationError, /distinct/);
  assert.equal(existsSync(f.source), true);
});

test('unavailable writer detection keeps the converted original available for a later retry', t => {
  const f = migrationFixture(t);
  const result = report(f.migrate(f.args, { PATH: f.dir }));
  assert.equal(result.migration, 'retained'); assert.match(result.migrationError, /Cannot check for writers/);
  assert.deepEqual(readFileSync(result.archive), readFileSync(f.source));
});

test('a concurrent recreation keeps both the replacement and the named recovery copy', t => {
  const f = migrationFixture(t), preload = join(f.dir, 'recreate.cjs');
  writeFileSync(preload, `const fs = require('node:fs');
const rename = fs.renameSync;
fs.renameSync = (src, dst) => {
  rename(src, dst);
  fs.writeFileSync(src, 'new Claude transcript', { flag: 'wx' });
};
require('node:module').syncBuiltinESMExports();`);
  const result = report(f.migrate(['--require', preload, ...f.args]));
  assert.equal(result.migration, 'retained');
  const recovery = /Recover the retained transcript from (.+?) \(/.exec(result.migrationError);
  assert.ok(recovery, result.migrationError);
  assert.deepEqual(readFileSync(recovery[1]), readFileSync(result.archive));
  assert.equal(readFileSync(f.source, 'utf8'), 'new Claude transcript');
});

test('a replacement at the instant of migration is restored without deleting its bytes', t => {
  const f = migrationFixture(t), preload = join(f.dir, 'replace.cjs');
  writeFileSync(preload, `const fs = require('node:fs');
const rename = fs.renameSync;
fs.renameSync = (src, dst) => {
  fs.writeFileSync(src + '.new', 'replacement');
  rename(src + '.new', src);
  rename(src, dst);
};
require('node:module').syncBuiltinESMExports();`);
  const result = report(f.migrate(['--require', preload, ...f.args]));
  assert.equal(result.migration, 'retained'); assert.match(result.migrationError, /changed or was replaced/);
  assert.equal(readFileSync(f.source, 'utf8'), 'replacement');
  assert.match(readFileSync(result.archive, 'utf8'), /synthetic migration/);
});

const picture = { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'AQID' } };
test('Claude keeps mixed content, source identity and matching tool results in a valid Pi v3 chain', t => {
  const f = fixture(t, 'claude', [claude('user', [txt('prompt'), picture]),
    claude('assistant', [{ type: 'thinking', thinking: 'visible reasoning' }, txt('calling'), { type: 'tool_use', id: 'x', name: 'Read', input: { path: 'a' } }]),
    claude('user', [{ type: 'tool_result', tool_use_id: 'x', is_error: true, content: [txt('error'), picture] }, txt('followup')]),
    claude('assistant', [txt('final'), { type: 'unmapped' }]), '{truncated']);
  const { file, id, warnings, archive } = f.ok(), [header, origin, ...chain] = entries(file);
  assert.deepEqual(readFileSync(archive), readFileSync(f.source));
  assert.equal(statSync(archive).mode & 0o777, 0o600);
  assert.equal(statSync(file).mode & 0o777, 0o600);
  assert.ok(file.endsWith(`_${id}.jsonl`));
  assert.equal(dirname(file), join(f.pi, `--${f.cwd.slice(1).replaceAll('/', '-')}--`));
  assert.deepEqual(header, { type: 'session', version: 3, id, timestamp: stamp, cwd: f.cwd });
  assert.equal(origin.parentId, null);
  assert.equal(origin.data.sourceId, sourceId);
  assert.equal(origin.data.backend, 'claude');
  assert.match(origin.data.sha256, /^[0-9a-f]{64}$/);
  assert.deepEqual(origin.data.warnings, warnings);
  for (let i = 0; i < chain.length; i++) assert.equal(chain[i].parentId, (chain[i - 1] ?? origin).id);
  const messages = chain.map(e => e.message);
  assert.deepEqual(messages.map(m => m.role), ['user', 'assistant', 'toolResult', 'user', 'assistant']);
  assert.deepEqual(messages[0].content[1], { type: 'image', data: 'AQID', mimeType: 'image/png' });
  assert.equal(messages[1].content[0].thinking, 'visible reasoning');
  assert.equal(messages[1].stopReason, 'toolUse');
  assert.equal(messages[1].content[2].id, messages[2].toolCallId);
  assert.equal(messages[2].toolName, 'Read');
  assert.equal(messages[2].isError, true);
  assert.deepEqual(messages[2].content[1], messages[0].content[1]);
  assert.ok(warnings.some(w => w.includes('unmapped')));
  assert.ok(warnings.some(w => w.includes('malformed JSONL')));
});

test('Claude separates archived administration from attachments and unknown records', t => {
  const attachment = type => ({ type: 'attachment', attachment: { type, content: 'private example' } });
  const admin = ['file-history-snapshot', 'last-prompt', 'session-owner', 'ai-title', 'tools-used', 'file-history-delta', 'worktree-state', 'relocated'];
  const context = ['auto_mode', 'silent_turn_reminder', 'deferred_tools_record', 'command_permissions'];
  const archived = ['file', 'directory', 'nested_memory', 'edited_text_file', 'diagnostics', 'queued_command',
    'compact_file_reference', 'invoked_skills', 'hook_system_message', 'at_mention_reference', 'future_attachment'];
  const system = subtype => ({ type: 'system', subtype });
  const f = fixture(t, 'claude', [claude('user', 'hello'), ...admin.map(type => ({ type })), ...context.map(attachment),
    attachment('hook_success'), attachment('hook_success'), { ...claude('user', 'private example'), isMeta: true },
    ...archived.map(attachment), attachment('file'), attachment(), { type: 'future_record', isMeta: true }, { type: 'queue-operation' },
    { ...system('stop_hook_summary'), hookErrors: ['private example'] },
    ...['turn_duration', 'compact_boundary', 'stop_hook_summary', 'local_command', 'future_system', undefined].map(system)]);
  const { warnings, notes } = f.ok();
  for (const label of admin) assert.ok(notes.includes(`archived Claude ${label} record (1)`));
  for (const label of context) assert.ok(notes.includes(`Claude attachment ${label} is available only in the original archive (1)`));
  for (const subtype of ['turn_duration', 'compact_boundary', 'stop_hook_summary'])
    assert.ok(notes.includes(`archived Claude system ${subtype} record (1)`));
  for (const subtype of ['stop_hook_summary', 'local_command', 'future_system', '(missing subtype)'])
    assert.ok(warnings.includes(`archived Claude system ${subtype} record (1)`));
  assert.ok(warnings.includes('archived Claude queue-operation record (1)'));
  assert.match(notes.find(n => n.includes('attachment hook_success')), /original.*\(2\)$/);
  assert.ok(notes.some(n => n.includes('metadata user')));
  assert.doesNotMatch(JSON.stringify(warnings), /hook_success|metadata user/);
  for (const label of [...archived, '(missing type)']) {
    const warning = warnings.find(w => w.includes(`attachment ${label}`));
    assert.match(warning, /original/i);
    assert.ok(warning.endsWith(label === 'file' ? '(2)' : '(1)'));
  }
  assert.ok(warnings.some(w => w.includes('future_record')));
  assert.doesNotMatch(JSON.stringify(warnings), /timestamp|file-history-snapshot|last-prompt/);
  assert.doesNotMatch(JSON.stringify([warnings, notes]), /private example/);
});

test('missing time is reported once per source record that supplies a final Pi message timestamp', t => {
  const unstamped = record => ({ ...record, timestamp: undefined });
  const f = fixture(t, 'claude', [claude('user', 'first'), unstamped(claude('user', [{ type: 'unmapped' }])),
    unstamped(claude('user', [{ type: 'tool_result', tool_use_id: 'orphan', content: 'lost' }])),
    claude('assistant', [{ type: 'tool_use', id: 'call', input: {}, name: 'tool' }]),
    unstamped(claude('user', [{ type: 'tool_result', tool_use_id: 'call', content: 'done' }, txt('another')])),
    unstamped(claude('user', 'last'))]);
  assert.match(f.ok().warnings.find(w => w.includes('missing timestamp')), /\(2\)$/);
});

test('legacy diagnostic differences allow reuse only with matching imported history and archive', t => {
  const f = fixture(t, 'claude', [claude('user', 'first'), { type: 'last-prompt' }]);
  const initial = f.ok(), records = entries(initial.file);
  records[1].data.warnings = ['archived Claude last-prompt record (1)'];
  records.push({ type: 'session_info', name: 'continued' });
  const contents = () => records.map(JSON.stringify).join('\n') + '\n';
  writeFileSync(initial.file, contents());
  assert.deepEqual(f.ok(), initial);
  assert.equal(readFileSync(initial.file, 'utf8'), contents());
  writeFileSync(initial.archive, 'damaged');
  assert.match(f.run().stderr, /differs/);
  writeFileSync(initial.archive, readFileSync(f.source));
  const sha256 = records[1].data.sha256;
  records[1].data.sha256 = 'foreign';
  writeFileSync(initial.file, contents());
  assert.match(f.run().stderr, /differs/);
  records[1].data.sha256 = sha256;
  records[2].message.content[0].text = 'edited';
  writeFileSync(initial.file, contents());
  assert.match(f.run().stderr, /differs/);
  assert.equal(readFileSync(initial.file, 'utf8'), contents());
});

test('Codex parallel calls form one group; mismatches, duplicates and missing calls are reported', t => {
  const f = fixture(t, 'codex', [meta, { type: 'turn_context', payload: { model: 'model-id' } },
    { type: 'event_msg', payload: { type: 'user_message', message: 'question' } },
    item({ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'question' }] }),
    call('a'), call('b'), call('missing-result'), result('b'), result('missing-call'), result('a'), result('a'),
    item({ type: 'custom_tool_call', call_id: 'custom', name: 'apply', input: 'original' }),
    item({ type: 'custom_tool_call_output', call_id: 'custom', output: [{ type: 'output_text', text: 'applied' }] }),
    item({ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'answer' }] })]);
  const { file, warnings } = f.ok();
  const messages = entries(file).filter(e => e.type === 'message').map(e => e.message);
  assert.deepEqual(messages.map(m => m.role), ['user', 'assistant', 'toolResult', 'toolResult', 'assistant', 'toolResult', 'assistant']);
  assert.deepEqual(messages[1].content.map(b => b.id), ['a', 'b']);
  assert.deepEqual(messages.slice(2, 4).map(r => [r.toolName, r.content[0].text]), [['tool_b', 'done b'], ['tool_a', 'done a']]);
  assert.deepEqual(messages[4].content[0].arguments, { input: 'original' });
  assert.equal(messages.at(-1).model, 'model-id');
  assert.ok(warnings.some(w => w.includes('orphan')));
  assert.ok(warnings.some(w => w.includes('unpaired')));
});

test('parallel imports reuse one file, preserve continuation, fork on source changes and reject conflicting contents', async t => {
  const f = fixture(t, 'claude', [claude('user', 'first')]);
  const responses = await Promise.all([1, 2, 3, 4].map(() => promisify(execFile)(process.execPath, f.args)));
  const initial = JSON.parse(responses[0].stdout);
  for (const r of responses) assert.deepEqual(JSON.parse(r.stdout), initial);
  appendFileSync(initial.file, '{"type":"session_info","name":"continued"}\n');
  const continued = readFileSync(initial.file);
  assert.deepEqual(f.ok(), initial);
  assert.deepEqual(readFileSync(initial.file), continued);
  appendFileSync(f.source, JSON.stringify(claude('user', 'later')) + '\n');
  const next = f.ok();
  assert.notEqual(next.id, initial.id);
  assert.notEqual(next.archive, initial.archive);
  assert.deepEqual(readFileSync(initial.file), continued);
  writeFileSync(next.file, 'foreign data');
  const fail = f.run();
  assert.notEqual(fail.status, 0);
  assert.equal(fail.stdout, '');
  assert.match(fail.stderr, /differs/);
  assert.equal(readFileSync(next.file, 'utf8'), 'foreign data');
});

test('CLI rejects wrong or missing native identity, traversal, symlinks and empty histories', t => {
  const f = fixture(t, 'codex', [meta, item({ type: 'message', role: 'user', content: 'hello' })]);
  const failure = (argv, error) => { const r = f.run(argv); assert.notEqual(r.status, 0); assert.equal(r.stdout, ''); assert.match(r.stderr, error); };
  for (const [id, error] of [['different', /mismatch/], ['../escape', /Invalid source/]]) {
    const args = [...f.args]; args[3] = id; failure(args, error);
  }
  const args = [...f.args]; args[2] = join(f.dir, 'symlink.jsonl'); symlinkSync(f.source, args[2]); failure(args, /ELOOP|symbolic/i);
  mkdirSync(f.pi);
  const parent = join(f.pi, `--${f.cwd.slice(1).replaceAll('/', '-')}--`);
  symlinkSync(f.cwd, parent); failure(f.args, /directory/);
  writeFileSync(f.source, JSON.stringify(item({ type: 'message', role: 'user', content: 'hello' })));
  failure(f.args, /Missing native source/);
  writeFileSync(f.source, JSON.stringify(meta)); failure(f.args, /No convertible/);
  failure([cli], /Usage/);
});

test('Claude imports only ancestors of the last conversational leaf', t => {
  const turn = (id, parent, prompt) => ({ ...claude('user', prompt), uuid: id, parentUuid: parent });
  const f = fixture(t, 'claude', [turn('a', null, 'first'), turn('b', 'a', 'abandoned'), turn('c', 'a', 'active')]);
  const { file, warnings } = f.ok();
  assert.deepEqual(entries(file).slice(2).map(e => e.message.content[0].text), ['first', 'active']);
  assert.ok(warnings.includes('archived Claude message outside the final parentUuid chain (1)'));
  appendFileSync(f.source, JSON.stringify(turn('d', 'missing', 'broken')));
  const failure = f.run();
  assert.notEqual(failure.status, 0);
  assert.match(failure.stderr, /Missing Claude branch parent.*archived/);
});

test('Claude counts off-chain records at a compaction boundary without changing Pi history', t => {
  const old = Array.from({ length: 1079 }, (_, i) => ({ ...claude('user', 'earlier'), uuid: `old-${i}`,
    parentUuid: i ? `old-${i - 1}` : null }));
  const f = fixture(t, 'claude', [...old, { type: 'system', subtype: 'compact_boundary', uuid: 'boundary', parentUuid: null },
    { ...claude('user', '<command-name>/clear</command-name>'), uuid: 'new', parentUuid: 'boundary' }]);
  const { file, archive, warnings, notes } = f.ok();
  assert.deepEqual(warnings, ['archived Claude message outside the final parentUuid chain (source contains compact_boundary) (1079)']);
  assert.deepEqual(notes, ['archived Claude system compact_boundary record (1)']);
  assert.deepEqual(entries(file).slice(2).map(e => e.message.content), [[txt('<command-name>/clear</command-name>')]]);
  assert.deepEqual(readFileSync(archive), readFileSync(f.source));
});

test('Claude explains command-only sources while retaining command messages and ordinary prompts', t => {
  const command = claude('user', '<command-name>/x</command-name>\n<command-args></command-args>');
  const stdout = claude('user', [txt('<local-command-stdout>synthetic</local-command-stdout>')]);
  const note = 'Claude 源记录包含本地命令，未发现普通问答 (1)';
  const imported = fixture(t, 'claude', [command, stdout]).ok();
  assert.ok(imported.notes.includes(note));
  assert.deepEqual(entries(imported.file).slice(2).map(e => e.message.content), [[txt(command.message.content)], stdout.message.content]);
  const mixed = fixture(t, 'claude', [command, claude('user', [txt('这是普通提问'), ...stdout.message.content])]).ok();
  assert.ok(!mixed.notes.includes(note));
  const empty = fixture(t, 'claude', [{ ...command, isMeta: true }, { type: 'system', subtype: 'local_command' }]);
  const fail = empty.run();
  assert.notEqual(fail.status, 0);
  const error = /包含本地命令，未发现普通问答。没有可导入的消息。原始记录已归档至 (.+)/.exec(fail.stderr);
  assert.ok(error, fail.stderr);
  assert.deepEqual(readFileSync(error[1]), readFileSync(empty.source));
});

test('Codex echo suppression preserves event-only turns and repeated prompts', t => {
  const event = message => ({ type: 'event_msg', payload: { type: 'user_message', message } });
  const start = { type: 'event_msg', payload: { type: 'task_started' } };
  const f = fixture(t, 'codex', [meta, start, event('same'), item({ type: 'message', role: 'user', content: 'same' }), start, event('same'), event('event only')]);
  assert.deepEqual(entries(f.ok().file).slice(2).map(e => e.message.content[0].text), ['same', 'same', 'event only']);
});

test('Codex restores the latest replacement_history and retains subsequent events', t => {
  const msg = value => ({ type: 'message', role: 'user', content: [txt(value)] });
  const compact = history => ({ type: 'compacted', timestamp: stamp, payload: { replacement_history: history } });
  const marker = { type: 'event_msg', payload: { type: 'context_compacted' } };
  const f = fixture(t, 'codex', [meta, item(msg('archived')), compact([msg('obsolete')]), marker,
    { type: 'event_msg', payload: { type: 'thread_rolled_back' } }, marker,
    compact([msg('restored'), { type: 'compaction', encrypted_content: 'opaque' }]), marker, item(msg('after'))]);
  const { file, warnings, archive } = f.ok();
  assert.deepEqual(entries(file).slice(2).map(e => e.message.content[0].text), ['restored', 'after']);
  assert.deepEqual(readFileSync(archive), readFileSync(f.source));
  assert.ok(warnings.some(w => w.includes('encrypted compaction')));
  assert.ok(warnings.some(w => w.includes('replacement_history')));
});

test('Codex rollbacks after a checkpoint decline replay and preserve the source', t => {
  const f = fixture(t, 'codex', [meta, { type: 'compacted', payload: { replacement_history: [] } },
    item({ type: 'message', role: 'user', content: 'removed' }), { type: 'event_msg', payload: { type: 'thread_rolled_back', num_turns: 1 } }]);
  const fail = f.run();
  assert.notEqual(fail.status, 0);
  assert.equal(fail.stdout, '');
  const match = /rollback changes active history\. Original archived at (.+)/.exec(fail.stderr);
  assert.ok(match, fail.stderr);
  assert.deepEqual(readFileSync(match[1]), readFileSync(f.source));
});

test('Codex compactions without a usable checkpoint decline ambiguous replay', t => {
  for (const change of [{ type: 'event_msg', payload: { type: 'context_compacted' } }, { type: 'compacted', payload: { replacement_history: [null] } }]) {
    const f = fixture(t, 'codex', [meta, item({ type: 'message', role: 'user', content: 'removed' }), change]);
    const fail = f.run();
    assert.notEqual(fail.status, 0);
    assert.equal(fail.stdout, '');
    const match = /Original archived at (.+)/.exec(fail.stderr);
    assert.ok(match, fail.stderr);
    assert.deepEqual(readFileSync(match[1]), readFileSync(f.source));
  }
});

test('Codex zstd archives retain their original compressed bytes', { skip: !zlib.zstdCompressSync }, t => {
  const f = fixture(t, 'codex', [meta, { type: 'event_msg', payload: { type: 'user_message', message: 'old format' } }], true);
  const { archive, file } = f.ok();
  assert.ok(basename(archive).endsWith('.jsonl.zst'));
  assert.deepEqual(readFileSync(archive), readFileSync(f.source));
  assert.deepEqual(entries(file).at(-1).message.content, [txt('old format')]);
});
