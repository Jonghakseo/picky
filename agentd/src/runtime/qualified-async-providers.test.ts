import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createAgentSessionFromServices, createAgentSessionServices, SettingsManager, type AgentSession, type EventBus, type ResourceLoader } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, it, vi } from "vitest";
import { asyncProviderLoaderOptions, qualifyAsyncProviders, type AsyncProviderLock } from "./qualified-async-providers.js";
import { PiSdkRuntime } from "./pi-sdk-runtime.js";

const roots: string[] = [];
afterEach(async () => {
  delete (globalThis as typeof globalThis & { __pickyMixedLegacyEvents?: number }).__pickyMixedLegacyEvents;
  delete (globalThis as typeof globalThis & { __pickyOwnedAPI?: unknown }).__pickyOwnedAPI;
  delete (globalThis as typeof globalThis & { __pickyOrdinaryEvents?: number }).__pickyOrdinaryEvents;
  vi.unstubAllEnvs();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function capsule() {
  const root = await mkdtemp(join(tmpdir(), "picky-qualified-async-")); roots.push(root);
  const home = join(root, "home");
  const agentDir = join(home, ".pi/agent");
  await mkdir(join(agentDir, "extensions"), { recursive: true });
  vi.stubEnv("HOME", home); vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
  const packageRoot = join(root, "async-task-providers");
  const lock: AsyncProviderLock = { packages: {
    "bash-async": { name: "@ryan_nookpi/pi-extension-bash-async", version: "0.2.1", files: {} },
    subagent: { name: "@ryan_nookpi/pi-extension-subagent", version: "0.5.7", files: {} },
  } };
  for (const [name, metadata] of Object.entries(lock.packages)) {
    const dir = join(packageRoot, "packages", name);
    await mkdir(dir, { recursive: true });
    const tool = name === "bash-async" ? "bash_async" : "subagent";
    await writeFile(join(dir, "index.ts"), `export default function (pi) { if (${JSON.stringify(name)} === 'bash-async') globalThis.__pickyOwnedAPI = pi; pi.registerTool({name:${JSON.stringify(tool)},label:'Owned',description:'Owned',parameters:{type:'object',properties:{}},execute:async()=>({content:[{type:'text',text:'owned'}]})}); }`);
    await writeFile(join(dir, "package.json"), JSON.stringify({ name: metadata.name, version: metadata.version, type: "module", pi: { extensions: ["./index.ts"] } }));
    for (const file of ["index.ts", "package.json"]) metadata.files[file] = createHash("sha256").update(await readFile(join(dir, file))).digest("hex");
  }
  // External dependency boundary; no user home or developer checkout is consulted.
  for (const module of ["yaml", "@anthropic-ai/claude-agent-sdk"]) {
    const dir = join(packageRoot, "node_modules", module);
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "package.json"), JSON.stringify({ name: module, main: "index.js" }));
    await writeFile(join(dir, "index.js"), "module.exports = {};");
  }
  const lockPath = join(root, "lock.json");
  await writeFile(lockPath, JSON.stringify(lock));
  return { root, agentDir, packageRoot, lockPath, lock };
}

it("qualifies only matching file bytes, identity, and resolvable dependencies", async () => {
  const f = await capsule();
  expect(qualifyAsyncProviders(f.packageRoot, f.lockPath)?.paths).toHaveLength(2);
  await writeFile(join(f.packageRoot, "packages", "subagent", "index.ts"), "tampered");
  expect(qualifyAsyncProviders(f.packageRoot, f.lockPath)).toBeUndefined();
  await symlink(join(f.root, "outside"), join(f.packageRoot, "packages", "bash-async", "extra.ts"));
  expect(qualifyAsyncProviders(f.packageRoot, f.lockPath)).toBeUndefined();
});

