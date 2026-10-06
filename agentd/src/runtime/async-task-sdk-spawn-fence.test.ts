import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, test } from "vitest";

const fixture = fileURLToPath(new URL("./async-task-sdk-spawn-fence.fixture.mjs", import.meta.url));
const installedSDK = fileURLToPath(new URL("../../node_modules/@earendil-works/pi-coding-agent", import.meta.url));
// Explicit acceptance targets are mandatory if supplied, never silently skipped.
const targets: Record<string, string> = process.env.PICKY_SDK_SPAWN_FENCE_TARGETS
  ? JSON.parse(process.env.PICKY_SDK_SPAWN_FENCE_TARGETS) as Record<string, string>
  : { "1.0.4": installedSDK };
if (Object.keys(targets).length === 0) throw new Error("At least one SDK target is required");

for (const [version, sdk] of Object.entries(targets)) {
  test(`SDK ${version} fences native spawn after abort and preserves finite execution`, () => {
    const home = mkdtempSync(join(tmpdir(), "PickySdkSpawnFenceTest-"));
    mkdirSync(join(home, "agent"));
    mkdirSync(join(home, "support"));
    try {
      const output = execFileSync(process.execPath, [fixture, sdk, version, "fenced"], {
        cwd: home,
        env: {
          PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
          HOME: home,
          PI_CODING_AGENT_DIR: join(home, "agent"),
          PICKY_APP_SUPPORT_DIR: join(home, "support"),
        },
        encoding: "utf8",
        timeout: 15_000,
      });
      expect(output).toContain('"afterAbort":0');
      expect(output).toContain('"output":"sdk-fence-ok"');
      console.log(output.trim());
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
}
