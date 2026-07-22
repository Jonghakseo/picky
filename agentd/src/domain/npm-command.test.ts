import { describe, expect, it } from "vitest";
import { bundledNpmCliPath, resolveNpmCommand } from "./npm-command.js";

const execPath = "/Applications/Picky.app/Contents/Resources/agentd-runtime/bin/node";
const bundledNpmCli = bundledNpmCliPath(execPath);

describe("resolveNpmCommand", () => {
  it("preserves an explicitly configured npm command", () => {
    const configured = ["/usr/local/bin/pnpm", "--silent"];

    expect(resolveNpmCommand({
      configured,
      execPath,
      fileExists: () => true,
    })).toEqual(configured);
  });

  it("uses the bundled npm CLI with the running Node binary when available", () => {
    expect(resolveNpmCommand({
      configured: undefined,
      execPath,
      fileExists: (path) => path === bundledNpmCli,
    })).toEqual([execPath, bundledNpmCli]);
  });

  it("preserves an empty configuration when no bundled npm CLI exists", () => {
    expect(resolveNpmCommand({
      configured: [],
      execPath,
      fileExists: () => false,
    })).toEqual([]);
  });
});
