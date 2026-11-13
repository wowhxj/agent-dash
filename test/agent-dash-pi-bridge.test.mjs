import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtemp, mkdir, writeFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { registerBridge, readBuiltinCommands, bindControlChannel,
  BRIDGE_COMMAND, CATALOG_PREFIX, SECRET_PREFIX, RESULT_PREFIX } from '../agent-dash-pi-bridge.mjs';

const commands = ['login', 'logout', 'name', 'session', 'reload', 'trust'].map(name => ({ name }));
const encode = (command, args = '', id = 'op') => Buffer.from(JSON.stringify({ id, command, args })).toString('base64');
function fixture() {
  const output = [], notices = [], inputs = [], saved = [], removed = [];
  let definition, sessionName;
  const pi = {
    registerCommand(name, options) { assert.equal(name, BRIDGE_COMMAND); definition = options; },
    setSessionName(name) { sessionName = name; }, getSessionName() { return sessionName; },
    sendUserMessage() { assert.fail('Model invocation'); },
  };
  const runtime = {
    getProviders: () => [{ id: 'offline', name: 'Offline', auth: { apiKey: { name: 'API key', login() {} } } }],
    listCredentials: async () => [{ providerId: 'offline', type: 'api_key' }],
    async login(id, method, interaction) {
      assert.equal(id, 'offline'); assert.equal(method, 'api_key');
      const key = await interaction.prompt({ type: 'secret', message: 'API key', placeholder: 'omit-me' });
      interaction.notify({ type: 'progress', message: `configured ${key}` });
      saved.push({ id, key });
      return { type: 'api_key', key };
    },
    async logout(id) { removed.push(id); },
  };
  const ctx = {
    mode: 'rpc', signal: new AbortController().signal, isIdle: () => true,
    modelRegistry: { runtime },
    sessionManager: { getSessionId: () => 'test-session', getSessionFile: () => undefined },
    ui: {
      async select(_title, choices) { return choices[0]; },
      async input(title, placeholder) { inputs.push({ title, placeholder }); return 'FAKE-SECRET'; },
      async confirm() { return true; }, notify(text) { notices.push(text); },
    },
  };
  const handle = registerBridge(pi, commands, record => output.push(record));
  return { pi, ctx, runtime, output, notices, inputs, saved, removed,
    get definition() { return definition; }, invoke: (command, args) => handle(encode(command, args), ctx) };
}

