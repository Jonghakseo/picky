import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createAgentSessionFromServices, type AgentSession, type ResourceLoader } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, it, vi } from "vitest";
import { PiSdkRuntime } from "./pi-sdk-runtime.js";
import { loadPiMcpInternals, type PickyMcpRuntimeTarget } from "./picky-mcp.js";

const echoServer = fileURLToPath(new URL("./fixtures/mcp-echo-server.mjs", import.meta.url));
const roots: string[] = [];

afterEach(async () => {
  vi.unstubAllEnvs();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function agentDirWithServers() {
  const root = await mkdtemp(join(tmpdir(), "picky-mcp-")); roots.push(root);
  const home = join(root, "home");
  const agentDir = join(home, ".pi/agent");
  await mkdir(agentDir, { recursive: true });
  vi.stubEnv("HOME", home); vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
  const server = (name: string) => ({ command: process.execPath, args: [echoServer, name] });
  await writeFile(join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: {
    shared: server("shared"),
    picky_only: { ...server("picky_only"), pickyScope: "main" },
  } }));
  return { root, agentDir };
}

async function connectedTools(target: PickyMcpRuntimeTarget, expected: string[]) {
  const { root, agentDir } = await agentDirWithServers();
  let session!: AgentSession;
  let loader!: ResourceLoader;
  const runtime = new PiSdkRuntime({
    agentDir, mcpTarget: target,
    // Pickles always run through the composed async-provider loader, even without providers.
    ...(target === "pickle" ? { asyncProviderPaths: [], asyncProvidersQualified: false } : {}),
    createSessionFromServices: async (options) => { loader = options.services.resourceLoader; const result = await createAgentSessionFromServices(options); session = result.session; return result; },
  });
  const handle = await runtime.prewarm({ cwd: root, sessionId: `mcp-${target}` });
  try {
    await vi.waitFor(() => expect(session.getAllTools().map((tool) => tool.name)).toEqual(expect.arrayContaining(expected)), { timeout: 15_000 });
    // Both servers start together; give an out-of-scope server the same chance to appear.
    await new Promise((resolve) => setTimeout(resolve, 300));
    const echo = loader.getExtensions().extensions.find((extension) => extension.tools.has("mcp__shared__echo"))?.tools.get("mcp__shared__echo")?.definition;
    return {
      names: session.getAllTools().map((tool) => tool.name),
      active: session.getActiveToolNames(),
      echoed: echo ? await echo.execute("call-1", {}, undefined, undefined, undefined as never) : undefined,
    };
  } finally {
    await handle.dispose?.();
  }
}

it("finds the SDK's MCP config helpers and command runner", async () => {
  const internals = await loadPiMcpInternals();
  for (const fn of Object.values(internals)) expect(fn).toBeTypeOf("function");
});

it("connects a Pickle only to servers not limited to the main Picky agent", async () => {
  const { names, active, echoed } = await connectedTools("pickle", ["mcp__shared__echo"]);
  expect(names).toContain("mcp__shared__echo");
  expect(names).not.toContain("mcp__picky_only__echo");
  // Default exposure reaches MCP tools through codemode, which the MCP extension activates.
  expect(active).toContain("codemode");
  expect(echoed?.content).toEqual([{ type: "text", text: "echo from shared" }]);
}, 30_000);

it("connects the main Picky agent to every configured server", async () => {
  const { names } = await connectedTools("main", ["mcp__shared__echo", "mcp__picky_only__echo"]);
  expect(names).toEqual(expect.arrayContaining(["mcp__shared__echo", "mcp__picky_only__echo"]));
}, 30_000);

it("picks up servers added to mcp.json after a plugin reload", async () => {
  const { root, agentDir } = await agentDirWithServers();
  let session!: AgentSession;
  const runtime = new PiSdkRuntime({
    agentDir, mcpTarget: "pickle", asyncProviderPaths: [], asyncProvidersQualified: false,
    createSessionFromServices: async (options) => { const result = await createAgentSessionFromServices(options); session = result.session; return result; },
  });
  const handle = await runtime.prewarm({ cwd: root, sessionId: "mcp-reload" });
  try {
    const names = () => session.getAllTools().map((tool) => tool.name);
    await vi.waitFor(() => expect(names()).toContain("mcp__shared__echo"), { timeout: 15_000 });
    await writeFile(join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: {
      added: { command: process.execPath, args: [echoServer, "added"] },
    } }));

    // Hub's plugin reload sends /reload to idle sessions.
    await handle.followUp({ text: "/reload", imagePaths: [] });

    await vi.waitFor(() => expect(names()).toContain("mcp__added__echo"), { timeout: 15_000 });
  } finally {
    await handle.dispose?.();
  }
}, 30_000);
