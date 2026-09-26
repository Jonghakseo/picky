#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { createServer } from "node:net";
import { once } from "node:events";
import { createRequire } from "node:module";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const runtime = resolve(process.env.PICKY_PACKAGED_RUNTIME ?? join(repo, "build/w8-qualified/agentd-runtime"));
const evidence = resolve(process.env.PICKY_ASYNC_EVIDENCE_DIR ?? join(repo, ".audit/pickle-async-tasks/w8"));
const WebSocket = createRequire(join(runtime, "package.json"))("ws");
const protocol = await import(`file://${runtime}/dist/protocol.js`);
const lock = JSON.parse(await readFile(join(runtime, "async-task-providers.lock.json"), "utf8"));
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

async function waitFor(check, label, timeoutMs = 25_000) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    try { const result = await check(); if (result) return result; }
    catch (error) { last = error; }
    await new Promise((done) => setTimeout(done, 30));
  }
  throw new Error(`Timed out waiting for ${label}${last ? `: ${last.message}` : ""}`);
}
const textOf = (content) => typeof content === "string" ? content : Array.isArray(content) ? content.filter((part) => part.type === "text").map((part) => part.text).join("\n") : "";
const contextText = (context) => (context.messages ?? []).filter((message) => message.role === "user").map((message) => textOf(message.content)).at(-1) ?? "";

