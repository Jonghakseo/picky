import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync, readdirSync } from "node:fs";
import { createRequire } from "node:module";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { CONFIG_DIR_NAME, createExtensionRuntime, DefaultPackageManager, SettingsManager, type CreateAgentSessionServicesOptions, type EventBus, type ExtensionRuntime, type ResourceLoader } from "@earendil-works/pi-coding-agent";

const providers = ["bash-async", "subagent"] as const;
const toolNames = new Set(["bash_async", "subagent", "sub", "sub:isolate"]);
const packageNames = {
  "bash-async": "@ryan_nookpi/pi-extension-bash-async",
  subagent: "@ryan_nookpi/pi-extension-subagent",
} as const;

export interface AsyncProviderLock {
  packages: Record<(typeof providers)[number], { name: string; version: string; files: Record<string, string> }>;
}

/** Both TS source and compiled dist live one directory below the agentd root. */
export const agentdRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function inventory(root: string): Record<string, string> {
  const result: Record<string, string> = {};
  const visit = (dir: string): void => {
    for (const name of readdirSync(dir).sort()) {
      const path = join(dir, name);
      const stat = lstatSync(path);
      if (stat.isDirectory()) visit(path);
      else if (stat.isFile()) result[relative(root, path).split(sep).join("/")] = createHash("sha256").update(readFileSync(path)).digest("hex");
      else throw new Error(`Async provider contains a non-regular file: ${path}`);
    }
  };
  visit(root);
  return result;
}

export function qualifyAsyncProviders(root = join(agentdRoot, "async-task-providers"), lockPath = join(agentdRoot, "async-task-providers.lock.json")): { paths: string[] } | undefined {
  if (!existsSync(root) || !existsSync(lockPath)) return undefined;
  try {
    const lock = JSON.parse(readFileSync(lockPath, "utf8")) as AsyncProviderLock;
    if (Object.keys(lock.packages).sort().join(",") !== [...providers].sort().join(",")) return undefined;
    const paths = providers.map((id) => {
      const dir = join(root, "packages", id);
      if (!lstatSync(dir).isDirectory()) throw new Error("Provider directory must be regular");
      const expected = lock.packages[id];
      const pkg = JSON.parse(readFileSync(join(dir, "package.json"), "utf8")) as { name?: string; version?: string; pi?: { extensions?: string[] } };
      if (expected.name !== packageNames[id] || pkg.name !== expected.name || pkg.version !== expected.version || JSON.stringify(pkg.pi?.extensions) !== JSON.stringify(["./index.ts"])) throw new Error("Provider package identity changed");
      const files = inventory(dir);
      if (!Object.keys(files).length || JSON.stringify(Object.entries(files).sort()) !== JSON.stringify(Object.entries(expected.files).sort())) throw new Error("Provider file integrity changed");
      const entry = join(dir, "index.ts");
      if (id === "subagent") {
        const require = createRequire(entry);
        require.resolve("yaml");
        require.resolve("@anthropic-ai/claude-agent-sdk");
      }
      return entry;
    });
    return { paths };
  } catch {
    // Missing or altered packages are never treated as qualified merely because
    // global Pi happened to register tools with matching names.
    return undefined;
  }
}

type LoaderOptions = NonNullable<CreateAgentSessionServicesOptions["resourceLoaderOptions"]>;

/** Give the SDK loader a file-backed settings view that excludes unavailable packages.
 * Its internal resolve() has no onMissing callback, including on /reload. Keep all
 * other settings live and never write the filtered package list to Pi's files.
 */
