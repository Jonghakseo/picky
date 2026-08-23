import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { pathToFileURL } from "node:url";
import { describe, expect, it } from "vitest";
import { installInternalPickyCli } from "./internal-picky-cli.js";

describe("internal Picky CLI installer", () => {
  it("installs a caller-tagged compiled CLI wrapper and prepends it to PATH", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-internal-cli-"));
    const appSupportDir = join(root, "Application Support", "Picky's Test");
    const applicationDir = join(root, "dist", "application");
    await mkdir(applicationDir, { recursive: true });
    await writeFile(join(root, "dist", "cli.js"), "// fixture", "utf8");
    const env: NodeJS.ProcessEnv = { PATH: "/usr/bin:/bin" };

    const wrapper = await installInternalPickyCli({
      appSupportDir,
      env,
      execPath: "/bundled/node",
      execArgv: ["--inspect"],
      moduleUrl: pathToFileURL(join(applicationDir, "internal-picky-cli.js")).href,
    });

    const script = await readFile(wrapper, "utf8");
    expect(script).toContain("export PICKY_CLI_CALLER=mainAgent");
    expect(script).toContain("PICKY_APP_SUPPORT_DIR='/");
    expect(script).toContain("Picky'\\''s Test'");
    expect(script).toContain("exec '/bundled/node' '");
    expect(script).toContain("/dist/cli.js' \"$@\"");
    expect(script).not.toContain("--inspect");
    expect(env.PATH?.split(delimiter)[0]).toBe(join(appSupportDir, "bin"));
  });

  it("reuses the current tsx loader arguments for source development", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-internal-cli-source-"));
    const applicationDir = join(root, "src", "application");
    await mkdir(applicationDir, { recursive: true });
    await writeFile(join(root, "src", "cli.ts"), "// fixture", "utf8");

    const wrapper = await installInternalPickyCli({
      appSupportDir: join(root, "support"),
      env: { PATH: "/usr/bin" },
      execPath: "/usr/bin/node",
      execArgv: ["--import", "/repo/node_modules/tsx/dist/loader.mjs"],
      moduleUrl: pathToFileURL(join(applicationDir, "internal-picky-cli.ts")).href,
    });

    const script = await readFile(wrapper, "utf8");
    expect(script).toContain("'--import' '/repo/node_modules/tsx/dist/loader.mjs'");
    expect(script).toContain("/src/cli.ts' \"$@\"");
  });
});
