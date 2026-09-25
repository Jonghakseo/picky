import { spawn } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const extensionRoot = process.env.PICKY_TEST_EXTENSION_ROOT?.trim();
const require = createRequire(import.meta.url);
const tsxLoader = join(dirname(require.resolve("tsx/package.json")), "dist/loader.mjs");

async function run(root: string): Promise<string> {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(process.execPath, ["--import", tsxLoader, join(root, "harness.mjs")], {
      cwd: root,
      detached: true,
      env: { ...process.env, HOME: join(root, "home"), PI_CODING_AGENT_DIR: join(root, "home/.pi/agent"),
        PI_OFFLINE: "1", PICKY_W0_ROOT: root },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    let timedOut = false;
    const timeout = setTimeout(() => {
      timedOut = true;
      // The isolated process group includes the controlled resource-exit child.
      if (child.pid !== undefined) {
        try { process.kill(-child.pid, "SIGKILL"); } catch { child.kill("SIGKILL"); }
      }
    }, 45_000);
    child.stdout.on("data", chunk => { output += String(chunk); });
    child.stderr.on("data", chunk => { output += String(chunk); });
    child.once("error", error => { clearTimeout(timeout); rejectRun(error); });
    child.once("close", code => {
      clearTimeout(timeout);
      if (code === 0 && !timedOut) resolveRun(output);
      else rejectRun(new Error(`W0 harness exit=${code} timeout=${timedOut}\n${output}`));
    });
  });
}

// Explicit opt-in keeps ordinary runs independent of a second repository. An
// invalid explicit checkout fails during copy; it cannot become a skipped pass.
for (const sdk of ["picky", "extension"] as const) {
  (extensionRoot ? it : it.skip)(`proves offline async host boundaries with ${sdk} SDK`, async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-w0-"));
    try {
      const dependencies = sdk === "picky" ? join(repositoryRoot, "agentd/node_modules") : join(extensionRoot!, "node_modules");
      await symlink(dependencies, join(root, "node_modules"));
      await mkdir(join(root, "home/.pi/agent"), { recursive: true });
      await writeFile(join(root, "package.json"), JSON.stringify({ type: "module" }));
      await cp(join(repositoryRoot, "agentd/src/runtime/fixtures/async-task-host.mjs"), join(root, "harness.mjs"));
      for (const name of ["bash-async", "subagent"]) {
        await cp(join(extensionRoot!, "packages", name), join(root, "packages", name), {
          recursive: true, filter: path => !path.includes("/node_modules"),
        });
      }
      const output = await run(root);
      const expected = JSON.parse(await readFile(join(dependencies, "@earendil-works/pi-coding-agent/package.json"), "utf8")) as { version: string };
      expect(output).toContain(`"version":"${expected.version}"`);
      expect(output).toContain('"event":"providers-loaded"');
      expect(output).toContain('"fenced":true,"externalRequests":1,"admissionRejections":1');
      console.log(output.trim());
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }, 60_000);
}
