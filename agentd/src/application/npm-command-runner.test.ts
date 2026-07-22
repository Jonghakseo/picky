import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { NPM_COMMAND_TIMEOUT_EXIT_CODE, parseNpmCommandRunnerArguments, runNpmCommandWithTimeout } from "./npm-command-runner.js";

describe("npm command runner", () => {
  it("parses the wrapped command separately from npm arguments", () => {
    expect(parseNpmCommandRunnerArguments([
      "--timeout-ms",
      "90000",
      "--command-json",
      JSON.stringify(["/bundled/node", "/bundled/npm-cli.js"]),
      "--",
      "npm",
      "install",
      "--global",
      "fixture",
    ])).toEqual({
      timeoutMs: 90_000,
      command: ["/bundled/node", "/bundled/npm-cli.js"],
      npmArgs: ["install", "--global", "fixture"],
    });
  });

  it("forwards npm arguments and returns the child exit code", async () => {
    const exitCode = await runNpmCommandWithTimeout({
      timeoutMs: 2_000,
      command: [process.execPath, "-e", "process.exit(process.argv[1] === 'sentinel' ? 0 : 9)"],
      npmArgs: ["sentinel"],
    });

    expect(exitCode).toBe(0);
  });

  it("terminates a stuck process group at the configured timeout", async () => {
    const startedAt = Date.now();
    const exitCode = await runNpmCommandWithTimeout({
      timeoutMs: 50,
      command: [process.execPath, "-e", "setInterval(() => {}, 1000)"],
      npmArgs: [],
    });

    expect(exitCode).toBe(NPM_COMMAND_TIMEOUT_EXIT_CODE);
    expect(Date.now() - startedAt).toBeLessThan(1_500);
  });

  it("waits for a SIGTERM-resistant descendant to be force-killed before returning", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-npm-runner-tree-"));
    const childPIDPath = join(root, "child.pid");
    const leaderScript = [
      "const { spawn } = require('node:child_process');",
      "const { writeFileSync } = require('node:fs');",
      "const child = spawn(process.execPath, ['-e', \"process.on('SIGTERM', () => {}); setInterval(() => {}, 1000)\"], { stdio: 'ignore' });",
      "writeFileSync(process.argv[1], String(child.pid));",
      "process.on('SIGTERM', () => process.exit(0));",
      "setInterval(() => {}, 1000);",
    ].join("\n");
    try {
      const exitCode = await runNpmCommandWithTimeout({
        timeoutMs: 50,
        command: [process.execPath, "-e", leaderScript, childPIDPath],
        npmArgs: [],
      }, spawn, 25);
      const childPID = Number(await readFile(childPIDPath, "utf8"));

      expect(exitCode).toBe(NPM_COMMAND_TIMEOUT_EXIT_CODE);
      expect(() => process.kill(childPID, 0)).toThrow();
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