export async function noInstallProviderSettings(cwd: string, agentDir: string): Promise<{ settingsManager: SettingsManager; refresh: () => Promise<void> }> {
  const sourceKey = (source: string, scope: "global" | "project") => `${scope}\0${source}`;
  let available = new Set<string>();
  const refresh = async () => {
    const actual = SettingsManager.create(cwd, agentDir);
    const resolved = await new DefaultPackageManager({ cwd, agentDir, settingsManager: actual }).resolve(async () => "skip");
    available = new Set(Object.values(resolved).flat().filter(resource => resource.metadata.origin === "package")
      .map(resource => sourceKey(resource.metadata.source, resource.metadata.scope === "user" ? "global" : "project")));
  };
  await refresh();
  const storage = {
    withLock(scope: "global" | "project", fn: (current: string | undefined) => string | undefined): void {
      const path = scope === "global" ? join(agentDir, "settings.json") : join(cwd, CONFIG_DIR_NAME, "settings.json");
      const current = existsSync(path) ? readFileSync(path, "utf8") : undefined;
      const parsed = current ? JSON.parse(current) as { packages?: Array<string | { source: string }> } : undefined;
      const filtered = parsed && { ...parsed, packages: parsed.packages?.filter(pkg => available.has(sourceKey(typeof pkg === "string" ? pkg : pkg.source, scope))) };
      if (fn(filtered && JSON.stringify(filtered)) !== undefined) throw new Error("Read-only async provider resource settings");
    },
  };
  return { settingsManager: SettingsManager.fromStorage(storage), refresh };
}


/** Preserve unrelated extensions, including mixed extensions with non-provider tools. */
function isLegacyProvider(path: string): boolean {
  let dir = dirname(path);
  for (let depth = 0; depth < 5; depth++, dir = dirname(dir)) {
    const manifest = join(dir, "package.json");
    if (existsSync(manifest)) {
      try {
        const name = (JSON.parse(readFileSync(manifest, "utf8")) as { name?: string }).name;
        if (name === packageNames["bash-async"] || name === packageNames.subagent) return true;
        break;
      } catch { break; }
    }
    if (dir === dirname(dir)) break;
  }
  return ["bash-async", "subagent", "bash_async"].includes(basename(dirname(path))) || ["bash-async.ts", "subagent.ts", "bash_async.ts"].includes(basename(path));
}

/** Resolve already installed extensions without installing or editing user Pi packages. */
export async function asyncProviderLoaderOptions(paths: string[], cwd: string, agentDir: string, settingsManager: SettingsManager, additionalPaths: string[] = []): Promise<Pick<LoaderOptions, "additionalExtensionPaths" | "noExtensions" | "extensionsOverride">> {
  const manager = new DefaultPackageManager({ cwd, agentDir, settingsManager });
  const available = await manager.resolve(async () => "skip");
  const metadata = new Map(available.extensions.filter((resource) => resource.enabled && !isLegacyProvider(resource.path))
    .map(({ path, metadata }) => [resolve(path), metadata] as const));
  // Temporary npm/git sources would invoke resolveExtensionSources() without
  // an onMissing callback. Only pass already-present local extension paths.
  const localPaths = additionalPaths.filter(path => (isAbsolute(path) || path.startsWith("./") || path.startsWith("../"))
    && existsSync(resolve(cwd, path)) && !isLegacyProvider(path));
  const extensionPaths = [...new Set([...metadata.keys(), ...localPaths])];
  return {
    noExtensions: true,
    additionalExtensionPaths: extensionPaths,
    extensionsOverride: (base) => ({
      ...base,
      extensions: base.extensions.flatMap((extension) => {
        const source = metadata.get(resolve(extension.resolvedPath));
        if (source) {
          extension.sourceInfo = { path: extension.path, ...source };
          for (const tool of extension.tools.values()) tool.sourceInfo = extension.sourceInfo;
          for (const command of extension.commands.values()) command.sourceInfo = extension.sourceInfo;
        }
        const tools = new Map([...extension.tools].filter(([name]) => !toolNames.has(name)));
        const commands = new Map([...extension.commands].filter(([name]) => !toolNames.has(name)));
        if (tools.size === extension.tools.size && commands.size === extension.commands.size) return [extension];
        if (tools.size === 0 && commands.size === 0) return [];
        return [{ ...extension, tools, commands }];
      }),
    }),
  };
}

