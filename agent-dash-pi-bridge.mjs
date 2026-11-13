// Pi-only extension: native commands never enter the model conversation.
// Authentication uses the running Pi runtime, including extension providers.
import { realpath, access } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const BRIDGE_COMMAND = 'agent-dash-native';
export const CATALOG_PREFIX = 'agent-dash-native-v1:';
export const SECRET_PREFIX = '[agent-dash:secret] ';
export const RESULT_PREFIX = '[agent-dash:native] ';

export async function readBuiltinCommands(executable) {
  const cli = await realpath(executable);
  const candidates = [join(dirname(cli), 'core/slash-commands.js'),
    join(dirname(cli), '../core/slash-commands.js')];
  let source;
  for (const candidate of candidates) {
    try { await access(candidate); source = candidate; break; } catch { /* Try bundled layout. */ }
  }
  if (!source) throw new Error('Native Pi catalog unavailable');
  const module = await import(pathToFileURL(source).href);
  const commands = module.BUILTIN_SLASH_COMMANDS;
  if (!Array.isArray(commands) || !commands.every(c => typeof c.name === 'string')) {
    throw new Error('This Pi version does not expose its native command catalog');
  }
  return commands.map(({ name, description }) => ({ name, description }));
}

// ModelRegistry is a compatibility facade. Its backing runtime is not a public
// extension API: keep the version-sensitive access here, guarded, and fail closed.
function authRuntime(ctx) {
  const runtime = ctx.modelRegistry?.runtime;
  if (!runtime || !['getProviders', 'login', 'logout', 'listCredentials']
    .every(method => typeof runtime[method] === 'function')) {
    throw new Error('Authentication bridge is unavailable in this Pi version');
  }
  return runtime;
}

export function authInteraction(ctx, signal = ctx.signal) {
  const secrets = new Set();
  const clean = value => {
    let text = String(value || "");
    for (const secret of secrets) text = text.replaceAll(secret, "[redacted]");
    return text;
  };
  return {
    signal,
    async prompt(prompt) {
      const dialogSignal = signal && prompt.signal
        ? AbortSignal.any([signal, prompt.signal]) : signal || prompt.signal;
      let value;
      if (prompt.type === 'select') {
        const choices = prompt.options.map(o => `${o.label} [${o.id}]`);
        const selected = await ctx.ui.select(clean(prompt.message), choices, { signal: dialogSignal });
        value = prompt.options[choices.indexOf(selected)]?.id;
      } else {
        // Manual OAuth codes are secrets too. Values go only to the RPC UI
        // response pipe, never to stdout, notices, session entries or prompts.
        // Legacy OAuth onPrompt labels API keys as plain text. Mask every
        // free-form auth answer rather than guessing from prompt wording.
        value = await ctx.ui.input(SECRET_PREFIX + clean(prompt.message),
          undefined, { signal: dialogSignal });
        if (typeof value === "string" && value) secrets.add(value);
      }
      if (typeof value !== 'string') throw new Error('Authentication cancelled');
      return value;
    },
    notify(event) {
      // Deliberately do not open a browser or replace the clipboard automatically.
      let text = event.message || event.instructions || '';
      if (event.type === 'auth_url') text += `\n${event.url}`;
      if (event.type === 'device_code') text += `\n${event.verificationUri}\nCode: ${event.userCode}`;
      for (const link of event.links || []) text += `\n${link.label || ''} ${link.url}`;
      if (text) ctx.ui.notify(clean(text), 'info');
    },
  };
}

async function authenticate(pi, ctx, command, args) {
  const runtime = authRuntime(ctx);
  const providers = command === 'logout'
    ? (await runtime.listCredentials()).map(c => ({ id: c.providerId, name: c.providerId }))
    : runtime.getProviders().filter(p => p.auth?.oauth || p.auth?.apiKey)
      .sort((a, b) => (a.name || a.id).localeCompare(b.name || b.id));
  let provider;
  if (args) provider = providers.find(p => p.id.toLowerCase() === args.toLowerCase());
  else {
    const choices = providers.map(p => `${p.name || p.id} [${p.id}]`);
    if (!choices.length) throw new Error('No providers available');
    const choice = await ctx.ui.select(command === 'login' ? 'Log in' : 'Log out', choices);
    provider = providers[choices.indexOf(choice)];
  }
  if (!provider) throw new Error('Provider not selected or unavailable');
  if (command === 'logout') {
    if (!await ctx.ui.confirm('Log out', `Remove stored authentication for ${provider.id}?`)) {
      throw new Error('Authentication cancelled');
    }
    await runtime.logout(provider.id, { signal: ctx.signal });
  } else {
    const methods = [];
    if (provider.auth?.oauth) methods.push({ type: 'oauth', name: provider.auth.oauth.name });
    if (provider.auth?.apiKey?.login) methods.push({ type: 'api_key', name: provider.auth.apiKey.name });
    let method = methods[0];
    if (methods.length > 1) {
      const choices = methods.map(m => `${m.name} [${m.type}]`);
      const choice = await ctx.ui.select('Authentication method', choices);
      method = methods[choices.indexOf(choice)];
    }
    const lifetime = new AbortController();
    const signal = ctx.signal ? AbortSignal.any([ctx.signal, lifetime.signal]) : lifetime.signal;
    try {
      if (!method || !await runtime.login(provider.id, method.type, authInteraction(ctx, signal))) {
        throw new Error('Authentication cancelled');
      }
    } finally {
      // OAuth callbacks can win a race against manual-code input. Retire any
      // remaining UI dialogs when the authentication operation has ended.
      lifetime.abort();
    }
  }
  return `/${command} completed for ${provider.id}`;
}

