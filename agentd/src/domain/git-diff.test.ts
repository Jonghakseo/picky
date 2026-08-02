import { describe, expect, it } from "vitest";
import { parseGitNumstat, parseGitNumstatEntries, parseGitPatchSections, parseGitStatusPorcelain, truncateDiff } from "./git-diff.js";

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

  it("parses normal and renamed numstat records", () => {
    expect(parseGitNumstat("12\t3\tsource.ts\n")).toEqual({ additions: 12, deletions: 3 });
    expect(parseGitNumstat("-\t-\timage.png\n")).toEqual({ additions: 0, deletions: 0 });
    expect(parseGitNumstatEntries("0\t0\t\0old-name.ts\0new-name.ts\0")).toEqual([
      { path: "new-name.ts", additions: 0, deletions: 0 },
    ]);
  });

  it("preserves tab-containing paths in numstat records", () => {
    expect(parseGitNumstatEntries("3\t2\tdirectory/file\twith-tab.ts\0")).toEqual([
      { path: "directory/file\twith-tab.ts", additions: 3, deletions: 2 },
    ]);
  });

  it("splits batch patches and truncates at UTF-8 boundaries without protocol markers", () => {
    expect(parseGitPatchSections("diff --git a/a.ts b/a.ts\n+one\ndiff --git a/b.ts b/b.ts\n+two\n")).toHaveLength(2);

    const result = truncateDiff("abc😀def", 6, true);
    expect(result).toEqual({ text: "abc", truncated: true });
    expect(result.text).not.toContain("�");
    expect(result.text).not.toContain("[diff truncated]");
  });
});