const reservedChannel = "pi.async-tasks.v1";

/** Other extensions share the session bus except for the host-owned protocol. */
export function ordinaryExtensionBus(bus: EventBus): EventBus {
  return {
    emit(channel, data) { if (channel !== reservedChannel) bus.emit(channel, data); },
    on(channel, handler) { return channel === reservedChannel ? () => {} : bus.on(channel, handler); },
  };
}

const runtimeActions = [
  "sendMessage", "sendUserMessage", "appendEntry", "setSessionName", "getSessionName",
  "setLabel", "getActiveTools", "getAllTools", "getSettings", "setActiveTools", "refreshTools",
  "getCommands", "setModel", "getThinkingLevel", "setThinkingLevel",
  "registerProvider", "registerNativeProvider", "unregisterProvider",
] as const;

/** The SDK binds one runtime. Fan that public binding out to each loader's captured APIs. */
function composeExtensionRuntime(runtimes: ExtensionRuntime[]): ExtensionRuntime {
  const combined = createExtensionRuntime();
  const flags = combined.flagValues;
  for (const runtime of runtimes) {
    for (const [key, value] of runtime.flagValues) flags.set(key, value);
    runtime.flagValues = flags;
  }
  for (const action of runtimeActions) {
    Object.defineProperty(combined, action, {
      configurable: true,
      get: () => runtimes[0]![action],
      set: (value: ExtensionRuntime[typeof action]) => {
        for (const runtime of runtimes) Reflect.set(runtime, action, value);
      },
    });
  }
  Object.defineProperty(combined, "pendingProviderRegistrations", {
    get: () => runtimes.flatMap(runtime => runtime.pendingProviderRegistrations),
    set: () => { for (const runtime of runtimes) runtime.pendingProviderRegistrations = []; },
  });
  Object.defineProperty(combined, "pendingNativeProviderRegistrations", {
    get: () => runtimes.flatMap(runtime => runtime.pendingNativeProviderRegistrations),
    set: () => { for (const runtime of runtimes) runtime.pendingNativeProviderRegistrations = []; },
  });
  // `pi.registerMcpServer()` and the MCP extension share one registry, and the runner listens
  // to it for `mcp_servers_change`. Ordinary extensions (runtimes[0]) own MCP.
  combined.mcpServers = runtimes[0]!.mcpServers;
  combined.assertActive = () => { for (const runtime of runtimes) runtime.assertActive(); };
  combined.invalidate = message => { for (const runtime of runtimes) runtime.invalidate(message); };
  return combined;
}

/** Delegate the normal resource catalog intact; only extension loading uses two buses. */
export function composeAsyncProviderLoader(normal: ResourceLoader, owned: ResourceLoader, reload: () => Promise<[ResourceLoader, ResourceLoader]>): ResourceLoader {
  let ordinary = normal;
  let providers = owned;
  const merged = () => {
    const first = ordinary.getExtensions();
    const second = providers.getExtensions();
    return {
      extensions: [...first.extensions, ...second.extensions],
      errors: [...first.errors, ...second.errors],
      runtime: composeExtensionRuntime([first.runtime, second.runtime]),
    };
  };
  let extensions = merged();
  return {
    getExtensions: () => extensions,
    getSkills: () => ordinary.getSkills(),
    getPrompts: () => ordinary.getPrompts(),
    getThemes: () => ordinary.getThemes(),
    getAgentsFiles: () => ordinary.getAgentsFiles(),
    getSystemPrompt: () => ordinary.getSystemPrompt(),
    getSystemPromptSource: () => ordinary.getSystemPromptSource(),
    getAppendSystemPrompt: () => ordinary.getAppendSystemPrompt(),
    getAppendSystemPromptSources: () => ordinary.getAppendSystemPromptSources(),
    extendResources(paths) { ordinary.extendResources(paths); },
    async reload() { [ordinary, providers] = await reload(); extensions = merged(); },
  };
}
