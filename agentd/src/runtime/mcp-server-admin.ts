/**
 * Manages the servers in Pi's global `mcp.json` for the Hub. Status and sign-in reuse Pi's own
 * `pi mcp list --json` and `pi mcp login` implementations, run in-process, so they stay in step
 * with how sessions connect.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { createPickyMcpCredentials } from "./picky-mcp-credentials.js";
import {
  PICKY_MCP_SCOPE_KEY,
  globalMcpConfigPath,
  loadPiMcpInternals,
  pickyMcpScope,
  type PiMcpInternals,
  type PickyMcpScope,
} from "./picky-mcp.js";

export type McpServerState = "disabled" | "connecting" | "connected" | "disconnected" | "needs-auth" | "failed" | "closed";

export interface McpServerSummary {
  name: string;
  pickyScope: PickyMcpScope;
  enabled: boolean;
  exposure: string;
  transport: string;
  state: McpServerState;
  tools: string[];
  error?: string;
  /** HTTP servers without an Authorization header sign in with OAuth. */
  usesOAuth: boolean;
}

export interface McpServerListing {
  configPath: string;
  servers: McpServerSummary[];
  configErrors: string[];
}

export type McpServerOperationErrorCode = "duplicate" | "invalid" | "notFound";

export class McpServerOperationError extends Error {
  constructor(message: string, readonly code?: McpServerOperationErrorCode) {
    super(message);
  }
}

interface ListReport {
  name: string;
  scope: string;
  enabled: boolean;
  exposure: string;
  transport: string;
  state: McpServerState;
  tools: string[];
  error?: string;
}

const SERVER_STATES = new Set<McpServerState>(["disabled", "connecting", "connected", "disconnected", "needs-auth", "failed", "closed"]);

export interface McpServerAdminOptions {
  getAgentDir?: () => string;
  loadInternals?: () => Promise<PiMcpInternals>;
}

export class McpServerAdmin {
  private readonly agentDir: () => string;
  private readonly internals: () => Promise<PiMcpInternals>;

  constructor(options: McpServerAdminOptions = {}) {
    this.agentDir = options.getAgentDir ?? getAgentDir;
    this.internals = options.loadInternals ?? loadPiMcpInternals;
  }

  get configPath(): string {
    return globalMcpConfigPath(this.agentDir());
  }

  /** Connects to every enabled global server, like `pi mcp list`, and reports its state. */
  async list(): Promise<McpServerListing> {
    const internals = await this.internals();
    const agentDir = this.agentDir();
    const credentials = createPickyMcpCredentials(agentDir, internals);
    const output: string[] = [];
    const errors: string[] = [];
    // The agent directory is never a trusted project, so only the global mcp.json is read.
    await internals.runMcpCommand(["list", "--json"], { cwd: agentDir, agentDir, credentials, log: (line) => output.push(line), error: (line) => errors.push(line) });
    let parsed: { servers?: ListReport[]; errors?: string[] };
    try {
      parsed = JSON.parse(output.join("\n")) as typeof parsed;
    } catch {
      throw new Error(errors.join("\n") || "pi mcp list returned no JSON");
    }
    const raw = this.readServers();
    const servers = (parsed.servers ?? []).filter((report) => report.scope === "global").map((report): McpServerSummary => {
      const config = raw[report.name];
      return {
        name: report.name,
        pickyScope: pickyMcpScope(config),
        enabled: report.enabled,
        exposure: report.exposure,
        transport: report.transport,
        state: SERVER_STATES.has(report.state) ? report.state : "failed",
        tools: report.tools,
        ...(report.error ? { error: report.error } : {}),
        usesOAuth: usesOAuth(config),
      };
    });
    return { configPath: this.configPath, servers, configErrors: parsed.errors ?? [] };
  }

  async add(name: string, configJson: string, pickyScope: PickyMcpScope): Promise<void> {
    const { validateMcpServerConfig, addMcpServerConfig } = await this.internals();
    let value: unknown;
    try {
      value = JSON.parse(configJson);
    } catch (error) {
      throw new McpServerOperationError(`Server config is not valid JSON: ${error instanceof Error ? error.message : String(error)}`, "invalid");
    }
    if (!isRecord(value)) throw new McpServerOperationError("Server config must be a JSON object", "invalid");
    const config: Record<string, unknown> = { ...value };
    delete config[PICKY_MCP_SCOPE_KEY];
    if (pickyScope === "main") config[PICKY_MCP_SCOPE_KEY] = "main";
    const validated = validateMcpServerConfig(name, config);
    if (typeof validated === "string") throw new McpServerOperationError(validated, "invalid");
    if (this.readServers()[name] !== undefined) throw new McpServerOperationError(`MCP server "${name}" already exists`, "duplicate");
    addMcpServerConfig(this.configPath, name, validated);
  }

  async remove(name: string): Promise<void> {
    const { removeMcpServerConfig } = await this.internals();
    if (!removeMcpServerConfig(this.configPath, name)) throw new McpServerOperationError(`No MCP server named "${name}"`, "notFound");
  }

  async update(name: string, patch: { enabled?: boolean; pickyScope?: PickyMcpScope }): Promise<void> {
    const { updateMcpServerConfig } = await this.internals();
    if (this.readServers()[name] === undefined) throw new McpServerOperationError(`No MCP server named "${name}"`, "notFound");
    if (patch.enabled !== undefined) updateMcpServerConfig(this.configPath, name, { enabled: patch.enabled });
    if (patch.pickyScope !== undefined) this.writeScope(name, patch.pickyScope);
  }

  /** Opens the authorization page in the browser and waits for the callback, like `pi mcp login`. */
  async signIn(name: string): Promise<void> {
    await this.runCommand(["login", name]);
  }

  async signOut(name: string): Promise<void> {
    await this.runCommand(["logout", name]);
  }

  private async runCommand(args: string[]): Promise<void> {
    const internals = await this.internals();
    const agentDir = this.agentDir();
    const credentials = createPickyMcpCredentials(agentDir, internals);
    const errors: string[] = [];
    const code = await internals.runMcpCommand(args, { cwd: agentDir, agentDir, credentials, log: () => {}, error: (line) => errors.push(line) });
    if (code !== 0) throw new McpServerOperationError(errors.join("\n") || `pi mcp ${args[0]} failed`);
  }

  private readServers(): Record<string, unknown> {
    const path = this.configPath;
    if (!existsSync(path)) return {};
    try {
      const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
      return isRecord(parsed) && isRecord(parsed.mcpServers) ? parsed.mcpServers : {};
    } catch {
      return {};
    }
  }

  /** Pi's config writer only knows its own keys; keep the file's other content and indentation. */
  private writeScope(name: string, scope: PickyMcpScope): void {
    const path = this.configPath;
    const text = readFileSync(path, "utf8");
    const parsed = JSON.parse(text) as { mcpServers?: Record<string, Record<string, unknown>> };
    const server = parsed.mcpServers?.[name];
    if (!isRecord(server)) throw new McpServerOperationError(`No MCP server named "${name}"`, "notFound");
    if (scope === "main") server[PICKY_MCP_SCOPE_KEY] = "main";
    else delete server[PICKY_MCP_SCOPE_KEY];
    const indent = /^([ \t]+)\S/m.exec(text)?.[1] ?? "  ";
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, `${JSON.stringify(parsed, null, indent)}\n`);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function usesOAuth(config: unknown): boolean {
  if (!isRecord(config) || typeof config.url !== "string") return false;
  const headers = isRecord(config.headers) ? Object.keys(config.headers) : [];
  return !headers.some((header) => header.toLowerCase() === "authorization");
}
