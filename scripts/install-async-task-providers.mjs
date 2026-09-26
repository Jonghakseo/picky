#!/usr/bin/env node
import { cp, mkdir, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

// Invoked only after agentd has been compiled and deployed. The checked-in lock
// pins the actual packed provider file bytes, independent of npm registry state.
const [runtimeArg, sourceArg, lockArg, dependenciesArg] = process.argv.slice(2);
if (!runtimeArg || !sourceArg || !lockArg || !dependenciesArg) {
  throw new Error("Usage: install-async-task-providers.mjs <runtime> <extracted-packages-root> <provider-lock> <dependency-root>");
}
const runtime = resolve(runtimeArg);
const capsule = join(runtime, "async-task-providers");
const source = resolve(sourceArg);
const lock = resolve(lockArg);
const dependencies = resolve(dependenciesArg);
const { qualifyAsyncProviders } = await import(pathToFileURL(join(runtime, "dist/runtime/qualified-async-providers.js")).href);
// No unresolved checkout link can enter the bundle. qualifyAsyncProviders
// checks every regular file, package identity, and both dependency imports.
if (process.env.PICKY_ASYNC_PROVIDER_VERIFY_ONLY !== "1") {
  for (const name of ["bash-async", "subagent"]) {
    await mkdir(join(capsule, "packages"), { recursive: true });
    await cp(join(source, "packages", name), join(capsule, "packages", name), { recursive: true, force: false, errorOnExist: true });
  }
  await cp(lock, join(runtime, "async-task-providers.lock.json"));
  await cp(join(dependencies, "package.json"), join(capsule, "package.json"));
  await cp(join(dependencies, "pnpm-lock.yaml"), join(capsule, "pnpm-lock.yaml"));
}
const pinned = JSON.parse(await readFile(lock, "utf8"));
for (const name of ["bash-async", "subagent"]) {
  if (!pinned.packages?.[name]?.files?.["index.ts"]) throw new Error(`Provider ${name} is not content-pinned`);
}
if (process.env.PICKY_ASYNC_PROVIDER_PREINSTALL_ONLY === "1") process.exit(0);
if (!qualifyAsyncProviders(capsule, join(runtime, "async-task-providers.lock.json"))) throw new Error("Packaged async providers failed integrity or dependency qualification");
console.log(`Qualified Picky-owned async providers: ${capsule}`);
