// Opt in with AGENT_DASH_TEST_PI=/absolute/path/to/pi. No upstream accounts.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, mkdir, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import test from 'node:test';

const run = promisify(execFile);
const converter = fileURLToPath(new URL('../agent-dash-convert.mjs', import.meta.url));
const cli = process.env.AGENT_DASH_TEST_PI;

for (const backend of ['claude', 'codex']) {
  test(`installed Pi resumes a converted ${backend} conversation twice`, { skip: !cli }, t => resume(t, backend));
}

async function resume(t, backend) {
  const home = await realpath(await mkdtemp(join(tmpdir(), 'agent-dash-pi-resume-')));
  t.after(() => rm(home, { recursive: true, force: true }));
  const agent = join(home, 'agent');
  await mkdir(agent);
  const requests = [];
  const server = createServer(async (req, res) => {
    let body = '';
    for await (const chunk of req) body += chunk;
    requests.push(JSON.parse(body));
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const reply = { id: 'fixture', object: 'chat.completion.chunk', model: 'fixture', choices: [] };
    for (const choice of [
      { index: 0, delta: { role: 'assistant', content: `Local reply ${requests.length}` }, finish_reason: null },
      { index: 0, delta: {}, finish_reason: 'stop' },
    ]) res.write(`data: ${JSON.stringify({ ...reply, choices: [choice] })}\n\n`);
    res.end('data: [DONE]\n\n');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  const provider = { baseUrl: `http://127.0.0.1:${server.address().port}/v1`, apiKey: 'fixture',
    api: 'openai-completions', models: [{ id: 'fixture' }] };
  await writeFile(join(agent, 'models.json'), JSON.stringify({ providers: { localtest: provider } }));
  const sourceId = 'bb21b884-cfab-43f8-bfb8-d0de43cb23cd';
  const claudeConfig = join(home, '.claude');
  const projectStore = join(claudeConfig, 'projects', 'fixture');
  if (backend === 'claude') await mkdir(projectStore, { recursive: true });
  const source = join(backend === 'claude' ? projectStore : home, `${sourceId}.jsonl`);
  let parentUuid = null;
  const turns = [
    ['user', 'Inspect the test output'],
    ['assistant', [{ type: 'tool_use', id: 'run01', name: 'Bash', input: { command: 'test -f example' } }]],
    ['user', [{ type: 'tool_result', tool_use_id: 'run01', content: 'fixture exit status 1', is_error: true }]],
    ['assistant', 'The file was absent.'],
  ];
  const lines = turns.map(([role, content], index) => {
    const uuid = `line-${index}`;
    const record = { type: role, uuid, parentUuid, sessionId: sourceId, cwd: home,
      timestamp: `2026-01-01T00:00:0${index}.000Z`, message: { role, content } };
    parentUuid = uuid;
    return JSON.stringify(record);
  });
  if (backend === 'codex') {
    const payloads = [
      { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'Inspect the test output' }] },
      { type: 'function_call', call_id: 'run01', name: 'exec_command', arguments: '{"cmd":"test -f example"}' },
      { type: 'function_call_output', call_id: 'run01', output: 'fixture exit status 1' },
      { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'The file was absent.' }] },
    ];
    const timestamp = '2026-01-01T00:00:00.000Z';
    const records = [{ type: 'session_meta', timestamp, payload: { id: sourceId, cwd: home, timestamp } },
      ...payloads.map(payload => ({ type: 'response_item', timestamp, payload }))];
    await writeFile(source, records.map(record => JSON.stringify(record)).join('\n') + '\n');
  } else {
    await writeFile(source, lines.join('\n') + '\n');
  }
  const args = [converter, backend, source, sourceId, home, join(agent, 'sessions'), join(home, 'archive')];
  const { stdout } = await run(process.execPath, args);
  const { file, id } = JSON.parse(stdout);
  const env = { PATH: process.env.PATH, HOME: home, PI_CODING_AGENT_DIR: agent,
    PI_OFFLINE: '1', NO_PROXY: '127.0.0.1', TERM: 'dumb' };
  for (const prompt of ['Continue the inspection', 'What happened next?']) {
    const turn = run(cli, ['--print', '--no-tools', '--no-extensions', '--session', file,
      '--model', 'localtest/fixture', prompt], { cwd: home, env, timeout: 30000 });
    turn.child.stdin.end();
    await turn;
  }
  assert.equal(requests.length, 2);
  const history = requests[1].messages;
  for (const [role, text] of [['user', 'Inspect the test output'], ['tool', 'fixture exit status 1'],
    ['assistant', 'The file was absent.'], ['user', 'Continue the inspection'],
    ['assistant', 'Local reply 1'], ['user', 'What happened next?']]) {
    assert.ok(history.some(m => m.role === role && JSON.stringify(m.content).includes(text)), text);
  }
  const call = history.flatMap(m => m.tool_calls || []).find(c => c.function.name === (backend === 'claude' ? 'Bash' : 'exec_command'));
  assert.ok(call && history.some(m => m.role === 'tool' && m.tool_call_id === call.id));
  const continued = await readFile(file, 'utf8');
  const repeated = await run(process.execPath, args);
  assert.equal(JSON.parse(repeated.stdout).file, file);
  assert.equal(await readFile(file, 'utf8'), continued);
  if (backend === 'claude') {
    const before = await readFile(source);
    const migration = await run(process.execPath, [...args, '--migrate-claude'], {
      env: { ...env, CLAUDE_CONFIG_DIR: claudeConfig },
    });
    const report = JSON.parse(migration.stdout);
    assert.equal(report.migration, 'moved', report.migrationError);
    await assert.rejects(readFile(source), { code: 'ENOENT' });
    assert.deepEqual(await readFile(report.archive), before);
    assert.equal(await readFile(file, 'utf8'), continued);
  }
  const records = continued.trim().split('\n').map(JSON.parse);
  assert.equal(records[0].id, id);
  assert.match(JSON.stringify(records.at(-1)), /Local reply 2/);
}
