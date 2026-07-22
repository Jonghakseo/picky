import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { CancellablePackageProcessController } from "./package-process-controller.js";

describe("CancellablePackageProcessController", () => {
  it("cancels a git-like process group and waits for resistant descendants to exit", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-package-process-tree-"));
    const childPIDPath = join(root, "child.pid");
    const leaderScript = [
      "const { spawn } = require('node:child_process');",
      "const { writeFileSync } = require('node:fs');",
      "const child = spawn(process.execPath, ['-e', \"process.on('SIGTERM', () => {}); setInterval(() => {}, 1000)\"], { stdio: 'ignore' });",
      "writeFileSync(process.argv[1], String(child.pid));",
      "process.on('SIGTERM', () => process.exit(0));",
      "setInterval(() => {}, 1000);",
    ].join("\n");
    const controller = new CancellablePackageProcessController({ forceKillGraceMs: 25, pollIntervalMs: 5 });
    try {
      const operation = controller.runCommand(process.execPath, ["-e", leaderScript, childPIDPath]);
      const childPID = await waitForPID(childPIDPath);

      await controller.cancelAll();

      await expect(operation).rejects.toThrow(/cancelled/i);
      expect(() => process.kill(childPID, 0)).toThrow();
    } finally {
      await controller.cancelAll();
      await rm(root, { recursive: true, force: true });
    }
  });

  it("captures command output without changing successful command semantics", async () => {
    const controller = new CancellablePackageProcessController();

    await expect(controller.runCommandCapture(
      process.execPath,
      ["-e", "process.stdout.write('captured')"],
    )).resolves.toBe("captured");
  });

  it("cancels capture commands at their command-specific timeout", async () => {
    const controller = new CancellablePackageProcessController({ forceKillGraceMs: 25, pollIntervalMs: 5 });

    await expect(controller.runCommandCapture(
      process.execPath,
      ["-e", "process.on('SIGTERM', () => {}); setInterval(() => {}, 1000)"],
      { timeoutMs: 25 },
    )).rejects.toThrow(/timed out after 25ms/);
  });
});

async function waitForPID(path: string): Promise<number> {
  const deadline = Date.now() + 2_000;
  while (Date.now() < deadline) {
    try {
      return Number(await readFile(path, "utf8"));
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }
  throw new Error(`Timed out waiting for ${path}`);
}
