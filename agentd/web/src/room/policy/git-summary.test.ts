import { describe, expect, it } from "vitest";
import { changesTabCounts, compactWorkspacePath, gitSummaryPresentation, parseGitSummary } from "./git-summary";

const repo = (overrides: Record<string, unknown> = {}) =>
  parseGitSummary({
    isGitRepo: true,
    repositoryName: "picky",
    branchName: "main",
    hasUncommittedChanges: true,
    uncommitted: { insertions: 5, deletions: 1 },
    branch: { insertions: 19, deletions: 3 },
    aheadCount: 1,
    behindCount: 0,
    ...overrides,
  });

describe("gitSummaryPresentation", () => {
  it("shows the branch total and the differing uncommitted subset, like the HUD details popover", () => {
    expect(gitSummaryPresentation(repo())).toEqual({
      repositoryName: "picky",
      branchLabel: "main",
      total: { pair: { insertions: "+19", deletions: "-3" }, isBranch: true },
      uncommitted: { insertions: "+5", deletions: "-1" },
      ahead: 1,
      behind: 0,
    });
  });

  it("drops the uncommitted subset when it equals the branch total", () => {
    const presentation = gitSummaryPresentation(repo({ branch: { insertions: 5, deletions: 1 } }));
    expect(presentation?.uncommitted).toBeUndefined();
    expect(presentation?.total?.isBranch).toBe(true);
  });

  it("falls back to uncommitted counts when there is no base to measure the branch from", () => {
    const presentation = gitSummaryPresentation(repo({ branch: undefined }));
    expect(presentation?.total).toEqual({ pair: { insertions: "+5", deletions: "-1" }, isBranch: false });
    expect(presentation?.uncommitted).toBeUndefined();
  });

  it("marks a dirty tree with no countable lines with an asterisk", () => {
    const presentation = gitSummaryPresentation(repo({ uncommitted: { insertions: 0, deletions: 0 }, branch: undefined }));
    expect(presentation?.branchLabel).toBe("main*");
    expect(presentation?.total).toBeUndefined();
  });

  it("hides everything Git-specific outside a repository or for an unreadable answer", () => {
    expect(gitSummaryPresentation(parseGitSummary({ isGitRepo: false }))).toBeUndefined();
    expect(gitSummaryPresentation(parseGitSummary("garbage"))).toBeUndefined();
  });
});

describe("changesTabCounts", () => {
  it("labels the changes tab with uncommitted counts only", () => {
    expect(changesTabCounts(repo())).toEqual({ insertions: "+5", deletions: "-1" });
    expect(changesTabCounts(repo({ uncommitted: { insertions: 0, deletions: 0 } }))).toBeUndefined();
    expect(changesTabCounts(null)).toBeUndefined();
  });
});

describe("compactWorkspacePath", () => {
  it("abbreviates a macOS home folder and leaves other paths alone", () => {
    expect(compactWorkspacePath("/Users/you/Documents/picky")).toBe("~/Documents/picky");
    expect(compactWorkspacePath("/Users/you")).toBe("~");
    expect(compactWorkspacePath("/opt/work/picky")).toBe("/opt/work/picky");
  });
});
