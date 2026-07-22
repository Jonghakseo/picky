import { describe, expect, it } from "vitest";
import { delimiter } from "node:path";
import { bundledNpmCliPath, prependNodeBinToPath, resolveNpmCommand } from "./npm-command.js";

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

  it("preserves an absent configuration when no bundled npm CLI exists", () => {
    expect(resolveNpmCommand({
      configured: undefined,
      execPath,
      fileExists: () => false,
    })).toBeUndefined();
  });
});

describe("prependNodeBinToPath", () => {
  const nodeBin = "/Applications/Picky.app/Contents/Resources/agentd-runtime/bin";

  it("prepends the running Node directory", () => {
    expect(prependNodeBinToPath(`/usr/local/bin${delimiter}/usr/bin`, execPath))
      .toBe(`${nodeBin}${delimiter}/usr/local/bin${delimiter}/usr/bin`);
  });

  it("does not duplicate the running Node directory", () => {
    const path = `${nodeBin}${delimiter}/usr/local/bin`;

    expect(prependNodeBinToPath(path, execPath)).toBe(path);
  });

  it("uses the running Node directory for an empty PATH", () => {
    expect(prependNodeBinToPath(undefined, execPath)).toBe(nodeBin);
    expect(prependNodeBinToPath("", execPath)).toBe(nodeBin);
  });
});