it("isolates a mixed extension's reserved channel while preserving its tool and ordinary events across reload", async () => {
  const f = await capsule();
  const mixed = join(f.agentDir, "extensions", "mixed.ts");
  await writeFile(mixed, `export default function(pi) {
    pi.events.on('pi.async-tasks.v1', () => { globalThis.__pickyMixedLegacyEvents = (globalThis.__pickyMixedLegacyEvents ?? 0) + 1; });
    pi.events.on('ordinary.channel', () => { globalThis.__pickyOrdinaryEvents = (globalThis.__pickyOrdinaryEvents ?? 0) + 1; pi.setSessionName('mixed-bound'); });
    for (const name of ['bash_async','subagent','other_tool','excluded_by_caller']) pi.registerTool({name,label:'Global',description:'Global',parameters:{type:'object',properties:{}},execute:async()=>({content:[{type:'text',text:'global'}]})});
  }`);
  for (const name of ["bash-async", "subagent"]) {
    const dir = join(f.agentDir, "extensions", name);
    await mkdir(dir);
    await writeFile(join(dir, "package.json"), JSON.stringify({ name: `@ryan_nookpi/pi-extension-${name}`, pi: { extensions: ["./index.ts"] } }));
    await writeFile(join(dir, "index.ts"), `export default function(pi) { globalThis.__pickyLegacyProviderLoaded = true; pi.events.on('pi.async-tasks.v1', () => { throw new Error('Legacy provider was loaded'); }); pi.registerTool({name:${JSON.stringify(name === "bash-async" ? "bash_async" : "subagent")},label:'Legacy',description:'Legacy',parameters:{type:'object',properties:{}},execute:async()=>({content:[]})}); }`);
  }
  const qualified = qualifyAsyncProviders(f.packageRoot, f.lockPath)!;
  let session!: AgentSession;
  let loader!: ResourceLoader;
  let bus!: EventBus;
  const runtime = new PiSdkRuntime({ agentDir: f.agentDir, asyncProviderPaths: qualified.paths,
    resourceLoaderOptions: {
      extensionFactories: [pi => pi.registerTool({ name: "inline_tool", label: "Inline", description: "Inline", parameters: { type: "object", properties: {} }, execute: async () => ({ content: [], details: undefined }) })],
      extensionsOverride: base => ({ ...base, extensions: base.extensions.map(extension => ({ ...extension,
        tools: new Map([...extension.tools].filter(([name]) => name !== "excluded_by_caller")),
      })) }),
    },
    createServices: options => { if (options.modelRuntime) bus = options.resourceLoaderOptions!.eventBus as typeof bus; return createAgentSessionServices(options); },
    createSessionFromServices: async options => { loader = options.services.resourceLoader; const result = await createAgentSessionFromServices(options); session = result.session; return result; },
  });
  const handle = await runtime.prewarm({ cwd: f.root, sessionId: "mixed" });
  try {
    const tools = () => session.getAllTools().map(tool => tool.name);
    expect((globalThis as typeof globalThis & { __pickyLegacyProviderLoaded?: boolean }).__pickyLegacyProviderLoaded).toBeUndefined();
    expect(tools()).toEqual(expect.arrayContaining(["bash_async", "subagent", "other_tool", "inline_tool"]));
    expect(tools()).not.toContain("excluded_by_caller");
    expect(tools().filter(name => name === "bash_async")).toHaveLength(1);
    const tool = (name: string) => loader.getExtensions().extensions.find(extension => extension.tools.has(name))!.tools.get(name)!.definition;
    expect((await tool("bash_async").execute("owned", {}, undefined, undefined, undefined as never)).content).toEqual([{ type: "text", text: "owned" }]);
    expect((await tool("other_tool").execute("ordinary", {}, undefined, undefined, undefined as never)).content).toEqual([{ type: "text", text: "global" }]);
    const prior = (globalThis as typeof globalThis & { __pickyOwnedAPI: { getAllTools(): unknown } }).__pickyOwnedAPI;
    expect(prior.getAllTools()).toEqual(expect.arrayContaining([expect.objectContaining({ name: "other_tool" })]));
    bus.emit("pi.async-tasks.v1", { type: "host-ready" });
    bus.emit("ordinary.channel", {});
    await vi.waitFor(() => expect(session.sessionManager.getSessionName()).toBe("mixed-bound"));
    expect((globalThis as typeof globalThis & { __pickyOrdinaryEvents?: number }).__pickyOrdinaryEvents).toBe(1);
    expect((globalThis as typeof globalThis & { __pickyMixedLegacyEvents?: number }).__pickyMixedLegacyEvents).toBeUndefined();
    const events: unknown[] = [];
    const unsubscribe = handle.subscribe(event => events.push(event));
    await handle.followUp({ text: "/reload", imagePaths: [] });
    expect(events).toContainEqual({ type: "log", line: "pi resources reloaded" });
    unsubscribe();
    expect(tools()).toEqual(expect.arrayContaining(["bash_async", "subagent", "other_tool", "inline_tool"]));
    expect(tools()).not.toContain("excluded_by_caller");
    expect(() => prior.getAllTools()).toThrow(/stale/);
    expect((globalThis as typeof globalThis & { __pickyOwnedAPI: { getAllTools(): unknown } }).__pickyOwnedAPI.getAllTools()).toEqual(expect.arrayContaining([expect.objectContaining({ name: "other_tool" })]));
    session.setSessionName("before-reload-event");
    bus.emit("pi.async-tasks.v1", { type: "host-ready" });
    bus.emit("ordinary.channel", {});
    await vi.waitFor(() => expect(session.sessionManager.getSessionName()).toBe("mixed-bound"));
    expect((globalThis as typeof globalThis & { __pickyOrdinaryEvents?: number }).__pickyOrdinaryEvents).toBe(2);
    expect((globalThis as typeof globalThis & { __pickyMixedLegacyEvents?: number }).__pickyMixedLegacyEvents).toBeUndefined();
  } finally { await handle.dispose?.(); }
  bus.emit("ordinary.channel", {});
  await new Promise(resolve => setTimeout(resolve, 0));
  expect((globalThis as typeof globalThis & { __pickyOrdinaryEvents?: number }).__pickyOrdinaryEvents).toBe(2);
}, 20000);

