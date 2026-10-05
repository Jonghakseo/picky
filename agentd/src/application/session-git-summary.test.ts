import { execFile as execFileCallback } from "node:child_process";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";
import { readSessionGitSummary } from "./session-git-summary.js";

const execFile = promisify(execFileCallback);

describe("readSessionGitSummary", () => {
  it("reports branch-wide, uncommitted, and upstream counts the way the HUD context line does", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-git-summary-"));
    const origin = join(root, "picky-origin.git");
    await git(root, ["init", "--bare", "--initial-branch=main", origin]);
    const work = join(root, "work");
    await git(root, ["clone", origin, work]);
    await configure(work);
    await writeFile(join(work, "base.ts"), "export const base = 1;\n");
    await git(work, ["add", "-A"]);
    await git(work, ["commit", "-m", "base"]);
    await git(work, ["push", "-u", "origin", "main"]);

    // A feature branch: one pushed commit, one local commit, then uncommitted work.
    await git(work, ["switch", "-c", "feat/summary"]);
    await writeFile(join(work, "feature.ts"), "one\ntwo\nthree\n");
    await git(work, ["add", "-A"]);
    await git(work, ["commit", "-m", "feature"]);
    await git(work, ["push", "-u", "origin", "feat/summary"]);
    await writeFile(join(work, "local.ts"), "local\n");
    await git(work, ["add", "-A"]);
    await git(work, ["commit", "-m", "local"]);
    await writeFile(join(work, "base.ts"), "export const base = 2;\n");
    await writeFile(join(work, "untracked.ts"), "a\nb");

    const summary = await readSessionGitSummary(work);

    expect(summary).toEqual({
      isGitRepo: true,
      repositoryName: "picky-origin",
      branchName: "feat/summary",
      hasUncommittedChanges: true,
      // base.ts +1 -1, plus the two untracked lines (the last one has no newline).
      uncommitted: { insertions: 3, deletions: 1 },
      // Since main: feature.ts 3, local.ts 1, base.ts +1 -1, untracked 2.
      branch: { insertions: 7, deletions: 1 },
      aheadCount: 1,
      behindCount: 0,
    });
  });

  it("falls back to the folder name and omits the branch total without an origin", async () => {
    const work = await mkdtemp(join(tmpdir(), "picky-git-summary-local-"));
    await git(work, ["init", "--initial-branch=main"]);
    await configure(work);
    await writeFile(join(work, "file.ts"), "x\n");
    await git(work, ["add", "-A"]);
    await git(work, ["commit", "-m", "initial"]);

    const summary = await readSessionGitSummary(work);

    expect(summary.repositoryName).toMatch(/^picky-git-summary-local-/);
    expect(summary).toMatchObject({ isGitRepo: true, branchName: "main", hasUncommittedChanges: false, aheadCount: 0, behindCount: 0 });
    expect(summary.uncommitted).toEqual({ insertions: 0, deletions: 0 });
    expect(summary.branch).toBeUndefined();
  });

  it("answers not-a-repository for a plain folder or a missing cwd", async () => {
    const plain = await mkdtemp(join(tmpdir(), "picky-git-summary-plain-"));

    expect((await readSessionGitSummary(plain)).isGitRepo).toBe(false);
    expect((await readSessionGitSummary(undefined)).isGitRepo).toBe(false);
  });
});

async function configure(cwd: string): Promise<void> {
  await git(cwd, ["config", "user.email", "test@example.com"]);
  await git(cwd, ["config", "user.name", "Picky Test"]);
}

async function git(cwd: string, args: string[]): Promise<void> {
  await execFile("git", args, { cwd });
}
