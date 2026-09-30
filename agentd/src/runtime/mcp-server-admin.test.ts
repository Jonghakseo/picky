import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, expect, it, vi } from "vitest";
import { McpServerAdmin } from "./mcp-server-admin.js";

const echoServer = fileURLToPath(new URL("./fixtures/mcp-echo-server.mjs", import.meta.url));
const roots: string[] = [];

afterEach(async () => {
  vi.unstubAllEnvs();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function admin() {
  const root = await mkdtemp(join(tmpdir(), "picky-mcp-admin-")); roots.push(root);
  const agentDir = join(root, "home/.pi/agent");
  await mkdir(agentDir, { recursive: true });
  vi.stubEnv("HOME", join(root, "home")); vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
  const configPath = join(agentDir, "mcp.json");
  return { admin: new McpServerAdmin({ getAgentDir: () => agentDir }), configPath };
}

const stdio = (name: string) => JSON.stringify({ command: process.execPath, args: [echoServer, name] });

it("adds servers with their Picky scope and reports their live state", async () => {
  const { admin: mcp, configPath } = await admin();
  await mcp.add("shared", stdio("shared"), "all");
  await mcp.add("picky_only", JSON.stringify({ url: "https://example.com/mcp", enabled: false }), "main");

  const file = JSON.parse(await readFile(configPath, "utf8"));
  expect(file.mcpServers.shared.pickyScope).toBeUndefined();
  expect(file.mcpServers.picky_only.pickyScope).toBe("main");

  const listing = await mcp.list();
  expect(listing.configPath).toBe(configPath);
  expect(listing.servers).toEqual([
    expect.objectContaining({ name: "shared", pickyScope: "all", enabled: true, state: "connected", tools: ["echo"], usesOAuth: false }),
    expect.objectContaining({ name: "picky_only", pickyScope: "main", enabled: false, state: "disabled", usesOAuth: true }),
  ]);
}, 20_000);

it("changes scope and enablement without dropping the entry's other settings", async () => {
  const { admin: mcp, configPath } = await admin();
  await writeFile(configPath, `{\n    "mcpServers": {\n        "docs": { "url": "https://example.com/mcp", "headers": { "Authorization": "Bearer \${DOCS}" }, "exposure": "direct" }\n    },\n    "autoEnableCodemode": false\n}\n`);

  await mcp.update("docs", { pickyScope: "main", enabled: false });
  let text = await readFile(configPath, "utf8");
  expect(JSON.parse(text)).toEqual({
    mcpServers: { docs: { url: "https://example.com/mcp", headers: { Authorization: "Bearer ${DOCS}" }, exposure: "direct", pickyScope: "main", enabled: false } },
    autoEnableCodemode: false,
  });
  expect(text).toContain('\n    "mcpServers"');

  await mcp.update("docs", { pickyScope: "all", enabled: true });
  text = await readFile(configPath, "utf8");
  expect(JSON.parse(text).mcpServers.docs).toEqual({ url: "https://example.com/mcp", headers: { Authorization: "Bearer ${DOCS}" }, exposure: "direct" });
  expect((await mcp.list()).servers[0]).toEqual(expect.objectContaining({ usesOAuth: false }));
});

it("rejects invalid, duplicate, and unknown servers without touching the file", async () => {
  const { admin: mcp, configPath } = await admin();
  await mcp.add("docs", JSON.stringify({ url: "https://example.com/mcp" }), "all");
  const before = await readFile(configPath, "utf8");

  await expect(mcp.add("bad name", stdio("x"), "all")).rejects.toMatchObject({ code: "invalid" });
  await expect(mcp.add("legacy", JSON.stringify({ type: "sse", url: "https://example.com/sse" }), "all")).rejects.toMatchObject({ code: "invalid" });
  await expect(mcp.add("broken", "{", "all")).rejects.toMatchObject({ code: "invalid" });
  await expect(mcp.add("docs", stdio("docs"), "all")).rejects.toMatchObject({ code: "duplicate" });
  await expect(mcp.update("missing", { enabled: false })).rejects.toMatchObject({ code: "notFound" });
  await expect(mcp.remove("missing")).rejects.toMatchObject({ code: "notFound" });
  expect(await readFile(configPath, "utf8")).toBe(before);

  await mcp.remove("docs");
  expect(JSON.parse(await readFile(configPath, "utf8")).mcpServers).toEqual({});
});