it("rejects a known legacy provider directory beneath an unrelated monorepo manifest", async () => {
  const f = await capsule();
  const dir = join(f.agentDir, "extensions/bash-async");
  await mkdir(dir);
  await writeFile(join(f.agentDir, "extensions/package.json"), JSON.stringify({ name: "unrelated-monorepo" }));
  await writeFile(join(dir, "index.ts"), "export default pi => pi.registerTool({name:'bash_async',label:'Legacy',description:'Legacy',parameters:{type:'object',properties:{}},execute:async()=>({content:[]})});");
  const options = await asyncProviderLoaderOptions([], f.root, f.agentDir, SettingsManager.inMemory({ packages: [] }));
  expect(options.additionalExtensionPaths).not.toContain(join(dir, "index.ts"));
});

it("refuses an unqualified legacy async tool on the real SDK session without dropping unrelated tools", async () => {
  const f = await capsule();
  const legacy = join(f.agentDir, "extensions", "legacy.ts");
  const sentinel = join(f.root, "legacy-launched");
  await writeFile(legacy, `export default function(pi) { for (const name of ['bash_async', 'other_tool']) pi.registerTool({ name, label: name, description: name, parameters: { type:'object', properties:{} }, execute: async () => { if (name === 'bash_async') require('node:fs').writeFileSync(${JSON.stringify(sentinel)}, 'launched'); return {content:[{type:'text',text:name}]}; } }); }`);
  let session!: AgentSession;
  const runtime = new PiSdkRuntime({ agentDir: f.agentDir, asyncProviderPaths: [], asyncProvidersQualified: false,
    createSessionFromServices: async options => { const result = await createAgentSessionFromServices(options); session = result.session; return result; },
  });
  const handle = await runtime.prewarm({ cwd: f.root, sessionId: "unqualified" });
  try {
    const names = session.getAllTools().map(tool => tool.name);
    expect(names).toContain("other_tool");
    expect(names).not.toContain("bash_async");
    expect(await import("node:fs").then(fs => fs.existsSync(sentinel))).toBe(false);
  } finally { await handle.dispose?.(); }
}, 15000);

