import { mkdtemp, writeFile, appendFile, truncate, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { PiSessionTailWatcher, type PiSessionTailEntry } from "./pi-session-tail-watcher.js";

describe("PiSessionTailWatcher", () => {
  let dir: string;
  let filePath: string;
  let entries: PiSessionTailEntry[][];
  let errors: unknown[];
  let watcher: PiSessionTailWatcher | undefined;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "pi-session-tail-"));
    filePath = join(dir, "session.jsonl");
    entries = [];
    errors = [];
  });

  afterEach(async () => {
    await watcher?.stop();
    watcher = undefined;
    await rm(dir, { recursive: true, force: true });
  });

  async function startWatcher(
    initial: string,
    options?: { startAt?: "eof" | "beginning"; onTruncate?: () => void | Promise<void> },
  ): Promise<void> {
    await writeFile(filePath, initial, "utf8");
    watcher = new PiSessionTailWatcher(
      filePath,
      (batch) => { entries.push(batch); },
      (error) => { errors.push(error); },
      options,
    );
    await watcher.start();
  }

  async function waitForBatches(target: number, timeoutMs = 1500): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (entries.length < target && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  }

  function line(entry: PiSessionTailEntry): string {
    return JSON.stringify(entry) + "\n";
  }

  it("starts at EOF by default and does not replay existing entries", async () => {
    await startWatcher(line({ id: "old-1", message: { role: "user" } }));
    // No new writes; give the watcher a beat in case it tried to read.
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(entries).toEqual([]);
  });

  it("emits entries that are appended after start", async () => {
    await startWatcher(line({ id: "old-1", message: { role: "user" } }));
    await appendFile(filePath, line({ id: "new-1", message: { role: "user" } }));
    await waitForBatches(1);
    expect(entries.flat().map((entry) => entry.id)).toEqual(["new-1"]);
  });

  it("batches multiple lines from a single write into one callback", async () => {
    await startWatcher("");
    await appendFile(
      filePath,
      line({ id: "u1", message: { role: "user" } }) +
        line({ id: "a1", message: { role: "assistant" } }),
    );
    await waitForBatches(1);
    expect(entries.length).toBe(1);
    expect(entries[0].map((entry) => entry.id)).toEqual(["u1", "a1"]);
  });

  it("starts at the beginning when startAt='beginning'", async () => {
    await startWatcher(line({ id: "boot", message: { role: "user" } }), { startAt: "beginning" });
    await waitForBatches(1);
    expect(entries.flat().map((entry) => entry.id)).toEqual(["boot"]);
  });

  it("skips malformed lines without aborting the batch", async () => {
    await startWatcher("");
    await appendFile(filePath, "{not json\n" + line({ id: "ok", message: { role: "assistant" } }));
    await waitForBatches(1);
    expect(entries.flat().map((entry) => entry.id)).toEqual(["ok"]);
  });

  it("retains incomplete trailing lines until the newline arrives", async () => {
    await startWatcher("");
    await appendFile(filePath, "{\"id\":\"split\",\"message\":{\"role\":\"user");
    await new Promise((resolve) => setTimeout(resolve, 80));
    expect(entries).toEqual([]);
    await appendFile(filePath, "\"}}\n");
    await waitForBatches(1);
    expect(entries.flat().map((entry) => entry.id)).toEqual(["split"]);
  });

  it("resets after truncation and suppresses the next emit so a compaction rewrite isn't replayed", async () => {
    await startWatcher("");
    await appendFile(filePath, line({ id: "before-trunc", message: { role: "user" } }));
    await waitForBatches(1);
    expect(entries.flat().map((entry) => entry.id)).toEqual(["before-trunc"]);

    // Pi compaction style: truncate file then re-write a fresh prefix.
    await truncate(filePath, 0);
    await new Promise((resolve) => setTimeout(resolve, 80));
    await writeFile(filePath, line({ id: "rewritten-1", message: { role: "assistant" } }));
    await new Promise((resolve) => setTimeout(resolve, 150));
    // First batch after truncation is suppressed, nothing should land yet.
    expect(entries.length).toBe(1);

    // Subsequent appends should be emitted normally.
    await appendFile(filePath, line({ id: "post-trunc", message: { role: "user" } }));
    await waitForBatches(2);
    expect(entries[1].map((entry) => entry.id)).toEqual(["post-trunc"]);
  });

  it("invokes onTruncate when the file shrinks below the cursor", async () => {
    const truncations: number[] = [];
    await startWatcher("", { onTruncate: () => { truncations.push(Date.now()); } });
    await appendFile(filePath, line({ id: "before-trunc", message: { role: "user" } }));
    await waitForBatches(1);
    await truncate(filePath, 0);
    await new Promise((resolve) => setTimeout(resolve, 80));
    await writeFile(filePath, line({ id: "rewritten", message: { role: "assistant" } }));
    await new Promise((resolve) => setTimeout(resolve, 150));
    expect(truncations.length).toBeGreaterThanOrEqual(1);
    expect(errors).toEqual([]);
  });

  it("routes onTruncate failures to onError without tearing down the tail", async () => {
    const boom = new Error("onTruncate exploded");
    await startWatcher("", { onTruncate: () => { throw boom; } });
    await appendFile(filePath, line({ id: "u1", message: { role: "user" } }));
    await waitForBatches(1);
    await truncate(filePath, 0);
    await new Promise((resolve) => setTimeout(resolve, 80));
    await writeFile(filePath, line({ id: "rewritten", message: { role: "assistant" } }));
    await new Promise((resolve) => setTimeout(resolve, 150));
    expect(errors).toContain(boom);
    // Tail still works after the callback throws.
    await appendFile(filePath, line({ id: "post-trunc", message: { role: "user" } }));
    await waitForBatches(2);
    expect(entries[1].map((entry) => entry.id)).toEqual(["post-trunc"]);
  });

  it("stops emitting after stop()", async () => {
    await startWatcher("");
    await watcher!.stop();
    watcher = undefined;
    await appendFile(filePath, line({ id: "after-stop", message: { role: "user" } }));
    await new Promise((resolve) => setTimeout(resolve, 120));
    expect(entries).toEqual([]);
    expect(errors).toEqual([]);
  });
});
