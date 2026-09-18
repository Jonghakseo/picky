import { appendFile, mkdtemp, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { PiToolHistoryReader, TOOL_HISTORY_MAX_RECORD_BYTES } from "./pi-tool-history-reader.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))); });
const call = (id = "call", args: unknown = { path: "/tmp/file" }) => ({ type: "message", id: `a-${id}`, parentId: null, message: { role: "assistant", content: [{ type: "toolCall", id, name: "read", arguments: args }] } });
const result = (text: string, id = "call") => ({ type: "message", id: `r-${id}`, parentId: `a-${id}`, message: { role: "toolResult", toolCallId: id, toolName: "read", content: [{ type: "text", text }], isError: false } });
const line = (value: unknown) => JSON.stringify(value) + "\n";
async function fixture(contents: string) { const root = await mkdtemp(join(tmpdir(), "picky-detail-")); roots.push(root); const path = join(root, "session.jsonl"); await writeFile(path, contents); return path; }

describe("PiToolHistoryReader", () => {
  it("returns exact stored arguments and old-branch results beyond the preview", async () => {
    const path = await fixture(line(call()) + line(result("x".repeat(600) + "EXACT")) + line({ type: "message", id: "new-branch", parentId: null, message: { role: "user", content: "rewind" } }));
    const reader = new PiToolHistoryReader();
    expect(JSON.parse((await reader.read(path, "call", "arguments")).text!)).toEqual({ path: "/tmp/file" });
    expect((await reader.read(path, "call", "result")).text).toContain("EXACT");
  });
  it("retries an incomplete trailing line after append without caching absence", async () => {
    const saved = line(result("persisted later"));
    const path = await fixture(line(call()) + saved.slice(0, 20));
    const reader = new PiToolHistoryReader();
    expect(await reader.read(path, "call", "result")).toMatchObject({ status: "pending" });
    await appendFile(path, saved.slice(20));
    expect(await reader.read(path, "call", "result")).toMatchObject({ status: "ready", text: expect.stringContaining("persisted later") });
  });
  it("pages losslessly with bounded UTF-16 pages and bound opaque cursors", async () => {
    const text = "🧪".repeat(40000) + "TAIL";
    const path = await fixture(line(call()) + line(result(text)) + line(call("other")) + line(result("other", "other")));
    const reader = new PiToolHistoryReader();
    const first = await reader.read(path, "call", "result");
    expect(first.nextCursor).toBeTruthy();
    expect(await reader.read(path, "other", "result", first.nextCursor)).toMatchObject({ status: "unavailable" });
    expect(await reader.read(path, "call", "arguments", first.nextCursor)).toMatchObject({ status: "unavailable" });
    const otherPath = await fixture(line(call()) + line(result(text)));
    expect(await reader.read(otherPath, "call", "result", first.nextCursor)).toMatchObject({ status: "unavailable" });
    let page = first; let combined = "";
    do {
      expect(page.text!.length).toBeLessThanOrEqual(32768);
      expect(page.text).not.toMatch(/[\uD800-\uDBFF]$/);
      combined += page.text;
      if (!page.nextCursor) break;
      page = await reader.read(path, "call", "result", page.nextCursor);
    } while (true);
    expect(JSON.parse(combined).content).toEqual([{ type: "text", text }]);
  });
  it("invalidates cursors after replacement and truncation", async () => {
    const path = await fixture(line(call()) + line(result("x".repeat(40000))));
    const reader = new PiToolHistoryReader();
    const first = await reader.read(path, "call", "result");
    await writeFile(path + ".new", line(call()) + line(result("replacement")));
    await rename(path + ".new", path);
    expect(await reader.read(path, "call", "result", first.nextCursor)).toMatchObject({ status: "unavailable" });
    expect((await reader.read(path, "call", "result")).text).toContain("replacement");
    await writeFile(path, line(call()));
    expect(await reader.read(path, "call", "result")).toMatchObject({ status: "pending" });
  });
  it("fails closed for unknown, duplicate, malformed and oversized records", async () => {
    const reader = new PiToolHistoryReader();
    expect(await reader.read(await fixture(line(call())), "unknown", "result")).toMatchObject({ status: "pending" });
    expect(await reader.read(await fixture(line(call()) + line(call())), "call", "arguments")).toMatchObject({ status: "unavailable", reason: "ambiguousToolCall" });
    expect(await reader.read(await fixture(line(call()) + "{broken}\n"), "call", "arguments")).toMatchObject({ status: "unavailable", reason: "malformedRecord" });
    expect(await reader.read(await fixture("x".repeat(TOOL_HISTORY_MAX_RECORD_BYTES + 1)), "call", "arguments")).toMatchObject({ status: "unavailable", reason: "recordTooLarge" });
  });
  it("preserves image-shaped argument objects exactly", async () => {
    const args = { type: "image", mimeType: "image/png", data: "argument-value" };
    const page = await new PiToolHistoryReader().read(await fixture(line(call("call", args))), "call", "arguments");
    expect(JSON.parse(page.text!)).toEqual(args);
    expect(page.attachmentsOmitted).toBeUndefined();
  });
  it("omits embedded image data while preserving text and image metadata", async () => {
    const saved = result("kept"); saved.message.content.push({ type: "image", mimeType: "image/png", data: "secret-base64" } as never);
    const reader = new PiToolHistoryReader();
    const page = await reader.read(await fixture(line(call()) + line(saved)), "call", "result");
    expect(page.attachmentsOmitted).toBe(true); expect(page.text).toContain("image/png"); expect(page.text).not.toContain("secret-base64"); expect(page.text).toContain("kept");
  });
});
