import { execFile as execFileCallback } from "node:child_process";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";
import { readSessionDiff } from "./session-diff.js";

const execFile = promisify(execFileCallback);

describe("readSessionDiff", () => {
  it("returns unstaged tracked and untracked file diffs from a real repository", async () => {
    const directory = await createRepository();
    await writeFile(join(directory, "tracked.ts"), "export const value = 2;\n");
    await writeFile(join(directory, "untracked.ts"), "export const extra = true;\n");

    const result = await readSessionDiff(directory, "unstaged");

    expect(result).toMatchObject({ isGitRepo: true });
    expect(result.files).toEqual(expect.arrayContaining([
      expect.objectContaining({ path: "tracked.ts", status: "modified", additions: 1, deletions: 1 }),
      expect.objectContaining({ path: "untracked.ts", status: "untracked", additions: 1, deletions: 0 }),
    ]));
    expect(result.files.find((file) => file.path === "untracked.ts")?.diff).toContain("+export const extra = true;");
  });

  it("returns staged diffs without untracked files", async () => {
    const directory = await createRepository();
    await writeFile(join(directory, "tracked.ts"), "export const value = 2;\n");
    await writeFile(join(directory, "untracked.ts"), "export const extra = true;\n");
    await git(directory, ["add", "--", "tracked.ts"]);

    const result = await readSessionDiff(directory, "staged");

    expect(result).toMatchObject({ isGitRepo: true });
    expect(result.files).toEqual([expect.objectContaining({ path: "tracked.ts", status: "modified", additions: 1, deletions: 1 })]);
  });

  it("reports a non-repository cwd without an error", async () => {
    const directory = await mkdtemp(join(tmpdir(), "picky-session-diff-non-git-"));

    await expect(readSessionDiff(directory, "unstaged")).resolves.toEqual({ isGitRepo: false, files: [] });
  });
});

async function createRepository(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "picky-session-diff-"));
  await git(directory, ["init"]);
  await git(directory, ["config", "user.email", "test@example.com"]);
  await git(directory, ["config", "user.name", "Picky Test"]);
  await writeFile(join(directory, "tracked.ts"), "export const value = 1;\n");
  await git(directory, ["add", "--", "tracked.ts"]);
  await git(directory, ["commit", "-m", "initial"]);
  return directory;
}

async function git(cwd: string, args: string[]): Promise<void> {
  await execFile("git", args, { cwd });
}
