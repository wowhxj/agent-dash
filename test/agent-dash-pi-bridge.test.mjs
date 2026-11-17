import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { mkdtemp, mkdir, writeFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { registerBridge, readBuiltinCommands, bindControlChannel, bindFastStatus,
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

test('fast status follows structured tiers and resets on model/session changes', () => {
  const handlers = new Map(), statuses = [];
  const ctx = { mode: 'rpc', model: { provider: 'proxy', id: 'gpt' },
    ui: { setStatus: (key, value) => statuses.push([key, value]) } };
  bindFastStatus({ on: (name, handler) => handlers.set(name, handler) });
  const emit = (name, event = {}) => handlers.get(name)(event, ctx);
  emit('session_start');
  for (const tier of ['priority', 'fast', 'auto', 'default', undefined]) {
    const payload = { service_tier: tier, private: 'NOT-EXPORTED' };
    assert.equal(emit('before_provider_request', { payload }), undefined);
    assert.equal(payload.service_tier, tier);
    assert.equal(statuses.at(-1)[1], ['priority', 'fast'].includes(tier) ? tier : undefined);
  }
  emit('provider_stream_event', { provider: 'proxy', model: 'gpt',
    data: { response: { service_tier: 'priority' } } });
  assert.equal(statuses.at(-1)[1], 'priority');
  const count = statuses.length;
  emit('provider_stream_event', { provider: 'other', model: 'gpt',
    data: { response: { service_tier: 'default' } } });
  emit('provider_stream_event', { provider: 'proxy', model: 'gpt', data: {} });
  assert.equal(statuses.length, count);
  emit('provider_stream_event', { provider: 'proxy', model: 'gpt',
    data: { response: { service_tier: 'default' } } });
  assert.equal(statuses.at(-1)[1], undefined);
  emit('model_select');
  assert.deepEqual(statuses.at(-1), ['agent-dash-fast', undefined]);
  ctx.mode = 'tui';
  const rpcCount = statuses.length;
  emit('before_provider_request', { payload: { service_tier: 'fast' } });
  assert.equal(statuses.length, rpcCount);
  assert(!JSON.stringify(statuses).includes('NOT-EXPORTED'));
});

test('pi-fast confirms RPC mode immediately without inventing a provider tier', () => {
  const handlers = new Map(), statuses = [], notices = [];
  const original = function(...args) { notices.push(args); return 'delivered'; };
  const ctx = { mode: 'rpc', model: { provider: 'openai-codex', id: 'gpt-6.1-sol' },
    ui: { notify: original, setStatus: (key, value) => statuses.push([key, value]) } };
  bindFastStatus({ on: (name, handler) => handlers.set(name, handler) });
  const emit = (name, event = {}) => handlers.get(name)(event, ctx);
  const mode = () => statuses.filter(([key]) => key === 'agent-dash-fast-mode').at(-1)?.[1];
  const tier = () => statuses.filter(([key]) => key === 'agent-dash-fast').at(-1)?.[1];
  const enabled = 'Fast mode enabled; requests ask for Fast processing, which can increase API charges or subscription usage.';
  emit('session_start');
  for (const text of ['Fast mode enabled', '/fast:2', 'Fast mode is unavailable for the current provider/model.',
    'Failed to refresh model pricing', `quoted: ${enabled}`]) ctx.ui.notify(text, 'warning');
  ctx.ui.notify(enabled, 'info');
  assert.equal(mode(), undefined);
  assert.equal(ctx.ui.notify(enabled, 'warning'), 'delivered');
  assert.equal(mode(), 'enabled');
  assert.equal(tier(), undefined); // No model request was sent to learn the mode.
  emit('before_provider_request', { payload: {} });
  emit('provider_stream_event', { provider: 'openai-codex', model: 'gpt-6.1-sol',
    data: { response: { service_tier: 'default' } } });
  assert.equal(mode(), 'enabled'); // Preference is not the server's resolved tier.
  assert.equal(tier(), undefined);
  ctx.ui.notify('Fast mode disabled.', 'info');
  assert.equal(mode(), undefined);
  ctx.ui.notify(enabled, 'warning');
  emit('model_select');
  assert.equal(mode(), 'enabled'); // Re-selecting a model doesn't turn Fast off.
  const originalModel = ctx.model;
  ctx.model = { provider: 'cliproxyapi', id: 'gpt-6.1-sol' };
  emit('model_select');
  assert.equal(mode(), undefined);
  ctx.model = originalModel;
  emit('model_select');
  assert.equal(mode(), 'enabled'); // Restore the confirmed model's indication.
  emit('session_start'); // Rebinding must not stack wrappers or duplicate notices.
  const count = notices.length;
  ctx.ui.notify(enabled, 'warning');
  assert.equal(notices.length, count + 1);
  emit('session_shutdown');
  assert.equal(ctx.ui.notify, original);
  assert.equal(mode(), undefined);
  const statusCount = statuses.length;
  ctx.ui.notify(enabled, 'warning');
  assert.equal(statuses.length, statusCount);
  ctx.mode = 'tui';
  emit('session_start');
  assert.equal(ctx.ui.notify, original);
  assert.equal(statuses.length, statusCount);
});

test('CPA silent toggles use their source, saved preference and model capability, not command numbering', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'dash-cpa-fast-'));
  const handlers = new Map(), statuses = [];
  const commands = [
    { name: 'fast:9', sourceInfo: { source: 'npm:@router-for-me/pi-cliproxyapi-provider@1.4.25' } },
    { name: 'fast:1', sourceInfo: { source: 'npm:pi-fast' } },
  ];
  const ctx = { mode: 'rpc', model: { provider: 'my-cpa', id: 'gpt-6.1-sol', baseUrl: 'http://localhost:8317/v1' },
    ui: { notify() {}, setStatus: (key, value) => statuses.push([key, value]) } };
  const save = fast => writeFile(join(dir, 'cliproxyapi.json'), JSON.stringify({ fast, providerId: 'my-cpa', apiKey: 'NOT-EXPORTED' }));
  const mode = () => statuses.filter(([key]) => key === 'agent-dash-fast-mode').at(-1)?.[1];
  const refresh = bindFastStatus({ on: (name, handler) => handlers.set(name, handler), getCommands: () => commands }, dir, {});
  try {
    await save(false);
    await writeFile(join(dir, 'cliproxyapi-models.json'), JSON.stringify({
      inferenceBaseUrl: 'http://localhost:8317/v1/', fastModelIds: ['gpt-6.1-sol'],
    }));
    handlers.get('session_start')({}, ctx);
    assert.equal(mode(), undefined);
    await save(true);
    refresh(ctx, 'fast:1'); // pi-fast is not CPA, regardless of its suffix.
    assert.equal(mode(), undefined);
    refresh(ctx, 'fast:9'); // No notification, model inference or toggle guessing.
    assert.equal(mode(), 'enabled');
    assert.equal(statuses.filter(([key]) => key === 'agent-dash-fast').at(-1)[1], undefined);
    await save(false); // An unrelated Pi process changes the shared file.
    handlers.get('model_select')({}, ctx);
    assert.equal(mode(), 'enabled'); // Do not mirror another process's mode.
    for (const changed of [
      { ...ctx.model, provider: 'openai-codex' },
      { ...ctx.model, id: 'unsupported' },
      { ...ctx.model, baseUrl: 'http://other/v1' },
    ]) {
      handlers.get('model_select')({}, { ...ctx, model: changed });
      assert.equal(mode(), undefined);
    }
    handlers.get('model_select')({}, ctx);
    assert.equal(mode(), 'enabled');
    refresh(ctx, 'fast:9');
    assert.equal(mode(), undefined);
    // Failure/rollback leaves the persisted preference off: never infer on.
    refresh(ctx, 'fast:9');
    assert.equal(mode(), undefined);
    await writeFile(join(dir, 'cliproxyapi.json'), '{bad json');
    refresh(ctx, 'fast:9');
    assert.equal(mode(), undefined);
    await save(true);
    await rm(join(dir, 'cliproxyapi-models.json'));
    refresh(ctx, 'fast:9');
    assert.equal(mode(), undefined); // Unknown support is not supported.
    assert(!JSON.stringify(statuses).includes('NOT-EXPORTED'));
    handlers.get('session_shutdown')({}, ctx);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('CPA startup environment and local command preferences remain distinct', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'dash-cpa-env-'));
  const handlers = new Map(), statuses = [];
  const ctx = { mode: 'rpc', model: { provider: 'env-cpa', id: 'supported', baseUrl: 'http://localhost/v1/' },
    ui: { setStatus: (key, value) => statuses.push([key, value]) } };
  const mode = () => statuses.filter(([key]) => key === 'agent-dash-fast-mode').at(-1)?.[1];
  const refresh = bindFastStatus({ on: (name, handler) => handlers.set(name, handler),
    getCommands: () => [{ name: 'fast', sourceInfo: { path: '/checkout/pi-cliproxyapi-provider/extensions/index.ts' } }],
  }, dir, { CLIPROXYAPI_FAST: 'true', CLIPROXYAPI_PROVIDER_ID: 'env-cpa' });
  try {
    await writeFile(join(dir, 'cliproxyapi.json'), '{"fast":false}');
    await writeFile(join(dir, 'cliproxyapi-models.json'), JSON.stringify({
      inferenceBaseUrl: ctx.model.baseUrl, fastModelIds: ['supported'],
    }));
    handlers.get('session_start')({}, ctx);
    assert.equal(mode(), 'enabled'); // Env wins at process startup.
    refresh(ctx, 'fast');
    assert.equal(mode(), undefined); // A local toggle supersedes the startup env.
    handlers.get('session_start')({}, ctx);
    assert.equal(mode(), 'enabled');
    await rm(join(dir, 'cliproxyapi.json')); // Environment-only CPA setup.
    handlers.get('session_start')({}, ctx);
    assert.equal(mode(), 'enabled');
    handlers.get('session_shutdown')({}, ctx);
    assert.equal(mode(), undefined);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

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
test('reload cannot tear down the bridge while it is writing its own acknowledgement', async () => {
  const f = fixture();
  f.ctx.reload = () => { assert.fail('Reload must use the confirmed Emacs restart path'); };
  await f.invoke('reload');
  assert.equal(f.output.at(-1).success, false);
  assert.match(f.output.at(-1).message, /confirm restarting/);
});

test('bridge is not a plaintext auth dialog in TUI mode', async () => {
  const f = fixture(); f.ctx.mode = 'interactive';
  await f.invoke('login', 'offline'); assert.equal(f.inputs.length, 0);
});
test('control channel never interprets ordinary prompts or ordinary UI responses', async () => {
  const events = new Map(), pi = { on: (name, fn) => events.set(name, fn) };
  const input = new EventEmitter(), seen = [];
  input.on('data', () => {}); // The SDK's RPC reader owns stdin first.
  const dispose = bindControlChannel(pi, value => seen.push(value), input);
  events.get('session_start')({}, { mode: 'rpc' });
  input.emit('data', JSON.stringify({ type: 'prompt', message: 'agent-dash-native:anything' }) + '\n');
  input.emit('data', JSON.stringify({ type: 'extension_ui_response', id: 'ordinary', value: 'agent-dash-native:secret' }) + '\n');
  const value = encode('session');
  const line = JSON.stringify({ type: 'extension_ui_response', id: 'agent-dash-native:op', value }) + '\n';
  input.emit('data', line.slice(0, 15)); input.emit('data', line.slice(15));
  assert.deepEqual(seen, [value]);
  events.get('session_start')({}, { mode: 'rpc' });
  assert.equal(input.listenerCount('data'), 2);
  events.get('session_shutdown')(); assert.equal(input.listenerCount('data'), 1);
  events.get('session_start')({}, { mode: 'interactive' });
  assert.equal(input.listenerCount('data'), 1); dispose();
});
test('private fast refresh only reads after RPC completion, never invokes a command or model', () => {
  const events = new Map(), input = new EventEmitter(), seen = [], native = [];
  const pi = { on: (name, fn) => events.set(name, fn) };
  input.on('data', () => {});
  const ctx = { mode: 'rpc' };
  const dispose = bindControlChannel(pi, value => native.push(value), input,
    (context, value) => { assert.equal(context, ctx); seen.push(value); });
  events.get('session_start')({}, ctx);
  const packet = { type: 'extension_ui_response', id: 'agent-dash-fast-refresh:op', value: 'fast:1' };
  input.emit('data', JSON.stringify({ ...packet, type: 'prompt' }) + '\n');
  input.emit('data', JSON.stringify({ ...packet, id: 'ordinary' }) + '\n');
  assert.deepEqual(seen, []);
  input.emit('data', JSON.stringify(packet) + '\n');
  assert.deepEqual(seen, ['fast:1']);
  assert.deepEqual(native, []);
  dispose();
  input.emit('data', JSON.stringify(packet) + '\n');
  assert.deepEqual(seen, ['fast:1']);
});

test('control bridge cannot consume buffered startup queries before RPC is ready', async () => {
  const events = new Map(), pi = { on: (name, fn) => events.set(name, fn) };
  const input = new PassThrough(), seen = [], rpc = [];
  const dispose = bindControlChannel(pi, value => seen.push(value), input);
  input.write('{"id":"ad-1","type":"get_state"}\n{"id":"ad-2","type":"get_entries"}\n');
  events.get('session_start')({}, { mode: 'rpc' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(input.listenerCount('data'), 0);
  input.on('data', chunk => rpc.push(chunk.toString()));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(rpc.join(''), '{"id":"ad-1","type":"get_state"}\n{"id":"ad-2","type":"get_entries"}\n');
  const value = encode('session');
  input.write(JSON.stringify({ type: 'extension_ui_response', id: 'agent-dash-native:op', value }) + '\n');
  assert.deepEqual(seen, [value]);
  dispose();
  assert.equal(input.listenerCount('newListener'), 0);
  input.destroy();
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
