import assert from "node:assert/strict";
import { createHook } from "node:async_hooks";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

// Run in a disposable process with a temporary HOME and cwd. No mocked spawn/fs.
const [sdk, expectedVersion, mode = "fenced"] = process.argv.slice(2);
assert.ok(sdk && expectedVersion, "SDK directory and exact version are required");
assert.ok(["baseline", "fenced"].includes(mode));
const metadata = JSON.parse(await readFile(join(sdk, "package.json"), "utf8"));
assert.equal(metadata.version, expectedVersion);
const { createLocalShellOperations } = await import(pathToFileURL(join(sdk, "dist/core/tools/bash.js")).href);
const ops = createLocalShellOperations("bash", () => ({ shell: "/bin/bash", args: ["-c"] }));
let controller;
let spawns = 0;
let afterAbort = 0;
const hook = createHook({ init(_id, type) {
  if (type === "PROCESSWRAP") {
    spawns++;
    if (controller?.signal.aborted) afterAbort++;
  }
} });
hook.enable();
try {
  controller = new AbortController();
  // exec runs synchronously up to its first await; abort before that await resumes.
  const pending = ops.exec("true", process.cwd(), { signal: controller.signal, onData() {} });
  controller.abort();
  await assert.rejects(pending, /^Error: aborted$/);
  const race = { sdk: metadata.version, mode, spawns, afterAbort, outcome: "aborted" };
  console.log(JSON.stringify(race));
  assert.equal(afterAbort, mode === "baseline" ? 1 : 0);
  assert.equal(spawns, mode === "baseline" ? 1 : 0);

  controller = new AbortController();
  spawns = 0;
  let output = "";
  const result = await ops.exec("printf sdk-fence-ok; exit 7", process.cwd(), {
    onData(data) { output += data.toString(); },
  });
  assert.equal(output, "sdk-fence-ok");
  assert.equal(result.exitCode, 7);
  assert.equal(spawns, 1);
  console.log(JSON.stringify({ normal: result, output, spawns }));

  await assert.rejects(ops.exec("true", join(process.cwd(), "missing-cwd"), { onData() {} }), /Working directory does not exist:/);
  controller = new AbortController();
  let ready = false;
  await assert.rejects(ops.exec("printf ready; exec /bin/sleep 2", process.cwd(), {
    signal: controller.signal,
    onData() { ready = true; controller.abort(); },
  }), /^Error: aborted$/);
  assert.equal(ready, true);
  await assert.rejects(ops.exec("exec /bin/sleep 2", process.cwd(), {
    timeout: 0.05, onData() {},
  }), /^Error: timeout:0.05$/);
  console.log(JSON.stringify({ cwdError: "preserved", runningAbort: "aborted after output", timeout: "timeout:0.05" }));
} finally {
  hook.disable();
}
