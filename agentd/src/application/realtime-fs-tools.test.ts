import { mkdtemp, readFile, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  REALTIME_BASH_TAIL_BYTES,
  REALTIME_READ_DEFAULT_LIMIT_LINES,
  REALTIME_READ_HARD_BYTES,
  executeRealtimeBash,
  executeRealtimeRead,
  executeRealtimeWrite,
} from "./realtime-fs-tools.js";

async function tempDir(prefix = "realtime-fs-tools"): Promise<string> {
  return mkdtemp(join(tmpdir(), `${prefix}-`));
}

describe("executeRealtimeRead", () => {
  it("returns the first N lines and the byte total of the file", async () => {
    const dir = await tempDir();
    const path = join(dir, "lines.txt");
    const lines = Array.from({ length: 100 }, (_, index) => `line-${index + 1}`);
    await writeFile(path, lines.join("\n"));

    const result = await executeRealtimeRead({ path });

    expect(result.totalLines).toBe(100);
    expect(result.offset).toBe(0);
    expect(result.limit).toBe(REALTIME_READ_DEFAULT_LIMIT_LINES);
    expect(result.content.split("\n")).toHaveLength(REALTIME_READ_DEFAULT_LIMIT_LINES);
    expect(result.truncated).toBe(true);
  });

  it("honours offset and limit", async () => {
    const dir = await tempDir();
    const path = join(dir, "lines.txt");
    const lines = Array.from({ length: 50 }, (_, index) => `line-${index + 1}`);
    await writeFile(path, lines.join("\n"));

    const result = await executeRealtimeRead({ path, offset: 10, limit: 5 });

    expect(result.content.split("\n")).toEqual(["line-11", "line-12", "line-13", "line-14", "line-15"]);
    expect(result.truncated).toBe(true);
    expect(result.offset).toBe(10);
    expect(result.limit).toBe(5);
  });

  it("truncates content above the hard byte cap", async () => {
    const dir = await tempDir();
    const path = join(dir, "wide.txt");
    const huge = "x".repeat(REALTIME_READ_HARD_BYTES * 2);
    await writeFile(path, huge);

    const result = await executeRealtimeRead({ path });

    expect(Buffer.byteLength(result.content, "utf8")).toBeLessThanOrEqual(REALTIME_READ_HARD_BYTES);
    expect(Buffer.byteLength(result.fullContent, "utf8")).toBeGreaterThan(REALTIME_READ_HARD_BYTES);
    expect(result.truncated).toBe(true);
  });

  it("does not flag truncation when the file fits in the cap", async () => {
    const dir = await tempDir();
    const path = join(dir, "small.txt");
    await writeFile(path, "hello\nworld");

    const result = await executeRealtimeRead({ path });

    expect(result.content).toBe("hello\nworld");
    expect(result.totalLines).toBe(2);
    expect(result.truncated).toBe(false);
  });

  it("rejects missing files", async () => {
    const dir = await tempDir();
    await expect(executeRealtimeRead({ path: join(dir, "missing.txt") })).rejects.toThrow();
  });
});

describe("executeRealtimeBash", () => {
  it("captures stdout and reports exit code 0", async () => {
    const result = await executeRealtimeBash({ command: "printf 'hello\\nworld\\n'" });
    expect(result.exitCode).toBe(0);
    expect(result.output).toBe("hello\nworld\n");
    expect(result.truncated).toBe(false);
    expect(result.timedOut).toBe(false);
  });

  it("merges stderr into the output stream", async () => {
    const result = await executeRealtimeBash({ command: "printf 'oops\\n' 1>&2; exit 3" });
    expect(result.exitCode).toBe(3);
    expect(result.output).toContain("oops");
  });

  it("returns a tail when output exceeds the hard cap", async () => {
    const result = await executeRealtimeBash({
      command: `python3 -c "import sys; sys.stdout.write('A' * ${REALTIME_BASH_TAIL_BYTES * 4})"`,
    });
    expect(result.exitCode).toBe(0);
    expect(Buffer.byteLength(result.output, "utf8")).toBeLessThanOrEqual(REALTIME_BASH_TAIL_BYTES);
    expect(result.truncated).toBe(true);
    expect(result.totalBytes).toBeGreaterThan(REALTIME_BASH_TAIL_BYTES);
  });

  it("kills the child on timeout and reports timedOut=true", async () => {
    const result = await executeRealtimeBash({ command: "sleep 5" }, { timeoutMs: 200 });
    expect(result.timedOut).toBe(true);
    expect(result.exitCode).not.toBe(0);
  });

  it("honours the cwd argument", async () => {
    // macOS resolves /var/folders -> /private/var/folders via a firmlink, so
    // compare both sides through realpath to avoid a symlink mismatch.
    const dir = await realpath(await tempDir());
    const result = await executeRealtimeBash({ command: "pwd", cwd: dir });
    expect(await realpath(result.cwd)).toBe(dir);
    expect(await realpath(result.output.trim())).toBe(dir);
  });
});

describe("executeRealtimeWrite", () => {
  it("overwrites files by default", async () => {
    const dir = await tempDir();
    const path = join(dir, "out.txt");
    await writeFile(path, "old");

    const result = await executeRealtimeWrite({ path, content: "new" });

    expect(result.mode).toBe("overwrite");
    expect(result.bytesWritten).toBe(3);
    await expect(readFile(path, "utf8")).resolves.toBe("new");
  });

  it("appends when mode=append", async () => {
    const dir = await tempDir();
    const path = join(dir, "out.txt");
    await writeFile(path, "alpha\n");

    const result = await executeRealtimeWrite({ path, content: "beta\n", mode: "append" });

    expect(result.mode).toBe("append");
    expect(result.bytesWritten).toBe(5);
    await expect(readFile(path, "utf8")).resolves.toBe("alpha\nbeta\n");
  });

  it("creates parent directories", async () => {
    const dir = await tempDir();
    const path = join(dir, "nested/sub/out.txt");
    const result = await executeRealtimeWrite({ path, content: "hi" });
    expect(result.bytesWritten).toBe(2);
    await expect(readFile(path, "utf8")).resolves.toBe("hi");
  });

  it("rejects empty paths", async () => {
    await expect(executeRealtimeWrite({ path: "", content: "x" })).rejects.toThrow(/path is required/);
  });
});
