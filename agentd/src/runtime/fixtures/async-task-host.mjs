// Offline public-SDK probe. Copied into a temporary dependency root by the test.
import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { once } from 'node:events';
import { createAgentSession, DefaultResourceLoader, SessionManager, SettingsManager, VERSION } from '@earendil-works/pi-coding-agent';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';

const root = process.env.PICKY_W0_ROOT;
assert.ok(root, 'isolated root is required');
assert.ok(['1.1.0', '0.85.0'].includes(VERSION), 'review characterization before changing SDK versions');
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
    pi.sendMessage(ticket('settled'), { triggerTurn: true, deliverAs: 'followUp' });
    if (fenced) state.open = false;
    f.session.clearQueue();
    // Awaiting abort *inside* agent_settled would wait for this handler itself.
    stop = f.session.abort();
  } });
  try {
    await f.session.prompt('INITIAL'); await f.session.waitForIdle(); await stop;
    assert.equal(f.requests.length, fenced || VERSION === '0.85.0' ? 1 : 2);
    assert.equal(f.state.blocked, fenced ? 1 : 0);
    if (!fenced && VERSION === '1.1.0') assert.ok(f.observations.some(m => m.details?.deliveryId === 'delivery-settled'));
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
    const context = VERSION === '0.85.0'
      ? f.session.extensionRunner.createContext()
      : f.session.extensionRunner.createToolContext('w0-provider', undefined);
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



async function compactionOverlap() {
  const f = await fixture();
  const entered = deferred(); const release = deferred();
  try {
    await f.session.prompt('BEFORE COMPACTION');
    f.pi.on('session_before_compact', async event => {
      entered.resolve(); await release.promise;
      return { compaction: { summary: 'Held offline summary',
        firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: event.preparation.tokensBefore } };
    });
    const compacting = f.session.compact();
    await entered.promise;
    assert.equal(f.session.isCompacting, true);
    // This deliberately probes SDK behavior without a future host scheduler.
    const delivery = f.session.sendCustomMessage(ticket('during-compact'), { triggerTurn: true });
    let deliveryError;
    await delivery.catch(error => { deliveryError = String(error); });
    const requestsDuringCompaction = f.requests.length - 1;
    release.resolve(); await compacting; await f.session.waitForIdle();
    assert.equal(deliveryError, undefined);
    assert.equal(requestsDuringCompaction, 1);
    assert.ok(JSON.stringify(f.requests.at(-1).messages).includes('RESULT during-compact'));
    assert.ok(readFileSync(f.session.sessionManager.getSessionFile(), 'utf8').includes('delivery-during-compact'));
    record('compaction-overlap', { requestsDuringCompaction, deliveryPersisted: true,
      compactionPersisted: f.session.sessionManager.getEntries().some(e => e.type === 'compaction') });
  } finally { release.resolve(); await f.close(); }
}

async function generationReopen() {
  const f = await fixture();
  const original = f.session.agent.streamFunction;
  let generation = 1; let open = true; let pending = [];
  const admissions = [];
  const observed = new Set();
  f.pi.on('context', event => {
    pending = event.messages.filter(m => m.role === 'custom' && m.details?.completionId)
      .map(m => ({ ...m.details })).filter(d => !observed.has(d.deliveryId));
    for (const delivery of pending) observed.add(delivery.deliveryId);
  });
  f.session.agent.streamFunction = (model, context, options) => {
    const stale = pending.some(d => d.controlGeneration !== generation);
    admissions.push({ generation, open, deliveries: pending, admitted: open && !stale });
    if (!open || stale) throw new Error('W0 stale generation');
    return original(model, context, options);
  };
  try {
    await f.session.prompt('AUTHORIZED GENERATION 1');
    open = false; generation++;
    await f.session.sendCustomMessage(ticket('closed-generation'), { triggerTurn: true });
    assert.equal(f.requests.length, 1);
    // Reopen alone cannot turn an old completion into a current authorization.
    open = true;
    await f.session.sendCustomMessage(ticket('stale-after-reopen'), { triggerTurn: true });
    assert.equal(f.requests.length, 1);
    // Historical rejected IDs are not a new delivery on an authorized turn.
    await f.session.prompt('AUTHORIZED GENERATION 2');
    assert.equal(f.requests.length, 2);
    assert.ok(JSON.stringify(f.requests.at(-1).messages).includes('AUTHORIZED GENERATION 2'));
    assert.equal(admissions[1].admitted, false);
    assert.ok(admissions[2].deliveries.some(d => d.deliveryId === 'delivery-stale-after-reopen'));
    assert.equal(admissions.at(-1).generation, 2);
    assert.equal(admissions.at(-1).admitted, true);
    record('generation-reopen', { admissions, externalRequests: f.requests.length,
      resetBoundary: 'same transcript; observed delivery IDs distinguish new arrivals, not durable ACKs' });
  } finally { await f.close(); }
}

async function subagentLifecycle() {
  // Only this finite executable can be found as pi. It never loads an SDK/model.
  const bin = join(root, 'fake-bin'); mkdirSync(bin, { recursive: true });
  const socketPath = join(root, 'child.sock');
  writeFileSync(join(bin, 'pi'), `#!${process.execPath}
import net from 'node:net';
const socket = net.connect(process.env.PICKY_W0_SOCKET);
process.on('SIGTERM', () => socket.write('signal\\n'));
socket.on('connect', () => socket.write(process.pid + '\\n'));
socket.on('data', data => {
  if (data.toString().includes('result')) console.log(JSON.stringify({type:'message_end',message:{role:'assistant',content:[{type:'text',text:'FINITE CHILD RESULT'}],stopReason:'stop',usage:{input:0,output:0,cacheRead:0,cacheWrite:0,cost:{total:0}}}}));
  if (data.toString().includes('exit')) process.exit(0);
});
`, { mode: 0o755 });
  const previousPath = process.env.PATH;
  process.env.PATH = bin; process.env.PICKY_W0_SOCKET = socketPath;
  const connections = []; let next = deferred();
  const server = createServer(socket => {
    let buffer = '';
    socket.on('data', data => {
      buffer += data.toString();
      if (buffer.includes('\n') && !socket.childPid) {
        socket.childPid = Number(buffer.split('\n')[0]); connections.push(socket); next.resolve(socket);
      }
    });
  });
  server.listen(socketPath); await once(server, 'listening');
  const agentsDir = join(process.env.PI_CODING_AGENT_DIR, 'agents'); mkdirSync(agentsDir, { recursive: true });
  writeFileSync(join(agentsDir, 'finite.md'), '---\nname: finite\ndescription: Offline finite fixture\ntools: []\n---\nNo model is executed.\n');
  const f = await fixture({ providerPaths: [join(root, 'packages/subagent/index.ts')] });
  try {
    // The real package registers its tool lazily from before_agent_start.
    await f.session.prompt('LOAD FINITE SUBAGENT; no tools');
    const tool = f.session.getToolDefinition('subagent');
    const context = VERSION === '0.85.0'
      ? f.session.extensionRunner.createContext()
      : f.session.extensionRunner.createToolContext('w0-provider', undefined);
    assert.equal(context.hasUI, false);
    let resolved = false;
    const run = tool.execute('finite-child', { command: 'subagent run finite --isolated -- finite fixture' }, undefined, undefined, context)
      .then(result => { resolved = true; return result; });
    const child = await Promise.race([next.promise, run.then(result => { throw new Error('Child never connected: ' + JSON.stringify(result)); })]);
    assert.equal(resolved, false); process.kill(child.childPid, 0);
    const closed = once(child, 'close'); child.write('result exit\n');
    const result = await run; await closed;
    assert.ok(JSON.stringify(result).includes('FINITE CHILD RESULT'));
    assert.notEqual(result.isError, true);
    record('subagent-headless', { resolvedBeforeExit: false, resultCaptured: true });

    const { runSingleAgent } = await import(join(root, 'packages/subagent/runner.ts'));
    const agent = { name: 'finite', description: 'fixture', source: 'user', filePath: join(agentsDir, 'finite.md'),
      systemPrompt: 'Offline', runtime: 'pi', tools: [], toolsConfigured: true };
    next = deferred();
    const diagnostics = []; const exited = deferred();
    const running = runSingleAgent(root, [agent], 'finite', 'finite', undefined, undefined, undefined,
      results => ({ mode: 'single', results }), { onDiagnostic: event => { diagnostics.push(event); if (event.event === 'exit') exited.resolve(event); } });
    const lingering = await Promise.race([next.promise, running.then(result => { throw new Error('Runner child never connected: ' + JSON.stringify(result)); })]);
    lingering.write('result\n');
    const runnerResult = await running;
    assert.equal(runnerResult.exitCode, 0);
    process.kill(lingering.childPid, 0);
    assert.ok(diagnostics.some(e => e.settleReason === 'terminal_message_fallback_timeout'));
    record('subagent-result-before-exit', { resourceAlive: true, runnerResolved: true,
      settleReason: 'terminal_message_fallback_timeout' });
    const lateClose = once(lingering, 'close'); lingering.write('exit\n'); await lateClose; await exited.promise;
    record('subagent-late-exit', { resourceAlive: false });

    next = deferred();
    const controller = new AbortController(); const abortSent = deferred();
    let abortResolved = false;
    const aborting = runSingleAgent(root, [agent], 'finite', 'cancel finite', undefined, controller.signal, undefined,
      results => ({ mode: 'single', results }), { onDiagnostic: event => {
        if (event.event === 'kill_result') abortSent.resolve();
      } }).then(() => { abortResolved = true; return undefined; }, error => { abortResolved = true; return error; });
    const cancelledChild = await Promise.race([next.promise, aborting.then(error => { throw error ?? new Error('No child'); })]);
    controller.abort(); await abortSent.promise;
    assert.equal(abortResolved, false); process.kill(cancelledChild.childPid, 0);
    cancelledChild.write('exit\n');
    const abortError = await aborting;
    assert.match(String(abortError), /Subagent was aborted/);
    record('subagent-cancellation', { resolvedAtSignal: false, aliveAtSignal: true, abortedAfterExit: true });
  } finally {
    for (const socket of connections) { try { process.kill(socket.childPid, 'SIGKILL'); } catch {} socket.destroy(); }
    await new Promise(resolve => server.close(resolve));
    process.env.PATH = previousPath; delete process.env.PICKY_W0_SOCKET;
    await f.close();
  }
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
  await compactionOverlap();
  await generationReopen();
  await subagentLifecycle();
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
