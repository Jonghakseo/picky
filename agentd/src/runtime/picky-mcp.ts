/**
 * Pi's first-party MCP support, wired into Picky's SDK runtimes.
 *
 * SDK sessions do not load Pi's built-in extensions, so Picky adds the MCP, codemode, and
 * tool_search extensions itself. Servers come from Pi's own `mcp.json` (global, or a trusted
 * project), so a server configured for Pi works in Picky too.
 *
 * Picky adds one key of its own to a server entry: `"pickyScope": "main"` limits the server to
 * the main Picky agent. Without it, the main agent and every Pickle connect to the server. Pi
 * validates server entries without rejecting unknown keys and keeps them when it edits the file.
 *
 * The config helpers and `pi mcp` command runner are not exported from the package root, so they
 * are loaded from the SDK's dist next to its entry point. `picky-mcp.test.ts` fails when an SDK
 * update moves them.
 */
import { existsSync, realpathSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  createCodemodeExtension,
  createMcpExtension,
  createToolSearchExtension,
  type ExtensionContext,
  type InlineExtension,
  type LoadedMcpConfig,
  type McpServerConfig,
} from "@earendil-works/pi-coding-agent";
import { createPickyMcpCredentials, type PickyMcpCredentials } from "./picky-mcp-credentials.js";

export const PICKY_MCP_SCOPE_KEY = "pickyScope";
/** `all`: the main agent and every Pickle. `main`: the main Picky agent only. */
export type PickyMcpScope = "all" | "main";
export type PickyMcpRuntimeTarget = "main" | "pickle";

export function pickyMcpScope(config: unknown): PickyMcpScope {
  return typeof config === "object" && config !== null && (config as Record<string, unknown>)[PICKY_MCP_SCOPE_KEY] === "main" ? "main" : "all";
}

/** Drops servers the target runtime must not connect to. The main agent keeps every server. */
export function filterMcpConfigForTarget(loaded: LoadedMcpConfig, target: PickyMcpRuntimeTarget): LoadedMcpConfig {
  if (target === "main") return loaded;
  return { ...loaded, servers: loaded.servers.filter((server) => pickyMcpScope(server.config) === "all") };
}

export interface PiMcpInternals {
  loadMcpConfig(options: { agentDir: string; cwd: string; projectTrusted: boolean }): LoadedMcpConfig;
  addMcpServerConfig(path: string, name: string, config: McpServerConfig): boolean;
  removeMcpServerConfig(path: string, name: string): boolean;
  updateMcpServerConfig(path: string, name: string, patch: { enabled?: boolean }): void;
  /** Returns the server config, or an error message. */
  validateMcpServerConfig(name: string, value: unknown): McpServerConfig | string;
  /** `mcp__<server>` with `-` replaced by `_`, as in tool names and `mcp-auth.json` keys. */
  mcpNamespace(server: string): string;
  /** The locked JSON file backend of `auth.json` and `mcp-auth.json`. */
  FileAuthStorageBackend: new (path: string) => FileAuthStorageBackend;
  // `credentials` is required: Pi 1.0's default store migrates URL keys and would sign an older CLI out.
  runMcpCommand(args: string[], options: { cwd: string; agentDir: string; credentials: PickyMcpCredentials; log?: (line: string) => void; error?: (line: string) => void }): Promise<number>;
}

export interface FileAuthStorageBackend {
  withLock<T>(fn: (current: string | undefined) => { result: T; next?: string }): T;
}

let internals: Promise<PiMcpInternals> | undefined;

export function loadPiMcpInternals(): Promise<PiMcpInternals> {
  internals ??= (async () => {
    const dist = piCodingAgentDist();
    const load = async (path: string) => await import(pathToFileURL(join(dist, path)).href) as Record<string, unknown>;
    const [config, servers, cli, auth] = await Promise.all([
      load("./extensions/mcp/config.js"),
      load("./core/mcp-servers.js"),
      load("./extensions/mcp/cli.js"),
      load("./core/auth-storage.js"),
    ]);
    const loaded: Record<keyof PiMcpInternals, unknown> = {
      loadMcpConfig: config.loadMcpConfig,
      addMcpServerConfig: config.addMcpServerConfig,
      removeMcpServerConfig: config.removeMcpServerConfig,
      updateMcpServerConfig: config.updateMcpServerConfig,
      validateMcpServerConfig: servers.validateMcpServerConfig,
      mcpNamespace: servers.mcpNamespace,
      FileAuthStorageBackend: auth.FileAuthStorageBackend,
      runMcpCommand: cli.runMcpCommand,
    };
    const missing = Object.entries(loaded).filter(([, value]) => typeof value !== "function").map(([name]) => name);
    if (missing.length > 0) throw new Error(`Pi SDK MCP internals moved: ${missing.join(", ")}`);
    // Every member is a function (checked above); their signatures are Pi internals that only
    // the TypeScript declarations above describe.
    return loaded as PiMcpInternals;
  })();
  internals.catch(() => { internals = undefined; });
  return internals;
}

/** The package's `exports` hide its dist files, so look the package up where Node would. */
function piCodingAgentDist(): string {
  const name = "@earendil-works/pi-coding-agent";
  for (const dir of createRequire(import.meta.url).resolve.paths(name) ?? []) {
    const root = join(dir, name);
    if (existsSync(join(root, "package.json"))) return join(realpathSync(root), "dist");
  }
  throw new Error(`Cannot find ${name}`);
}

export function globalMcpConfigPath(agentDir: string): string {
  return join(agentDir, "mcp.json");
}

/**
 * The extensions the Pi CLI loads as built-ins for MCP. They are replaceable like the CLI's, so a
 * user extension that registers `/mcp` (for example `pi-mcp-adapter`) takes over instead of
 * conflicting. `codemode` and `tool_search` stay inactive until an MCP server needs them.
 */
export async function pickyMcpExtensions(target: PickyMcpRuntimeTarget, agentDir: string): Promise<InlineExtension[]> {
  const internals = await loadPiMcpInternals();
  const { loadMcpConfig } = internals;
  const credentials = createPickyMcpCredentials(agentDir, internals);
  const loadConfig = (ctx: ExtensionContext): LoadedMcpConfig => filterMcpConfigForTarget(
    loadMcpConfig({ agentDir, cwd: ctx.cwd, projectTrusted: ctx.isProjectTrusted() }),
    target,
  );
  return [
    { name: "codemode", factory: createCodemodeExtension(), replaceable: true, hidden: true },
    { name: "tool-search", factory: createToolSearchExtension(), replaceable: true, hidden: true },
    { name: "mcp", factory: createMcpExtension({ loadConfig, credentials }), replaceable: true, hidden: true },
  ];
}
