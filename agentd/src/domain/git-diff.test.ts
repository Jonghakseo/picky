import { describe, expect, it } from "vitest";
import { DIFF_TRUNCATION_MARKER, parseGitNumstat, parseGitStatusPorcelain, truncateDiff } from "./git-diff.js";

describe("git diff domain policy", () => {
  it("selects staged and unstaged porcelain entries with stable statuses", () => {
    const porcelain = [
      "M  staged.ts",
      " M unstaged.ts",
      "R  renamed.ts",
      "original.ts",
      "?? new file.ts",
      "",
    ].join("\0");

    expect(parseGitStatusPorcelain(porcelain, "staged")).toEqual([
      { path: "staged.ts", status: "modified" },
      { path: "renamed.ts", status: "renamed", renamedFrom: "original.ts" },
    ]);
    expect(parseGitStatusPorcelain(porcelain, "unstaged")).toEqual([
      { path: "unstaged.ts", status: "modified" },
      { path: "new file.ts", status: "untracked" },
    ]);
  });

  it("parses text and binary numstat output", () => {
    expect(parseGitNumstat("12\t3\tsource.ts\n")).toEqual({ additions: 12, deletions: 3 });
    expect(parseGitNumstat("-\t-\timage.png\n")).toEqual({ additions: 0, deletions: 0 });
  });

  it("truncates at UTF-8 boundaries and appends a visible marker", () => {
    const result = truncateDiff("abc😀def", 24, true);

    expect(result.truncated).toBe(true);
    expect(result.text).toContain(DIFF_TRUNCATION_MARKER.trim());
    expect(result.text).not.toContain("�");
  });
});