test('advertises an exact native catalog without model commands', () => {
  const f = fixture();
  assert.deepEqual(JSON.parse(f.definition.description.slice(CATALOG_PREFIX.length)), commands);
});
test('api-key login uses secure UI, registered runtime, and redacts notices', async () => {
  const f = fixture(); await f.invoke('login', 'offline');
  assert.deepEqual(f.saved, [{ id: 'offline', key: 'FAKE-SECRET' }]);
  assert.equal(f.inputs[0].title, SECRET_PREFIX + 'API key');
  assert.equal(f.inputs[0].placeholder, undefined);
  assert.equal(f.output.at(-1).success, true);
  assert(!JSON.stringify([f.output, f.notices, f.inputs]).includes('FAKE-SECRET'));
});
test('legacy OAuth text prompts are masked as well', async () => {
  const f = fixture();
  f.runtime.login = async (_id, _method, interaction) => {
    const key = await interaction.prompt({ type: 'text', message: 'Legacy key' });
    interaction.notify({ type: 'progress', message: key });
    return {};
  };
  await f.invoke('login', 'offline');
  assert(f.inputs[0].title.startsWith(SECRET_PREFIX));
  assert(!JSON.stringify(f.notices).includes('FAKE-SECRET'));
});
test('default result transport uses SDK notifications, not captured stdout', async () => {
  const f = fixture();
  const handle = registerBridge(f.pi, commands);
  await handle(encode('session'), f.ctx);
  const results = f.notices.filter(value => value.startsWith(RESULT_PREFIX))
    .map(value => JSON.parse(value.slice(RESULT_PREFIX.length)));
  assert.equal(results[0].type, 'agent_dash_native_started');
  assert.equal(results[1].type, 'agent_dash_native_result');
  assert.equal(results[1].success, true);
});
test('provider and method pickers include extension OAuth methods', async () => {
  const f = fixture();
  f.runtime.getProviders = () => [{ id: 'extension', auth: { oauth: { name: 'Account' },
    apiKey: { name: 'Key', login() {} } } }];
  f.runtime.login = async (id, method) => { assert.equal(id, 'extension'); assert.equal(method, 'oauth'); return {}; };
  await f.invoke('login'); assert.equal(f.output.at(-1).success, true);
});
test('completed authentication retires its dialog lifetime', async () => {
  const f = fixture(); let signal;
  f.runtime.login = async (_id, _type, interaction) => {
    signal = interaction.signal; assert(!signal.aborted); return {};
  };
  await f.invoke('login', 'offline'); assert(signal.aborted);
});
test('cancelled secret input does not save or retry credentials', async () => {
  const f = fixture(); f.ctx.ui.input = async () => undefined;
  await f.invoke('login', 'offline');
  assert.equal(f.saved.length, 0); assert.equal(f.output.at(-1).success, false);
});
test('provider exceptions containing credentials are never echoed', async () => {
  const f = fixture(); f.runtime.login = async () => { throw new Error('FAKE-SECRET'); };
  await f.invoke('login', 'offline');
  assert.equal(f.output.at(-1).success, false);
  assert(!JSON.stringify(f.output).includes('FAKE-SECRET'));
});
test('credentials cannot be supplied as inline command arguments', async () => {
  const f = fixture(); await f.invoke('login', 'offline FAKE-SECRET');
  assert.equal(f.saved.length, 0); assert.equal(f.output.at(-1).success, false);
  assert(!JSON.stringify(f.output).includes('FAKE-SECRET'));
});
test('logout requires confirmation and uses runtime storage operation', async () => {
  const f = fixture(); f.ctx.ui.confirm = async () => false;
  await f.invoke('logout', 'offline'); assert.equal(f.removed.length, 0);
  f.ctx.ui.confirm = async () => true;
  await f.invoke('logout', 'offline'); assert.deepEqual(f.removed, ['offline']);
});
test('missing SDK auth capability fails closed', async () => {
  const f = fixture(); f.ctx.modelRegistry = {};
  await f.invoke('login', 'offline'); assert.equal(f.output.at(-1).success, false);
});
test('terminal-only operations and busy contexts cannot reach models', async () => {
  const f = fixture(); await f.invoke('trust'); assert.equal(f.output.at(-1).success, false);
  f.ctx.isIdle = () => false;
  await f.invoke('login', 'offline'); assert.equal(f.saved.length, 0);
});
test('bridge is not a plaintext auth dialog in TUI mode', async () => {
  const f = fixture(); f.ctx.mode = 'interactive';
  await f.invoke('login', 'offline'); assert.equal(f.inputs.length, 0);
});
test('control channel never interprets ordinary prompts or ordinary UI responses', async () => {
  const events = new Map(), pi = { on: (name, fn) => events.set(name, fn) };
  const input = new EventEmitter(), seen = [];
  const dispose = bindControlChannel(pi, value => seen.push(value), input);
  events.get('session_start')({}, { mode: 'rpc' });
  input.emit('data', JSON.stringify({ type: 'prompt', message: 'agent-dash-native:anything' }) + '\n');
  input.emit('data', JSON.stringify({ type: 'extension_ui_response', id: 'ordinary', value: 'agent-dash-native:secret' }) + '\n');
  const value = encode('session');
  const line = JSON.stringify({ type: 'extension_ui_response', id: 'agent-dash-native:op', value }) + '\n';
  input.emit('data', line.slice(0, 15)); input.emit('data', line.slice(15));
  assert.deepEqual(seen, [value]);
  events.get('session_start')({}, { mode: 'rpc' });
  assert.equal(input.listenerCount('data'), 1);
  events.get('session_shutdown')(); assert.equal(input.listenerCount('data'), 0);
  events.get('session_start')({}, { mode: 'interactive' });
  assert.equal(input.listenerCount('data'), 0); dispose();
});
test('native catalog supports ordinary and bundled CLI layouts via symlinks', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dash-native-'));
  try {
    await mkdir(join(root, 'dist/core'), { recursive: true });
    await mkdir(join(root, 'dist/bundle'));
    await writeFile(join(root, 'package.json'), '{"type":"module"}');
    await writeFile(join(root, 'dist/core/slash-commands.js'), 'export const BUILTIN_SLASH_COMMANDS=[{name:"login",description:"Login"}];');
    for (const entry of ['dist/cli.js', 'dist/bundle/cli.js']) {
      await writeFile(join(root, entry), '');
      const link = join(root, entry.includes('bundle') ? 'bundled-pi' : 'pi');
      await symlink(join(root, entry), link);
      assert.deepEqual(await readBuiltinCommands(link), [{ name: 'login', description: 'Login' }]);
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});
