import { execFile as execFileCallback } from "node:child_process";
import { mkdtemp, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";
import { SESSION_DIFF_MAX_FILES, SESSION_DIFF_PER_FILE_BYTES, SESSION_DIFF_TOTAL_BYTES } from "../domain/git-diff.js";
import { readSessionDiff } from "./session-diff.js";

const execFile = promisify(execFileCallback);

describe("readSessionDiff", () => {
  it("returns unstaged tracked and untracked file diffs from a real repository", async () => {
    const directory = await createRepository();
    await writeFile(join(directory, "tracked.ts"), "export const value = 2;\n");
    await writeFile(join(directory, "untracked.ts"), "export const extra = true;\n");

    const result = await readSessionDiff(directory, "unstaged");

    expect(result).toMatchObject({ isGitRepo: true, filesTruncated: false });
    expect(result.files).toEqual(expect.arrayContaining([
      expect.objectContaining({ path: "tracked.ts", status: "modified", additions: 1, deletions: 1, truncated: false }),
      expect.objectContaining({ path: "untracked.ts", status: "untracked", additions: 1, deletions: 0, truncated: false }),
    ]));
    expect(result.files.find((file) => file.path === "untracked.ts")?.diff).toContain("+export const extra = true;");
  });

  it("returns staged diffs without untracked files", async () => {
    const directory = await createRepository();
    await writeFile(join(directory, "tracked.ts"), "export const value = 2;\n");
    await writeFile(join(directory, "untracked.ts"), "export const extra = true;\n");
    await git(directory, ["add", "--", "tracked.ts"]);

    const result = await readSessionDiff(directory, "staged");

    expect(result).toMatchObject({ isGitRepo: true, filesTruncated: false });
    expect(result.files).toEqual([expect.objectContaining({ path: "tracked.ts", status: "modified", additions: 1, deletions: 1 })]);
  });

  it("preserves renamed file metadata in a staged batch diff", async () => {
    const directory = await createRepository();
    await git(directory, ["mv", "tracked.ts", "renamed.ts"]);
    await git(directory, ["add", "-A"]);

    const result = await readSessionDiff(directory, "staged");

    expect(result.files).toEqual([expect.objectContaining({
      path: "renamed.ts",
      status: "renamed",
      renamedFrom: "tracked.ts",
      additions: 0,
      deletions: 0,
    })]);
  });

  it("keeps a repository result when a capped batch diff terminates git", async () => {
    const directory = await createRepository();
    await writeFile(join(directory, "tracked.ts"), "x".repeat(SESSION_DIFF_TOTAL_BYTES + 1));

    const result = await readSessionDiff(directory, "unstaged");
    const file = result.files.find((candidate) => candidate.path === "tracked.ts");

    expect(result.isGitRepo).toBe(true);
    expect(file).toMatchObject({ truncated: true });
    expect(Buffer.byteLength(file?.diff ?? "")).toBeLessThanOrEqual(SESSION_DIFF_PER_FILE_BYTES);
    expect(file?.diff).not.toContain("[diff truncated]");
  });

  it("retains a later patch after an earlier file reaches its per-file cap", async () => {
    const directory = await createRepository();
    await writeFile(join(directory, "z-second.ts"), "export const second = 1;\n");
    await git(directory, ["add", "--", "z-second.ts"]);
    await git(directory, ["commit", "-m", "add second file"]);
    await writeFile(join(directory, "tracked.ts"), "x".repeat(3 * 1024 * 1024));
    await writeFile(join(directory, "z-second.ts"), "export const second = 2;\n");

    const result = await readSessionDiff(directory, "unstaged");
    const first = result.files.find((file) => file.path === "tracked.ts");
    const second = result.files.find((file) => file.path === "z-second.ts");

    expect(result.isGitRepo).toBe(true);
    expect(first).toMatchObject({ truncated: true });
    expect(Buffer.byteLength(first?.diff ?? "")).toBeLessThanOrEqual(SESSION_DIFF_PER_FILE_BYTES);
    expect(second).toMatchObject({ truncated: false, additions: 1, deletions: 1 });
    expect(second?.diff).toContain("+export const second = 2;");
  });

  it.skipIf(process.platform === "win32")("preserves counts for tracked filenames containing tabs", async () => {
    const directory = await createRepository();
    const filename = "tracked\tfile.ts";
    await writeFile(join(directory, filename), "export const value = 1;\n");
    await git(directory, ["add", "--", filename]);
    await git(directory, ["commit", "-m", "add tab file"]);
    await writeFile(join(directory, filename), "export const value = 2;\n");

    const result = await readSessionDiff(directory, "unstaged");

    expect(result.files).toEqual(expect.arrayContaining([
      expect.objectContaining({ path: filename, additions: 1, deletions: 1 }),
    ]));
  });

  it("caps changed files and bounds untracked Git process creation", async () => {
    const directory = await createRepository();
    await Promise.all(Array.from({ length: SESSION_DIFF_MAX_FILES + 300 }, async (_, index) => {
      await writeFile(join(directory, `untracked-${index}.txt`), "new\n");
    }));
    let spawnCount = 0;

    const result = await readSessionDiff(directory, "unstaged", { onGitSpawn: () => { spawnCount += 1; } });

    expect(result.files).toHaveLength(SESSION_DIFF_MAX_FILES);
    expect(result.filesTruncated).toBe(true);
    expect(spawnCount).toBeLessThanOrEqual(2 + Math.ceil(SESSION_DIFF_TOTAL_BYTES / SESSION_DIFF_PER_FILE_BYTES));
  });

  it("does not update the Git index mtime while reading a clean repository", async () => {
    const directory = await createRepository();
    const index = join(directory, ".git", "index");
    const before = await stat(index);

    await expect(readSessionDiff(directory, "unstaged")).resolves.toMatchObject({ isGitRepo: true, files: [] });

    const after = await stat(index);
    expect(after.mtimeMs).toBe(before.mtimeMs);
  });

  it("reports a non-repository cwd without an error", async () => {
    const directory = await mkdtemp(join(tmpdir(), "picky-session-diff-non-git-"));

    await expect(readSessionDiff(directory, "unstaged")).resolves.toEqual({ isGitRepo: false, files: [], filesTruncated: false });
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
