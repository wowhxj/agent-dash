// Pi-only extension: native commands never enter the model conversation.
// Authentication uses the running Pi runtime, including extension providers.
import { realpath, access } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
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
            throw new Error('Use agent-dash /reload to confirm restarting and resuming the saved session');
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
  const refreshFast = bindFastStatus(pi, await readPiAgentDir(process.argv[1]));
  bindControlChannel(pi, handle, process.stdin, refreshFast);
}

// Keep the requested mode separate from the tier actually observed on the wire.
// pi-fast only emits its structured icon in TUI mode. In RPC, these exact
// successful-toggle notices are its only confirmation; never infer from /fast:N.
const PI_FAST_ENABLED_NOTICE = 'Fast mode enabled; requests ask for Fast processing, which can increase API charges or subscription usage.';
const PI_FAST_DISABLED_NOTICE = 'Fast mode disabled.';

// Ask this Pi installation for its agent dir (including PI_CODING_AGENT_DIR),
// not Emacs's environment. No preferences or plugin source files are modified.
async function readPiAgentDir(executable) {
  const cli = await realpath(executable);
  for (const path of [join(dirname(cli), 'config.js'), join(dirname(cli), '../config.js')]) {
    try {
      const config = await import(pathToFileURL(path).href);
      if (typeof config.getAgentDir === 'function') return config.getAgentDir();
    } catch { /* Unsupported layout: keep tier observation, fail closed on config. */ }
  }
}

function cpaCommand(command) {
  const source = command?.sourceInfo;
  return /^npm:@router-for-me\/pi-cliproxyapi-provider(?:@[^/]+)?$/.test(source?.source || '')
    || /(?:^|[\\/])pi-cliproxyapi-provider(?:[\\/]|$)/.test(source?.path || '');
}

function readCpaMode(agentDir, env, afterCommand) {
  if (!agentDir) return;
  try {
    let config = {};
    try { config = JSON.parse(readFileSync(join(agentDir, 'cliproxyapi.json'), 'utf8')); }
    catch (error) { if (afterCommand || error.code !== 'ENOENT') return; }
    if (afterCommand && typeof config.fast !== 'boolean') return;
    let enabled = config.fast ?? false;
    if (!afterCommand && env.CLIPROXYAPI_FAST?.trim()) {
      const flag = env.CLIPROXYAPI_FAST.trim().toLowerCase();
      if (!['1', 'true', 'yes', 'on', '0', 'false', 'no', 'off'].includes(flag)) return;
      enabled = ['1', 'true', 'yes', 'on'].includes(flag);
    }
    if (typeof enabled !== 'boolean') return;
    let cache;
    try { cache = JSON.parse(readFileSync(join(agentDir, 'cliproxyapi-models.json'), 'utf8')); }
    catch { /* No advertised capability: do not mark any model Fast. */ }
    return {
      enabled,
      provider: env.CLIPROXYAPI_PROVIDER_ID?.trim() || config.providerId?.trim() || 'cliproxyapi',
      baseUrl: cache?.inferenceBaseUrl,
      models: Array.isArray(cache?.fastModelIds) ? cache.fastModelIds : [],
    };
  } catch { /* Missing/invalid config is not proof of a successful toggle. */ }
}