it("never installs missing or version-mismatched packages on initial SDK load or reload", async () => {
  const f = await capsule();
  const bin = join(f.root, "bin"); await mkdir(bin);
  const sentinel = join(f.root, "install-attempts");
  for (const command of ["npm", "git"]) await writeFile(join(bin, command), `#!/bin/sh\nprintf '%s %s\\n' '${command}' "$*" >> ${JSON.stringify(sentinel)}\nexit 99\n`, { mode: 0o755 });
  vi.stubEnv("PATH", `${bin}:${process.env.PATH}`);
  vi.stubEnv("PI_OFFLINE", undefined);
  const installed = join(f.agentDir, "npm/node_modules/picky-w8-installed");
  await mkdir(installed, { recursive: true });
  await writeFile(join(installed, "package.json"), JSON.stringify({ name: "picky-w8-installed", version: "1.0.0", pi: { extensions: ["./index.js"] } }));
  await writeFile(join(installed, "index.js"), "export default pi => pi.registerTool({name:'installed_tool',label:'Installed',description:'Installed',parameters:{type:'object',properties:{}},execute:async()=>({content:[]})});\n");
  const stale = join(f.agentDir, "npm/node_modules/picky-w8-mismatch");
  await mkdir(stale, { recursive: true });
  await writeFile(join(stale, "package.json"), JSON.stringify({ name: "picky-w8-mismatch", version: "1.0.0", pi: { extensions: ["./index.js"] } }));
  await writeFile(join(stale, "index.js"), "export default () => { throw new Error('stale version loaded'); };\n");
  const settingsPath = join(f.agentDir, "settings.json");
  const settings = JSON.stringify({ packages: ["npm:picky-w8-installed@1.0.0", "npm:picky-w8-missing@2.0.0", "npm:picky-w8-mismatch@2.0.0", "git:https://example.invalid/w8-missing"], npmCommand: [join(bin, "npm")] });
  await writeFile(settingsPath, settings);
  let session!: AgentSession;
  const runtime = new PiSdkRuntime({ agentDir: f.agentDir, asyncProviderPaths: [],
    createSessionFromServices: async options => { const result = await createAgentSessionFromServices(options); session = result.session; return result; },
  });
  const handle = await runtime.prewarm({ cwd: f.root, sessionId: "no-install" });
  expect(session.getAllTools().map(tool => tool.name)).toContain("installed_tool");
  const events: unknown[] = [];
  const unsubscribe = handle.subscribe(event => { events.push(event); });
  try {
    await handle.followUp({ text: "/reload", imagePaths: [] });
    expect(events).toContainEqual({ type: "log", line: "pi resources reloaded" });
    expect(session.getAllTools().map(tool => tool.name)).toContain("installed_tool");
    expect(await readFile(settingsPath, "utf8")).toBe(settings);
    const invocations = await readFile(sentinel, "utf8").catch(() => "");
    expect(invocations).not.toMatch(/\b(?:install|clone|fetch|pull|ls-remote)\b/);
  } finally { unsubscribe(); await handle.dispose?.(); }
});

it("binds settings and the MCP registry for ordinary extensions on the composed Pickle loader", async () => {
  const f = await capsule();
  let api!: { getSettings(): unknown; getMcpServers(): unknown[]; registerMcpServer(name: string, config: object): void };
  const runtime = new PiSdkRuntime({ agentDir: f.agentDir, asyncProviderPaths: [], asyncProvidersQualified: false,
    resourceLoaderOptions: { extensionFactories: [pi => { api = pi as unknown as typeof api; }] },
  });
  const handle = await runtime.prewarm({ cwd: f.root, sessionId: "composed-settings" });
  try {
    // codemode reads its mode from settings whenever it builds the model's tool declarations.
    expect(() => api.getSettings()).not.toThrow();
    api.registerMcpServer("registered", { url: "https://example.com/mcp", enabled: false });
    expect(api.getMcpServers()).toEqual([expect.objectContaining({ name: "registered" })]);
  } finally { await handle.dispose?.(); }
});

it("matches a Picky prompt rewritten by a qualified provider so the echo is not a second user message", async () => {
  const f = await capsule();
  // Mirror pi-extension-subagent's `>agent` mention transform inside the owned provider.
  const subagent = f.lock.packages.subagent!;
  const subagentDir = join(f.packageRoot, "packages", "subagent");
  await writeFile(join(subagentDir, "index.ts"), `export default function (pi) {
    pi.on('input', (event) => {
      if (event.source === 'extension') return { action: 'continue' };
      const text = event.text.replace(/(^|\\s)>worker\\b/g, '$1subagent:worker');
      return text === event.text ? { action: 'continue' } : { action: 'transform', text, images: event.images };
    });
  }`);
  subagent.files["index.ts"] = createHash("sha256").update(await readFile(join(subagentDir, "index.ts"))).digest("hex");
  await writeFile(f.lockPath, JSON.stringify(f.lock));
  const qualified = qualifyAsyncProviders(f.packageRoot, f.lockPath)!;
  const runtime = new PiSdkRuntime({ agentDir: f.agentDir, asyncProviderPaths: qualified.paths });
  const handle = await runtime.prewarm({ cwd: f.root, sessionId: "owned-rewrite" });
  try {
    // No model is configured, so Pi rejects the prompt after the input transforms have run.
    await handle.followUp({ text: "delegate >worker now", imagePaths: [] }).catch(() => undefined);
    // The learned alias lets Pi's rewritten role=user echo resolve to Picky's own delivery
    // instead of surfacing as a second, extension-originated user message.
    expect(handle.reverseInputExpansion?.("delegate subagent:worker now")).toBe("delegate >worker now");
  } finally { await handle.dispose?.(); }
}, 15000);
