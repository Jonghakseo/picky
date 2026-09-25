// Offline public-SDK probe. Copied into a temporary dependency root by the test.
import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createAgentSession, DefaultResourceLoader, SessionManager, SettingsManager, VERSION } from '@earendil-works/pi-coding-agent';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';

const root = process.env.PICKY_W0_ROOT;
assert.ok(root, 'isolated root is required');
assert.ok(['0.87.1', '0.85.0'].includes(VERSION), 'review characterization before changing SDK versions');
const trace = [];
const record = (event, data = {}) => trace.push({ event, ...data });
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const ticket = id => ({ customType: 'w0-completion', content: `RESULT ${id}`, display: true,
  details: { completionId: id, deliveryId: `delivery-${id}`, controlGeneration: 1 } });
let ordinal = 0;
async function fixture({ providerPaths = [], settled } = {}) {
  const cwd = join(root, `session-${++ordinal}`);
  const agentDir = join(cwd, 'agent');
  mkdirSync(agentDir, { recursive: true });
  const settingsManager = SettingsManager.inMemory({ packages: [], autoCompaction: { enabled: false }, compaction: { enabled: false, keepRecentTokens: 1, reserveTokens: 100 }, defaultProvider: 'w0-offline', defaultModel: 'finite' });
  let pi;
  const requests = [];
  const observations = [];
  const state = { open: true, blocked: 0, hold: undefined, entered: undefined };
  const loader = new DefaultResourceLoader({ cwd, agentDir, settingsManager,
    noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
    additionalExtensionPaths: providerPaths,
    extensionFactories: [api => {
      pi = api;
      api.on('context', event => {
        for (const message of event.messages) if (message.role === 'custom') observations.push(structuredClone(message));
      });
      api.on('agent_settled', async () => { if (settled) await settled({ pi, state }); });
      api.registerProvider('w0-offline', { baseUrl: 'http://127.0.0.1:1', apiKey: 'offline', api: 'w0-offline',
        models: [{ id: 'finite', name: 'Finite', reasoning: false, input: ['text'],
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 1000 }],
        streamSimple(model, context) {
          // SDK 0.85 includes callable tool definitions. Capture the wire-visible fields.
          requests.push(JSON.parse(JSON.stringify(context)));
          state.entered?.resolve();
          const hold = state.hold;
          state.hold = undefined;
          const stream = createAssistantMessageEventStream();
          const message = { role: 'assistant', content: [{ type: 'text', text: `ACK ${requests.length}` }],
            api: model.api, provider: model.provider, model: model.id,
            usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
              cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: 'stop', timestamp: Date.now() };
          stream.push({ type: 'start', partial: message });
          void (async () => { if (hold) await hold.promise; stream.push({ type: 'done', reason: 'stop', message }); stream.end(); })();
          return stream;
        },
      });
    }],
  });
  await loader.reload();
  assert.deepEqual(loader.getExtensions().errors, []);
  const { session } = await createAgentSession({ cwd, agentDir, settingsManager, resourceLoader: loader,
    sessionManager: SessionManager.create(cwd, join(cwd, 'sessions')), noTools: 'builtin' });
  const originalStream = session.agent.streamFunction;
  session.agent.streamFunction = (model, context, options) => {
    if (!state.open) { state.blocked++; throw new Error('W0 admission closed'); }
    return originalStream(model, context, options);
  };
  await session.setModel(session.modelRuntime.getModel('w0-offline', 'finite'));
  await session.bindExtensions({ mode: 'rpc', onError: error => { throw new Error(JSON.stringify(error)); } });
  session.subscribe(event => { if (event.type === 'message_end' || event.type === 'agent_settled') record(event.type, { role: event.message?.role, error: event.message?.errorMessage }); });
  return { session, requests, observations, state, pi,
    async close() { await session.extensionRunner.emit({ type: 'session_shutdown', reason: 'exit' }); session.dispose(); } };
}

