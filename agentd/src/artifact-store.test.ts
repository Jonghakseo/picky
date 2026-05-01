import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ArtifactStore } from "./artifact-store.js";
import { LogStore } from "./log-store.js";

describe("ArtifactStore", () => {
  it("writes, reads, and lists artifacts under injected app support root", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-artifacts-"));
    const store = new ArtifactStore(root);
    const artifact = await store.write("session-1", { id: "report", kind: "report", title: "Report", fileName: "report.md", content: "# Done" });

    expect(artifact.path).toContain(root);
    await expect(store.read("session-1", "report.md")).resolves.toEqual(Buffer.from("# Done"));
    await expect(store.list("session-1")).resolves.toEqual(["report.md"]);
  });

  it("rejects path traversal artifact names and unsafe session ids", async () => {
    const store = new ArtifactStore(await mkdtemp(join(tmpdir(), "picky-artifacts-")));
    await expect(store.write("session-1", { id: "evil", kind: "report", title: "Evil", fileName: "../evil", content: "no" })).rejects.toThrow(/Unsafe artifact path/);
    await expect(store.write("../session", { id: "evil", kind: "report", title: "Evil", fileName: "ok.md", content: "no" })).rejects.toThrow(/Unsafe path segment/);
  });
});

describe("LogStore", () => {
  it("appends, reads, and lists durable session logs", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-logs-"));
    const store = new LogStore(root);
    const path = await store.append("session-1", "hello");
    expect(path).toContain(root);
    await store.append("session-1", "world");
    expect(await store.read("session-1")).toContain("hello");
    expect(await store.read("session-1")).toContain("world");
    await expect(store.list()).resolves.toEqual(["session-1.log"]);
  });

  it("rejects unsafe log session ids", async () => {
    const store = new LogStore(await mkdtemp(join(tmpdir(), "picky-logs-")));
    await expect(store.append("../evil", "nope")).rejects.toThrow(/Unsafe artifact path|Unsafe path segment/);
  });
});