export function bindFastStatus(pi, agentDir, env = process.env) {
  let restoreNotify, cpaMode, piFastEnabled = false;
  const piFastModels = new Set();
  const modelKey = ctx => JSON.stringify([ctx.model?.provider, ctx.model?.id]);
  const supportsCpa = ctx => cpaMode?.enabled && ctx.model?.provider === cpaMode.provider
    && cpaMode.models.includes(ctx.model.id)
    && typeof cpaMode.baseUrl === 'string' && cpaMode.baseUrl.length > 0
    && typeof ctx.model.baseUrl === 'string'
    && cpaMode.baseUrl.replace(/\/+$/, '') === ctx.model.baseUrl.replace(/\/+$/, '');
  const publishMode = ctx => {
    const enabled = (piFastEnabled && piFastModels.has(modelKey(ctx))) || supportsCpa(ctx);
    if (ctx.mode === 'rpc') ctx.ui.setStatus('agent-dash-fast-mode', enabled ? 'enabled' : undefined);
  };
  const publish = (ctx, tier) => {
    if (ctx.mode === 'rpc') {
      ctx.ui.setStatus('agent-dash-fast', tier === 'fast' || tier === 'priority' ? tier : undefined);
    }
  };
  pi.on('session_start', (_event, ctx) => {
    restoreNotify?.();
    piFastEnabled = false;
    piFastModels.clear();
    cpaMode = pi.getCommands?.().some(cpaCommand) ? readCpaMode(agentDir, env, false) : undefined;
    publishMode(ctx);
    publish(ctx);
    if (ctx.mode !== 'rpc' || typeof ctx.ui.notify !== 'function') return;
    const ui = ctx.ui, original = ui.notify;
    const notify = function(message, type, ...args) {
      const result = original.call(this, message, type, ...args);
      if ((message === PI_FAST_ENABLED_NOTICE && type === 'warning')
          || (message === PI_FAST_DISABLED_NOTICE && type === 'info')) {
        piFastEnabled = message === PI_FAST_ENABLED_NOTICE;
        if (piFastEnabled && ctx.model) piFastModels.add(modelKey(ctx));
        publishMode(ctx);
        publish(ctx); // A previous request's tier is stale after a mode change.
      }
      return result;
    };
    ui.notify = notify;
    restoreNotify = () => {
      if (ui.notify === notify) ui.notify = original;
      restoreNotify = undefined;
    };
  });
  pi.on('model_select', (_event, ctx) => {
    publishMode(ctx);
    publish(ctx);
  });
  pi.on('session_shutdown', (_event, ctx) => {
    restoreNotify?.();
    piFastEnabled = false;
    piFastModels.clear();
    cpaMode = undefined;
    publishMode(ctx);
    publish(ctx);
  });
  pi.on('before_provider_request', (event, ctx) => {
    publish(ctx, event.payload?.service_tier);
  });
  // Other extensions can rewrite the payload after our hook. Responses carry
  // the server's resolved tier, including when a requested tier was downgraded.
  pi.on('provider_stream_event', (event, ctx) => {
    const response = event.data?.response;
    if (event.provider === ctx.model?.provider && event.model === ctx.model?.id
        && response && Object.hasOwn(response, 'service_tier')) {
      publish(ctx, response.service_tier);
    }
  });
  // Read only after this process finishes the actual CPA command. Watching the
  // shared config would incorrectly mirror toggles made in other Pi processes.
  return (ctx, name) => {
    if (ctx.mode !== 'rpc' || !/^fast(?::[0-9]+)?$/.test(name)) return;
    if (!pi.getCommands?.().some(command => command.name === name && cpaCommand(command))) return;
    const next = readCpaMode(agentDir, env, true);
    if (next) cpaMode = next;
    publishMode(ctx);
    publish(ctx);
  };
}

export function bindControlChannel(pi, handle, input = process.stdin, refreshFast) {
  let context;
  // session_start precedes the SDK's RPC reader. Becoming stdin's first data
  // listener would drain buffered get_state/get_entries before the SDK sees them.
  const readerAdded = event => {
    if (event !== 'data') return;
    input.off('newListener', readerAdded);
    queueMicrotask(() => {
      if (context && input.listenerCount('data') > 0
          && !input.listeners('data').includes(listen)) input.on('data', listen);
    });
  };
  pi.on('session_start', (_event, ctx) => {
    context = ctx.mode === 'rpc' ? ctx : undefined;
    input.off('data', listen);
    input.off('newListener', readerAdded);
    if (context) {
      if (input.listenerCount('data') > 0) input.on('data', listen);
      else input.on('newListener', readerAdded);
    }
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
      if (skip || (!line.includes('agent-dash-native:')
                   && !line.includes('agent-dash-fast-refresh:'))) continue;
      try {
        const record = JSON.parse(line);
        if (record.type === 'extension_ui_response' && context
            && record.id?.startsWith('agent-dash-fast-refresh:') && typeof record.value === 'string') {
          refreshFast?.(context, record.value);
          continue;
        }
        if (record.type === 'extension_ui_response'
            && record.id?.startsWith('agent-dash-native:') && context) {
          const data = JSON.parse(Buffer.from(record.value, 'base64').toString('utf8'));
          if (record.id === `agent-dash-native:${data.id}`) void handle(record.value, context);
        }
      } catch { /* Never log input, which may contain a credential response. */ }
    }
    if (pending.length > 65536) { pending = ''; dropping = true; }
  };
  const dispose = () => {
    input.off('newListener', readerAdded);
    input.off('data', listen);
    pending = '';
    context = undefined;
  };
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
