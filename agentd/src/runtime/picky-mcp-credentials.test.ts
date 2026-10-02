import { createHash } from "node:crypto";
import { createServer, type Server } from "node:http";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import lockfile from "proper-lockfile";
import { afterEach, expect, it, vi } from "vitest";
import { McpServerAdmin } from "./mcp-server-admin.js";
import { createPickyMcpCredentials } from "./picky-mcp-credentials.js";
import { loadPiMcpInternals } from "./picky-mcp.js";
import { PiSdkRuntime } from "./pi-sdk-runtime.js";

const URL_A = "https://mcp.example.com/mcp";
const roots: string[] = [];
const servers: Server[] = [];

afterEach(async () => {
  vi.unstubAllEnvs();
  await Promise.all(servers.splice(0).map((server) => new Promise((resolve) => server.close(resolve))));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function tempAgentDir() {
  const root = await mkdtemp(join(tmpdir(), "picky-mcp-auth-")); roots.push(root);
  const home = join(root, "home");
  const agentDir = join(home, ".pi/agent");
  await mkdir(agentDir, { recursive: true });
  vi.stubEnv("HOME", home); vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
  return { root, agentDir };
}

const state = (url: string, token: string) => ({ serverUrl: String(new URL(url)), tokens: { access_token: token, token_type: "Bearer" } });
/** Pi before 1.0 keys an entry by URL; Pi 1.0 by `mcp__<server>|<url>`. */
const legacyKey = (url: string) => String(new URL(url));
const perServerKey = (name: string, url: string) => `mcp__${name}|${legacyKey(url)}`;

async function writeAuth(agentDir: string, states: Record<string, unknown>) {
  await writeFile(join(agentDir, "mcp-auth.json"), JSON.stringify(states));
}
async function readAuth(agentDir: string): Promise<Record<string, unknown>> {
  return JSON.parse(await readFile(join(agentDir, "mcp-auth.json"), "utf8")) as Record<string, unknown>;
}

it("keeps an older Pi CLI's sign-in in place when Picky uses it", async () => {
  const { agentDir } = await tempAgentDir();
  await writeAuth(agentDir, { [legacyKey(URL_A)]: state(URL_A, "old-cli") });
  const credentials = createPickyMcpCredentials(agentDir, await loadPiMcpInternals());

  expect(await credentials.forServer("docs", URL_A).load()).toEqual(state(URL_A, "old-cli"));
  expect(await readAuth(agentDir)).toEqual({ [legacyKey(URL_A)]: state(URL_A, "old-cli") });
});

it("saves refreshed tokens where an older Pi CLI reads them", async () => {
  const { agentDir } = await tempAgentDir();
  await writeAuth(agentDir, { [legacyKey(URL_A)]: state(URL_A, "old-cli") });
  const credentials = createPickyMcpCredentials(agentDir, await loadPiMcpInternals());

  await credentials.forServer("docs", URL_A).save(state(URL_A, "refreshed"));

  expect(await readAuth(agentDir)).toEqual({ [legacyKey(URL_A)]: state(URL_A, "refreshed") });
});

it("stores a fresh sign-in where an older Pi CLI reads it", async () => {
  const { agentDir } = await tempAgentDir();
  const credentials = createPickyMcpCredentials(agentDir, await loadPiMcpInternals());

  await credentials.forServer("docs", URL_A).save(state(URL_A, "fresh"));

  expect(await readAuth(agentDir)).toEqual({ [legacyKey(URL_A)]: state(URL_A, "fresh") });
});

it("uses the per-server entry once Pi 1.0 has taken the sign-in over", async () => {
  const { agentDir } = await tempAgentDir();
  await writeAuth(agentDir, { [perServerKey("docs", URL_A)]: state(URL_A, "pi-1") });
  const credentials = createPickyMcpCredentials(agentDir, await loadPiMcpInternals());
  const store = credentials.forServer("docs", URL_A);

  expect(await store.load()).toEqual(state(URL_A, "pi-1"));
  await store.save(state(URL_A, "refreshed"));

  expect(await readAuth(agentDir)).toEqual({ [perServerKey("docs", URL_A)]: state(URL_A, "refreshed") });
});

it("keeps separate accounts for servers that share a URL under Pi 1.0", async () => {
  const { agentDir } = await tempAgentDir();
  await writeAuth(agentDir, { [perServerKey("work", URL_A)]: state(URL_A, "work") });
  const credentials = createPickyMcpCredentials(agentDir, await loadPiMcpInternals());
  const personal = credentials.forServer("personal", URL_A);

  expect(await personal.load()).toBeUndefined();
  await personal.save(state(URL_A, "personal"));

  expect(await readAuth(agentDir)).toEqual({
    [perServerKey("work", URL_A)]: state(URL_A, "work"),
    [perServerKey("personal", URL_A)]: state(URL_A, "personal"),
  });
});

it("refreshes into the older Pi CLI's entry even when another server has a Pi 1.0 entry", async () => {
  const { agentDir } = await tempAgentDir();
  await writeAuth(agentDir, { [legacyKey(URL_A)]: state(URL_A, "old-cli"), [perServerKey("work", URL_A)]: state(URL_A, "work") });
  const credentials = createPickyMcpCredentials(agentDir, await loadPiMcpInternals());
  const docs = credentials.forServer("docs", URL_A);

  expect(await docs.load()).toEqual(state(URL_A, "old-cli"));
  await docs.save(state(URL_A, "rotated"));

  expect(await readAuth(agentDir)).toEqual({
    [legacyKey(URL_A)]: state(URL_A, "rotated"),
    [perServerKey("work", URL_A)]: state(URL_A, "work"),
  });
});

it("signs out of the entries of both Pi versions", async () => {
  const { agentDir } = await tempAgentDir();
  await writeAuth(agentDir, { [legacyKey(URL_A)]: state(URL_A, "old-cli"), [perServerKey("docs", URL_A)]: state(URL_A, "pi-1") });
  const credentials = createPickyMcpCredentials(agentDir, await loadPiMcpInternals());

  expect(credentials.remove("docs", URL_A)).toBe(true);
  expect(await readAuth(agentDir)).toEqual({});
  expect(credentials.remove("docs", URL_A)).toBe(false);
});

it("waits for an older Pi CLI that is refreshing the same server", async () => {
  const { agentDir } = await tempAgentDir();
  const credentials = createPickyMcpCredentials(agentDir, await loadPiMcpInternals());
  // Pi before 1.0 names the refresh lock after the URL key.
  const hash = createHash("sha256").update(legacyKey(URL_A)).digest("hex").slice(0, 16);
  const release = await lockfile.lock(join(agentDir, `mcp-auth-refresh-${hash}`), { realpath: false });
  let ran = false;

  const refresh = credentials.forServer("docs", URL_A).withRefreshLock(async () => { ran = true; });
  await new Promise((resolve) => setTimeout(resolve, 300));
  expect(ran).toBe(false);
  await release();
  await refresh;

  expect(ran).toBe(true);
});

it("signs out from the Hub without leaving an older Pi CLI's entry behind", async () => {
  const { agentDir } = await tempAgentDir();
  await writeFile(join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: { docs: { url: URL_A } } }));
  await writeAuth(agentDir, { [legacyKey(URL_A)]: state(URL_A, "old-cli"), [perServerKey("docs", URL_A)]: state(URL_A, "pi-1") });

  await new McpServerAdmin({ getAgentDir: () => agentDir }).signOut("docs");

  expect(await readAuth(agentDir)).toEqual({});
});

it("connects a Picky session with an older Pi CLI's sign-in and leaves it in place", async () => {
  const { root, agentDir } = await tempAgentDir();
  const authorizations: (string | undefined)[] = [];
  const server = createServer((request, response) => {
    authorizations.push(request.headers.authorization);
    response.writeHead(500).end();
  });
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("no server port");
  const url = `http://127.0.0.1:${address.port}/mcp`;
  await writeFile(join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: { docs: { url } } }));
  await writeAuth(agentDir, { [legacyKey(url)]: state(url, "old-cli") });

  const runtime = new PiSdkRuntime({ agentDir, mcpTarget: "main" });
  const handle = await runtime.prewarm({ cwd: root, sessionId: "mcp-legacy-auth" });
  try {
    await vi.waitFor(() => expect(authorizations).toContain("Bearer old-cli"), { timeout: 15_000 });
  } finally {
    await handle.dispose?.();
  }

  expect(await readAuth(agentDir)).toEqual({ [legacyKey(url)]: state(url, "old-cli") });
});