async function correlation() {
  const f = await fixture();
  try {
    await f.session.sendCustomMessage(ticket('passive'), { triggerTurn: false });
    assert.equal(f.requests.length, 0, 'passive append is not consumption');
    await f.session.sendCustomMessage(ticket('idle'), { triggerTurn: true, deliverAs: 'followUp' });
    await f.session.waitForIdle();
    assert.equal(f.requests.length, 1);
    assert.ok(f.observations.some(m => m.details?.deliveryId === 'delivery-idle'));
    assert.deepEqual(f.observations.find(m => m.details?.deliveryId === 'delivery-idle').details, ticket('idle').details);
    assert.ok(JSON.stringify(f.requests[0].messages).includes('RESULT idle'));
    // Structured details are host-side metadata, not automatically provider payload.
    assert.ok(!JSON.stringify(f.requests[0].messages).includes('delivery-idle'));
    const entered = deferred(); const release = deferred();
    f.state.entered = entered; f.state.hold = release;
    const active = f.session.prompt('ACTIVE');
    await entered.promise;
    await f.session.sendCustomMessage(ticket('queued'), { triggerTurn: true, deliverAs: 'followUp' });
    assert.equal(f.requests.length, 2);
    release.resolve(); await active; await f.session.waitForIdle();
    assert.equal(f.requests.length, 3);
    assert.ok(f.observations.some(m => m.details?.deliveryId === 'delivery-queued'));
    assert.ok(JSON.stringify(f.requests[2].messages).includes('RESULT queued'));
    const entries = f.session.sessionManager.getEntries();
    assert.ok(JSON.stringify(entries).includes('delivery-queued'));
    assert.ok(entries.some(e => e.type === 'message' && e.message.role === 'assistant' && e.message.content.some(c => c.text === 'ACK 3')));
    assert.ok(readFileSync(f.session.sessionManager.getSessionFile(), 'utf8').includes('delivery-queued'));
    f.pi.on('session_before_compact', event => ({ compaction: { summary: 'Offline compacted summary',
      firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: event.preparation.tokensBefore } }));
    await f.session.compact();
    assert.ok(f.session.sessionManager.getEntries().some(e => e.type === 'compaction'));
    await f.session.sendCustomMessage(ticket('after-compact'), { triggerTurn: true });
    await f.session.waitForIdle();
    assert.ok(f.observations.some(m => m.details?.deliveryId === 'delivery-after-compact'));
    assert.ok(JSON.stringify(f.requests.at(-1).messages).includes('RESULT after-compact'));
    assert.ok(readFileSync(f.session.sessionManager.getSessionFile(), 'utf8').includes('delivery-queued'));
    record('compaction', { entryPersisted: true, postCompactionDeliveryConsumed: true });
    record('correlation', { requests: f.requests.length, detailsPersisted: true, detailsInProviderPayload: false });
  } finally { await f.close(); }
}

async function settlement(fenced) {
  let once = false; let stop;
  let f;
  f = await fixture({ settled: async ({ pi, state }) => {
    if (once) return; once = true;
    await pi.sendMessage(ticket('settled'), { triggerTurn: true, deliverAs: 'followUp' });
    if (fenced) state.open = false;
    f.session.clearQueue();
    // Awaiting abort *inside* agent_settled would wait for this handler itself.
    stop = f.session.abort();
  } });
  try {
    await f.session.prompt('INITIAL'); await f.session.waitForIdle(); await stop;
    assert.equal(f.requests.length, fenced || VERSION === '0.85.0' ? 1 : 2);
    assert.equal(f.state.blocked, fenced ? 1 : 0);
    if (!fenced && VERSION === '0.87.1') assert.ok(f.observations.some(m => m.details?.deliveryId === 'delivery-settled'));
    record('settlement', { fenced, externalRequests: f.requests.length, admissionRejections: f.state.blocked });
  } finally { await f.close(); }
}

