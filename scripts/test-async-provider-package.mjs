#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdtemp, mkdir, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
await mkdir(join(repo, "build"), { recursive: true });
const root = await mkdtemp(join(repo, "build/async-provider-verify."));
const runtime = join(root, "runtime");
const source = join(root, "extracted");
const lockPath = join(root, "providers.lock.json");
const pnpm = process.env.PICKY_PNPM_BIN ?? "pnpm";
const run = (file, args, env = {}) => execFileSync(file, args, { cwd: repo, env: { ...process.env, HOME: join(root, "home"), PI_CODING_AGENT_DIR: join(root, "home/.pi/agent"), PI_OFFLINE: "1", ...env }, stdio: "inherit" });
try {
  await mkdir(join(root, "home/.pi/agent"), { recursive: true });
  const lock = { packages: {} };
  for (const [id, version] of [["bash-async", "0.2.1"], ["subagent", "0.5.7"]]) {
    const dir = join(source, "packages", id);
    await mkdir(dir, { recursive: true });
    const name = `@ryan_nookpi/pi-extension-${id}`;
    const tool = id === "bash-async" ? "bash_async" : "subagent";
    const imports = id === "subagent" ? `import YAML from 'yaml'; import { query } from '@anthropic-ai/claude-agent-sdk'; if (!YAML || !query) throw new Error('Dependency not loaded');\n` : "";
    await writeFile(join(dir, "index.ts"), `${imports}export default function(pi) { pi.registerTool({name:${JSON.stringify(tool)},label:'Packed',description:'Packed',parameters:{type:'object',properties:{}},execute:async()=>({content:[{type:'text',text:'packed-ready'}]})}); }\n`);
    await writeFile(join(dir, "package.json"), JSON.stringify({ name, version, type: "module", pi: { extensions: ["./index.ts"] } }));
    const files = {};
    for (const file of ["index.ts", "package.json"]) files[file] = createHash("sha256").update(await readFile(join(dir, file))).digest("hex");
    lock.packages[id] = { name, version, files };
  }
  await writeFile(lockPath, JSON.stringify(lock));
  run(pnpm, ["--filter", "picky-agentd", "deploy", "--prod", "--legacy", runtime]);
  const args = [join(repo, "scripts/install-async-task-providers.mjs"), runtime, source, lockPath, join(repo, "agentd/async-task-provider-deps")];
  run(process.execPath, args, { PICKY_ASYNC_PROVIDER_PREINSTALL_ONLY: "1" });
  run(pnpm, ["--dir", join(runtime, "async-task-providers"), "install", "--ignore-workspace", "--prod", "--frozen-lockfile", "--ignore-scripts"]);
  run(process.execPath, args, { PICKY_ASYNC_PROVIDER_VERIFY_ONLY: "1" });
  const { qualifyAsyncProviders } = await import(pathToFileURL(join(runtime, "dist/runtime/qualified-async-providers.js")).href);
  assert.equal(qualifyAsyncProviders(join(runtime, "async-task-providers"), join(runtime, "async-task-providers.lock.json"))?.paths.length, 2);
  const sdk = await import(pathToFileURL(join(runtime, "node_modules/@earendil-works/pi-coding-agent/dist/index.js")).href);
  const agentDir = join(root, "home/.pi/agent");
  // Match PiSdkRuntime's owned loader, not its ordinary loader that filters these tools out.
  const paths = qualifyAsyncProviders(join(runtime, "async-task-providers"), join(runtime, "async-task-providers.lock.json")).paths;
  const services = await sdk.createAgentSessionServices({ cwd: root, agentDir, settingsManager: sdk.SettingsManager.inMemory({ packages: [] }), resourceLoaderOptions: { noExtensions: true, additionalExtensionPaths: paths, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true } });
  const loaded = services.resourceLoader.getExtensions();
  assert.deepEqual(loaded.errors, [], "Standalone provider extensions must load without errors");
  assert.deepEqual(loaded.extensions.flatMap((extension) => [...extension.tools.keys()]).sort(), ["bash_async", "subagent"]);
  for (const dep of ["yaml", "@anthropic-ai/claude-agent-sdk"]) {
    const path = await realpath(join(runtime, "async-task-providers/node_modules", dep));
    assert.ok(path.startsWith(runtime), `Dependency escaped standalone runtime: ${path}`);
  }
  await cp(join(runtime, "async-task-providers", "packages", "bash-async", "index.ts"), join(root, "original.ts"));
  await writeFile(join(runtime, "async-task-providers", "packages", "bash-async", "index.ts"), "tampered");
  assert.equal(qualifyAsyncProviders(join(runtime, "async-task-providers"), join(runtime, "async-task-providers.lock.json")), undefined);
  console.log("Standalone packaged provider dependency, extension load, and byte-tamper checks passed");
} finally {
  await rm(root, { recursive: true, force: true });
}