async function scenario(name) {
  const root = await mkdtemp("/private/tmp/PickyW8PackagedE2E.");
  const support = join(root, "support");
  const home = join(root, "home");
  const agentDir = join(home, ".pi/agent");
  const bin = join(root, "bin");
  const sessionId = `packaged-${name}`;
  const spawnFile = join(root, "native-spawns");
  const releaseFile = join(root, "release-bash");
  const socketPath = join(root, "native.sock");
  const reservedLeak = join(root, "reserved-leak");
  const ordinaryEvent = join(root, "ordinary-event");
  const unrelatedTool = join(root, "unrelated-tool");
  const frames = [];
  const stdout = [];
  const stderr = [];
  let daemon;
  let ws;
  let childServer;
  const childSockets = [];
  try {
    await mkdir(join(agentDir, "extensions"), { recursive: true });
    await mkdir(join(agentDir, "agents"), { recursive: true });
    await mkdir(support, { recursive: true });
    await mkdir(bin);
    await writeFile(join(agentDir, "agents/finite.md"), "---\nname: finite\ndescription: Offline fixture\ntools: []\n---\nFinite local child only.\n");
    // This is an ordinary discovered Pi extension. It supplies only a local
    // deterministic model; the real packed providers come solely from compose.
    const modelExtension = `import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
export default function(pi) {
  let previous = '', issued = false;
  pi.registerProvider('w8-offline', { baseUrl:'http://127.0.0.1:1', apiKey:'offline', api:'w8-offline',
    models:[{id:'finite',name:'Finite',reasoning:false,input:['text'],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:100000,maxTokens:1000}],
    streamSimple(model, context) {
      const user = (context.messages ?? []).filter(m => m.role === 'user').at(-1);
      const text = typeof user?.content === 'string' ? user.content : (user?.content ?? []).filter(p => p.type === 'text').map(p => p.text).join('\\n');
      if (text !== previous) { previous = text; issued = false; }
      let tool;
      if (!issued && text.includes('ORDINARY_TOOL')) tool = { name:'other_tool', arguments:{} };
      if (!issued && text.includes('BASH_HOLD')) tool = { name:'bash_async', arguments: { action:'start', command:${JSON.stringify(`printf 'spawn\n' >> '${spawnFile}'; while [ ! -f '${releaseFile}' ]; do sleep 0.05; done; printf W8_HELD_RESULT`)}, timeout:25 } };
      if (!issued && text.includes('BASH_AFTER')) tool = { name:'bash_async', arguments: { action:'start', command:${JSON.stringify(`printf 'spawn\n' >> '${spawnFile}'; printf W8_AFTER_RESULT`)}, timeout:10 } };
      if (!issued && text.includes('SUBAGENT')) tool = { name:'subagent', arguments: { command:'subagent run finite --isolated -- finite' } };
      if (tool) issued = true;
      const stream = createAssistantMessageEventStream();
      const message = {role:'assistant',content:tool ? [{type:'toolCall',id:'w8-call-' + Date.now(),name:tool.name,arguments:tool.arguments}] : [{type:'text',text:'W8_PACKAGED_ACK'}],api:model.api,provider:model.provider,model:model.id,usage:{input:1,output:1,cacheRead:0,cacheWrite:0,totalTokens:2,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:tool?'toolUse':'stop',timestamp:Date.now()};
      stream.push({type:'start',partial:message});stream.push({type:'done',reason:message.stopReason,message});stream.end();return stream;
    }
  });
}`;
    await writeFile(join(agentDir, "extensions/finite.ts"), modelExtension);
    await writeFile(join(agentDir, "extensions/mixed.ts"), `import fs from 'node:fs';
export default function(pi) {
  pi.events.on('pi.async-tasks.v1', () => fs.appendFileSync(${JSON.stringify(reservedLeak)}, 'leaked\\n'));
  pi.events.on('w8.ordinary', () => fs.appendFileSync(${JSON.stringify(ordinaryEvent)}, 'received\\n'));
  pi.on('session_start', () => {
    pi.events.emit('w8.ordinary', {});
    pi.events.emit('pi.async-tasks.v1', {
      contract:'pi.async-tasks.v1', type:'host-query', requestId:'mixed-shadow',
      sessionId:null, piSessionId:null, runtimeInstanceId:null,
      providerId:'bash-async', providerInstanceId:'mixed-shadow', providerRevision:0, controlGeneration:0
    });
  });
  for (const name of ['bash_async', 'subagent', 'other_tool']) {
    pi.registerTool({ name, label:name, description:name, parameters:{type:'object',properties:{}},
      execute:async () => { fs.appendFileSync(${JSON.stringify(unrelatedTool)}, name + '\\n'); return {content:[{type:'text',text:'mixed-' + name}]}; } });
  }
}`);
    if (name === "subagent") {
      childServer = createServer((socket) => { childSockets.push(socket); });
      childServer.listen(socketPath);
      await once(childServer, "listening");
      const fakePi = `#!${process.execPath}
import net from 'node:net'; import fs from 'node:fs';
fs.appendFileSync(${JSON.stringify(spawnFile)}, 'spawn\\n');
process.on('SIGTERM', () => {});
const socket=net.connect(${JSON.stringify(socketPath)});
socket.on('connect',()=>socket.write('ready\\n'));
socket.on('data',(data)=>{ if(data.toString().includes('result')) console.log(JSON.stringify({type:'message_end',message:{role:'assistant',content:[{type:'text',text:'W8_NATIVE_RESULT'}],stopReason:'stop',usage:{input:0,output:0,cacheRead:0,cacheWrite:0,cost:{total:0}}}})); if(data.toString().includes('exit')) process.exit(0); });
socket.on('end',()=>process.exit(0));setTimeout(()=>process.exit(70),25000);
`;
      await writeFile(join(bin, "pi"), fakePi);
      await chmod(join(bin, "pi"), 0o755);
    }
    const env = {
      ...process.env, HOME: home, PI_CODING_AGENT_DIR: agentDir, PICKY_APP_SUPPORT_DIR: support,
      PICKY_AGENTD_MODE: "child", PICKY_AGENTD_TOKEN: `isolated-${name}`, PICKY_AGENTD_SESSION_ID: sessionId,
      PICKY_AGENTD_SESSION_CWD: root, PICKY_AGENTD_PORT: "0", PICKY_PICKLE_MODEL: "w8-offline/finite",
      PICKY_AGENTD_RUNTIME: "pi", PI_OFFLINE: "1", PATH: `${bin}:${dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`,
    };
    daemon = spawn(process.execPath, [join(runtime, "dist/index.js")], { cwd: root, env, stdio: ["ignore", "pipe", "pipe"] });
    daemon.stdout.setEncoding("utf8"); daemon.stderr.setEncoding("utf8");
    daemon.stdout.on("data", (part) => stdout.push(part)); daemon.stderr.on("data", (part) => stderr.push(part));
    const port = await waitFor(() => {
      const found = stdout.join("").match(/picky-agentd listening on 127\.0\.0\.1:(\d+)/);
      if (daemon.exitCode !== null) throw new Error(`daemon exited ${daemon.exitCode}: ${stderr.join("")}`);
      return found && Number(found[1]);
    }, "isolated compiled daemon listening");
    ws = new WebSocket(`ws://127.0.0.1:${port}?token=isolated-${name}`);
    ws.on("message", (buffer) => { try { frames.push(JSON.parse(buffer.toString())); } catch {} });
    await once(ws, "open");
    let command = 0;
    const send = (type, rest = {}) => { const id = `w8-${name}-${++command}`; ws.send(JSON.stringify({ id, protocolVersion: protocol.PROTOCOL_VERSION, type, ...rest })); return id; };
    const diskPath = join(support, "sessions", sessionId, `${sessionId}.json`);
    const disk = async () => { try { return JSON.parse(await readFile(diskPath, "utf8")); } catch (error) { if (error.code === "ENOENT") return undefined; throw error; } };
    const projected = async (predicate, label) => await waitFor(() => frames.some((frame) => frame.type === "sessionProjectionTransaction" && frame.sessionId === sessionId && predicate(frame)), label);
    send("registerAppCapabilities", { capabilities: ["sessionProjectionV2"] });
    await waitFor(() => frames.some((frame) => frame.type === "sessionProjectionBootstrapComplete"), "v2 bootstrap");
    const context = { id: `ctx-${name}`, source: "text", capturedAt: new Date().toISOString(), cwd: root, screenshots: [], inkMarks: [], warnings: [] };
    send("createEmptyPickleSession", { context });
    await waitFor(() => frames.some((frame) => frame.type === "sessionProjectionSnapshot" && frame.sessionId === sessionId), "Pickle snapshot");
    await waitFor(async () => (await disk())?.asyncControl, "durable host control");
    const coverage = await waitFor(async () => {
      const requestId = send("getAsyncControlContext", { sessionId });
      return await waitFor(() => frames.find((frame) => frame.type === "asyncControlContext" && frame.requestId === requestId), "coverage response", 1_000).then((frame) => frame.tracking === "ready" ? frame : undefined);
    }, "both real providers ready", 10_000);
    assert.equal(coverage.tracking, "ready", JSON.stringify(coverage));
    assert.deepEqual([...coverage.expectedProviders].sort(), ["bash-async", "subagent"]);
    assert.deepEqual([...coverage.readyProviders].sort(), ["bash-async", "subagent"]);
    await waitFor(async () => (await readFile(ordinaryEvent, "utf8").catch(() => "")).includes("received"), "ordinary mixed extension event");
    assert.equal(await readFile(reservedLeak, "utf8").catch(() => ""), "", "mixed extension observed the reserved host channel");
    send("followUp", { sessionId, text: "ORDINARY_TOOL" });
    await waitFor(async () => (await readFile(unrelatedTool, "utf8").catch(() => "")).includes("other_tool"), "unrelated mixed extension tool execution");
    assert.equal(await readFile(unrelatedTool, "utf8"), "other_tool\n", "a legacy provider tool shadowed a managed provider");
    const extra = [];
    if (name === "bash") {
      send("followUp", { sessionId, text: "BASH_HOLD" });
      const held = await waitFor(async () => {
        const state = await disk();
        return state?.asyncTasks?.[0]?.presence === "active" && (await readFile(spawnFile, "utf8").catch(() => "")) === "spawn\n" ? state : undefined;
      }, "native held bash spawn and persisted active task");
      assert.equal(held.asyncWorkSummary?.canReleaseRuntime, false);
      await projected((frame) => frame.mutations?.some((mutation) => mutation.type === "asyncTaskDetailSet"), "v2 task detail");
      await projected((frame) => frame.mutations?.some((mutation) => mutation.type === "toolUpsert" && mutation.tool?.name === "bash_async" && mutation.tool?.status === "succeeded"), "async tool returned while native job alive");
      assert.equal((await disk()).asyncTasks[0].presence, "active");
      extra.push({ phase: "async-return-before-exit", task: (await disk()).asyncTasks[0], spawnCount: 1 });
      const firstTaskId = held.asyncTasks[0].taskId;
      // An already-live process observes this file on each registration. Model
      // turns continue, but no second native job gets a durable grant.
      const rolloutScript = join(repo, "scripts/set-async-task-rollout.mjs");
      const { execFileSync } = await import("node:child_process");
      execFileSync(process.execPath, [rolloutScript, support, "drain"], { env });
      send("followUp", { sessionId, text: "BASH_AFTER" });
      await waitFor(() => frames.some((frame) => frame.type === "sessionProjectionTransaction" && frame.sessionId === sessionId && frame.mutations?.some((mutation) => mutation.type === "toolUpsert" && mutation.tool?.resultPreview?.includes("registration was not approved"))), "drained job rejected in v2 tool result");
      assert.equal(await readFile(spawnFile, "utf8"), "spawn\n", "drained registration spawned a second job");
      const during = await disk();
      assert.equal(during.asyncTasks?.[0]?.taskId, firstTaskId);
      assert.equal(during.asyncTasks?.[0]?.presence, "active");
      extra.push({ phase: "drain", task: during.asyncTasks[0], tickets: during.completionTickets ?? [], spawnCount: 1 });
      await writeFile(releaseFile, "released\n");
      const completed = await waitFor(async () => {
        const state = await disk();
        return state?.asyncTasks?.[0]?.presence === "settled" && state.completionTickets?.some((ticket) => ticket.state === "handled") ? state : undefined;
      }, "existing held work settled with handled ticket");
      assert.equal(completed.asyncTasks[0].execution, "succeeded");
      extra.push({ phase: "drained-existing", task: completed.asyncTasks[0], tickets: completed.completionTickets });
      execFileSync(process.execPath, [rolloutScript, support, "on"], { env });
      send("followUp", { sessionId, text: "BASH_AFTER" });
      await waitFor(async () => (await readFile(spawnFile, "utf8").catch(() => "")).split("spawn\n").length - 1 === 2, "reopened second native bash spawn");
      await waitFor(async () => (await disk())?.completionTickets?.length >= 2 && (await disk())?.completionTickets?.every((ticket) => ticket.state === "handled"), "reopened job tickets handled");
      assert.equal((await readFile(spawnFile, "utf8")).split("spawn\n").length - 1, 2);
    } else {
      send("followUp", { sessionId, text: "SUBAGENT" });
      const child = await waitFor(() => childSockets[0], "finite native child socket");
      const started = await waitFor(async () => {
        const state = await disk();
        return state?.asyncTasks?.[0]?.presence === "active" ? state : undefined;
      }, "active subagent before child result");
      assert.equal(started.asyncWorkSummary?.canReleaseRuntime, false);
      await projected((frame) => frame.mutations?.some((mutation) => mutation.type === "toolUpsert" && mutation.tool?.name === "subagent" && mutation.tool?.status === "succeeded"), "subagent tool returned before child exit");
      assert.equal((await disk()).asyncTasks[0].presence, "active");
      extra.push({ phase: "async-return-before-exit", task: (await disk()).asyncTasks[0] });
      child.write("result\n");
      const retained = await waitFor(async () => {
        const state = await disk();
        return state?.completionTickets?.[0]?.state === "handled" && state.asyncWorkSummary?.activeRootCount === 1 ? state : undefined;
      }, "handled subagent result before native child exit");
      assert.equal(retained.asyncWorkSummary.canReleaseRuntime, false);
      extra.push({ phase: "handled-before-child-exit", task: retained.asyncTasks[0], tickets: retained.completionTickets, status: retained.status });
      child.end("exit\n");
      await waitFor(async () => (await disk())?.asyncTasks?.[0]?.presence === "settled" && (await disk())?.asyncWorkSummary?.canReleaseRuntime === true, "native child exit and quiescence");
      assert.equal(await readFile(spawnFile, "utf8"), "spawn\n");
    }
    const final = await disk();
    await projected((frame) => frame.revision === final.revision, "final saved revision v2 frame");
    assert.equal(final.asyncWorkSummary?.tracking, "ready");
    assert.equal(final.asyncWorkSummary?.canReleaseRuntime, true);
    assert.ok(frames.some((frame) => frame.type === "sessionProjectionTransaction" && frame.mutations?.some((mutation) => mutation.type === "asyncTaskDetailSet")));
    assert.ok(frames.some((frame) => frame.type === "sessionProjectionTransaction" && frame.mutations?.some((mutation) => mutation.type === "metaPatch" && mutation.patch?.status === "completed")));
    assert.equal(final.status, "completed");
    assert.equal(await readFile(reservedLeak, "utf8").catch(() => ""), "", "mixed extension intercepted an actual provider frame");
    const ticketStates = frames.filter((frame) => frame.type === "sessionProjectionTransaction").flatMap((frame) => frame.mutations ?? []).filter((mutation) => mutation.type === "asyncTaskDetailSet").flatMap((mutation) => mutation.detail?.tickets?.map((ticket) => ticket.state) ?? []);
    for (const state of ["pending", "processing", "handled"]) assert.ok(ticketStates.includes(state), `missing ${state} in v2 ${name} ticket lifetime`);
    const transcript = await readFile(final.piSessionFilePath, "utf8");
    assert.ok(transcript.includes(name === "bash" ? "W8_HELD_RESULT" : "W8_NATIVE_RESULT"), "real result missing from saved Pi session");
    const summary = { scenario: name, packagedRuntime: runtime, sdk: (await readFile(join(runtime, "node_modules/@earendil-works/pi-coding-agent/package.json"), "utf8")).match(/"version":\s*"([^"]+)"/)?.[1], providerFiles: Object.fromEntries(Object.entries(lock.packages).map(([id, pkg]) => [id, { version: pkg.version, entrySha256: pkg.files["index.ts"] }])), mixedExtension: { reservedFrames: 0, ordinaryEvent: true, unrelatedTool: await readFile(unrelatedTool, "utf8") }, coverage: { tracking: coverage.tracking, expectedProviders: coverage.expectedProviders, readyProviders: coverage.readyProviders }, support, sessionId, nativeSpawnCount: (await readFile(spawnFile, "utf8")).trim().split("\n").length, ticketStates: [...new Set(ticketStates)], wire: { bootstrap: frames.filter((frame) => frame.type === "sessionProjectionBootstrapComplete").length, snapshots: frames.filter((frame) => frame.type === "sessionProjectionSnapshot").length, transactions: frames.filter((frame) => frame.type === "sessionProjectionTransaction").length, lastRevision: final.revision }, extra, final: { status: final.status, tracking: final.asyncWorkSummary.tracking, canReleaseRuntime: final.asyncWorkSummary.canReleaseRuntime, tasks: final.asyncTasks, tickets: final.completionTickets, finalAnswer: final.finalAnswer } };
    await writeFile(join(evidence, `compiled-${name}-wire.json`), JSON.stringify(frames, null, 2));
    await writeFile(join(evidence, `compiled-${name}-disk.json`), JSON.stringify(final, null, 2));
    await writeFile(join(evidence, `compiled-${name}-summary.json`), JSON.stringify(summary, null, 2));
    console.log(JSON.stringify(summary));
  } catch (error) {
    console.error(`PACKAGED ${name} FAILED:`, error);
    console.error(`daemon stdout: ${stdout.join("")}`);
    console.error(`daemon stderr: ${stderr.join("")}`);
    await writeFile(join(evidence, `compiled-${name}-failure.json`), JSON.stringify({ error: String(error), stdout, stderr, frames, disk: await readFile(join(support, "sessions", sessionId, `${sessionId}.json`), "utf8").catch(() => null) }, null, 2));
    throw error;
  } finally {
    await writeFile(releaseFile, "cleanup\n").catch(() => {});
    for (const socket of childSockets) { if (!socket.destroyed && !socket.writableEnded) socket.end("exit\n"); }
    if (ws && ws.readyState === WebSocket.OPEN) ws.close();
    if (daemon && daemon.exitCode === null) {
      daemon.kill("SIGTERM");
      await Promise.race([once(daemon, "exit"), new Promise((done) => setTimeout(() => { daemon.kill("SIGKILL"); done(); }, 5000))]);
    }
    for (const socket of childSockets) socket.destroy();
    if (childServer) await new Promise((done) => childServer.close(done));
    await rm(root, { recursive: true, force: true });
  }
}

assert.equal(protocol.PROTOCOL_VERSION, "2026-08-25");
assert.deepEqual(Object.keys(lock.packages).sort(), ["bash-async", "subagent"]);
for (const name of ["bash", "subagent"]) await scenario(name);
console.log("Compiled production bootstrap, v2 socket, actual packed providers, drain/on: PASS");