async function providers() {
  const paths = ['bash-async', 'subagent'].map(name => join(root, 'packages', name, 'index.ts'));
  const f = await fixture({ providerPaths: paths });
  try {
    await f.session.prompt('LOAD ONLY; no tools');
    assert.equal(f.requests.length, 1, 'loaded providers must allow an actual offline response');
    const names = f.session.getAllTools().map(tool => tool.name);
    assert.ok(names.includes('bash_async'));
    assert.ok(names.includes('subagent'));
    const bash = f.session.getToolDefinition('bash_async');
    const context = f.session.extensionRunner.createContext();
    const marker = join(root, 'must-not-start-' + VERSION);
    const cancelled = await bash.execute('cancelled', { action: 'start', command: `touch '${marker}'` }, AbortSignal.abort(), undefined, context);
    assert.ok(cancelled.details.error?.includes('cancelled'));
    assert.equal(existsSync(marker), false);
    const completion = deferred();
    const unsubscribe = f.session.subscribe(event => {
      if (event.type === 'message_end' && event.message?.customType === 'bash-async-completion') completion.resolve(event.message);
    });
    const started = await bash.execute('finite', { action: 'start', command: 'printf W0_REAL_BASH', timeout: 5 }, undefined, undefined, context);
    assert.ok(started.details.jobId);
    const message = await completion.promise;
    await f.session.waitForIdle(); unsubscribe();
    assert.ok(message.content.includes('W0_REAL_BASH'));
    assert.ok(message.details.jobIds.includes(started.details.jobId));
    assert.ok(JSON.stringify(f.requests.at(-1).messages).includes('W0_REAL_BASH'));
    record('real-bash', { cancelledBeforeAcceptance: true, completionConsumed: true, jobId: started.details.jobId });
    record('providers-loaded', { version: VERSION, tools: ['bash_async', 'subagent'] });
  } finally { await f.close(); }
}


async function resourceExit() {
  const { JobManager } = await import(join(root, 'packages/bash-async/job-manager.ts'));
  const f = await fixture();
  const ready = deferred(); const cancellation = deferred();
  let child; let closed = false; let resultResolved = false;
  const manager = new JobManager({ logsDirectory: join(root, 'job-logs'),
    execute: ({ job }) => new Promise((resolve, reject) => {
      // External executor is fake; resource lifetime is a real OS child process.
      child = spawn(process.execPath, ['-e', `process.on('message', m => { if (m === 'exit') process.exit(0); }); process.send('ready');`], { stdio: ['ignore', 'ignore', 'pipe', 'ipc'] });
      child.once('error', reject);
      child.once('message', () => ready.resolve());
      child.once('close', code => { closed = true; resultResolved = true; resolve({ exitCode: code }); });
      job.abortController.signal.addEventListener('abort', () => cancellation.resolve(), { once: true });
    }),
  });
  try {
    const started = await manager.start({ command: 'finite-controlled-child', timeoutSeconds: 0, context: f.session.extensionRunner.createContext() });
    assert.ok(started.ok); await ready.promise;
    const killing = manager.kill(started.details.jobId, 10);
    await cancellation.promise;
    assert.equal(closed, false); assert.equal(resultResolved, false);
    const result = await killing;
    assert.equal(result.terminalCause, 'cleanup_error');
    assert.equal(closed, false); assert.equal(resultResolved, false);
    process.kill(child.pid, 0);
    record('termination-unconfirmed', { status: result.status, terminalCause: result.terminalCause, resourceAlive: true, runnerResolved: false });
    const exited = once(child, 'close'); child.send('exit'); await exited;
    assert.equal(closed, true); assert.equal(resultResolved, true);
    record('late-resource-exit', { resourceAlive: false, runnerResolved: true });
  } finally {
    if (child && !closed) { const exited = once(child, 'close'); child.kill('SIGKILL'); await exited; }
    manager.beginShutdown(); await manager.abortAndSettleAll(); manager.closeAllLogs(); await f.close();
  }
}

try {
  await correlation();
  await settlement(false);
  await settlement(true);
  await providers();
  await resourceExit();
  console.log('W0_EVIDENCE ' + JSON.stringify({ version: VERSION, trace }));
  process.exit(0);
} catch (error) {
  console.error(JSON.stringify({ version: VERSION, trace }));
  console.error(error);
  process.exit(1);
}