export function registerBridge(pi, commands, write) {
  const names = new Set(commands.map(c => c.name));
  const definition = {
    description: CATALOG_PREFIX + JSON.stringify(commands),
    async handler(encoded, ctx) {
      let request;
      try {
        request = JSON.parse(Buffer.from(encoded, 'base64').toString('utf8'));
        if (typeof request.id !== 'string' || !names.has(request.command)
            || typeof request.args !== 'string') throw new Error('Invalid native command');
      } catch {
        // No untrusted payloads or provider exception strings in output.
        return;
      }
      const { id, command, args } = request;
      // The SDK captures extension stdout. Use its RPC UI writer, preserving
      // ordering with large RPC replies rather than bypassing stdout buffering.
      const emit = record => write ? write(record)
        : ctx.ui.notify(RESULT_PREFIX + JSON.stringify(record), 'info');
      emit({ type: 'agent_dash_native_started', id, command });
      let message;
      try {
        if (ctx.mode !== 'rpc') throw new Error('This bridge is only for RPC clients');
        if (!ctx.isIdle()) throw new Error('Wait for Pi to become idle');
        switch (command) {
          case 'login':
          case 'logout':
            if (args && !/^[a-zA-Z0-9_.-]+$/.test(args)) {
              throw new Error('Provide only a provider id; enter credentials in the secure dialog');
            }
            message = await authenticate(pi, ctx, command, args);
            break;
          case 'reload':
            if (typeof ctx.reload !== 'function') {
              throw new Error('Pi RPC cannot reload resources; stop and resume this session instead');
            }
            await ctx.reload();
            message = 'Pi resources reloaded';
            break;
          case 'name':
            if (!args.trim()) throw new Error('Usage: /name <name>');
            pi.setSessionName(args.trim());
            message = 'Session name updated';
            break;
          case 'session':
            message = `Session: ${ctx.sessionManager.getSessionId()}\n`
              + `File: ${ctx.sessionManager.getSessionFile() || '(not saved)'}\n`
              + `Name: ${pi.getSessionName() || '(unnamed)'}`;
            break;
          default:
            throw new Error('This native command needs the Pi terminal UI; it was not sent to a model');
        }
        emit({ type: 'agent_dash_native_result', id, command, success: true, message });
      } catch (error) {
        emit({ type: 'agent_dash_native_result', id, command, success: false,
          message: command === 'login' || command === 'logout'
            ? 'Authentication failed or cancelled; not retried. No credentials were echoed.'
            : String(error?.message || 'Native command failed') });
      }
    },
  };
  pi.registerCommand(BRIDGE_COMMAND, definition);
  return definition.handler;
}

export default async function extension(pi) {
  // Main's normal CLI bootstrap still owns resources, providers and trust.
  const handle = registerBridge(pi, await readBuiltinCommands(process.argv[1]));
  bindControlChannel(pi, handle);
}

export function bindControlChannel(pi, handle, input = process.stdin) {
  let context;
  pi.on('session_start', (_event, ctx) => {
    context = ctx.mode === 'rpc' ? ctx : undefined;
    input.off('data', listen);
    if (context) input.on('data', listen);
  });
  // Unsolicited extension_ui_response is ignored by stock RPC, not treated as
  // a model prompt. Even a missing/unloaded bridge cannot leak a slash command
  // into model inference. Normal dialog replies use unrelated ids.
  let pending = '';
  let dropping = false;
  const listen = chunk => {
    pending += chunk.toString('utf8');
    let end;
    while ((end = pending.indexOf('\n')) !== -1) {
      const line = pending.slice(0, end);
      pending = pending.slice(end + 1);
      const skip = dropping;
      dropping = false;
      if (skip || !line.includes('agent-dash-native:')) continue;
      try {
        const record = JSON.parse(line);
        if (record.type === 'extension_ui_response'
            && record.id?.startsWith('agent-dash-native:') && context) {
          const data = JSON.parse(Buffer.from(record.value, 'base64').toString('utf8'));
          if (record.id === `agent-dash-native:${data.id}`) void handle(record.value, context);
        }
      } catch { /* Never log input, which may contain a credential response. */ }
    }
    if (pending.length > 65536) { pending = ''; dropping = true; }
  };
  const dispose = () => { input.off('data', listen); pending = ''; context = undefined; };
  pi.on('session_shutdown', dispose);
  return dispose;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]
    && process.argv[2] === '--catalog') {
  try {
    process.stdout.write(JSON.stringify(await readBuiltinCommands(process.argv[3])));
  } catch {
    process.exitCode = 1;
  }
}
