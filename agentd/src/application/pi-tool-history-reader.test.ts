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
  it("preserves exact checkbox and free-text answers without changing flattened result text", async () => {
    const value = { choices: ["one, two", "three|four", "🧪"], notes: "line one\nline two\t| exact", empty: "" };
    const saved = result("User response: flattened, unchanged");
    const record = { ...saved, message: { ...saved.message, toolName: "ask_user_question", details: { value, cancelled: false, diagnostic: "private", data: "private-binary" } } };
    const questionCall = call(); questionCall.message.content[0].name = "ask_user_question";
    const path = await fixture(line(questionCall) + line(record));
    const reader = new PiToolHistoryReader();
    const page = await reader.read(path, "call", "result");
    expect(page.text).toBe("User response: flattened, unchanged");
    expect(JSON.parse(page.structuredResult!)).toEqual({ value, cancelled: false });
    expect(await reader.read(path, "call", "arguments")).toEqual({ status: "ready", text: JSON.stringify({ path: "/tmp/file" }, null, 2) });
  });
  it("reports cancellation without inventing an answer", async () => {
    const saved = result("The question form was dismissed.");
    const record = { ...saved, message: { ...saved.message, toolName: "ask_user_question", details: { cancelled: true } } };
    const page = await new PiToolHistoryReader().read(await fixture(line(call()) + line(record)), "call", "result");
    expect(page).toEqual({ status: "ready", text: "The question form was dismissed.", structuredResult: '{"value":null,"cancelled":true}' });
  });
  it("sends structured answers only on the first result page", async () => {
    const text = "x".repeat(40000);
    const saved = result(text);
    const record = { ...saved, message: { ...saved.message, toolName: "ask_user_question", details: { value: ["a", "b"], cancelled: false } } };
    const path = await fixture(line(call()) + line(record));
    const reader = new PiToolHistoryReader();
    const first = await reader.read(path, "call", "result");
    expect(JSON.parse(first.structuredResult!)).toEqual({ value: ["a", "b"], cancelled: false });
    expect(first.nextCursor).toBeTruthy();
    const second = await reader.read(path, "call", "result", first.nextCursor);
    expect(second.structuredResult).toBeUndefined();
    expect(first.text! + second.text!).toBe(text);
  });
  it.each([16383, 16384, 16385])("bounds encoded answers at 16384 UTF-16 units (size %i)", async (size) => {
    // The JSON wrapper occupies 30 units; emoji occupies two, and the escaped newline two.
    const value = "🧪\n" + "x".repeat(size - 34);
    const saved = result("unchanged");
    const record = { ...saved, message: { ...saved.message, toolName: "ask_user_question", details: { value, cancelled: false } } };
    const page = await new PiToolHistoryReader().read(await fixture(line(call()) + line(record)), "call", "result");
    expect(page.text).toBe("unchanged");
    if (size <= 16384) {
      expect(page.structuredResult?.length).toBe(size);
      expect(JSON.parse(page.structuredResult!).value).toBe(value);
    } else {
      expect(page.structuredResult).toBeUndefined();
    }
  });
  it("omits unrelated tool details and question error metadata", async () => {
    const saved = result("unchanged");
    for (const message of [
      { ...saved.message, details: { value: "private", cancelled: false } },
      { ...saved.message, toolName: "ask_user_question", details: { error: "private" } },
      { ...saved.message, toolName: "ask_user_question" },
    ]) {
      const page = await new PiToolHistoryReader().read(await fixture(line(call()) + line({ ...saved, message })), "call", "result");
      expect(page).toEqual({ status: "ready", text: "unchanged" });
    }
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
    expect(combined).toBe(text);
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
  it("renders ordered text blocks verbatim without outer error metadata", async () => {
    const saved = result('first\n"quoted"\tvalue');
    saved.message.isError = true;
    saved.message.content.push({ type: "text", text: "second\nline" });
    const record = { ...saved, message: { ...saved.message, details: { diagnostic: "hidden metadata" } } };
    const page = await new PiToolHistoryReader().read(await fixture(line(call()) + line(record)), "call", "result");
    expect(page).toEqual({ status: "ready", text: 'first\n"quoted"\tvalue\n\nsecond\nline' });
  });
  it("preserves non-text content in order while omitting nested attachments", async () => {
    const saved = result("before");
    const content = [
      ...saved.message.content,
      { type: "resource", resource: { uri: "file:///report", text: "report body", blob: "secret-blob" } },
      { type: "audio", mimeType: "audio/wav", data: "secret-audio" },
      { type: "link", url: "data:image/png;base64,secret-inline" },
      { type: "text", text: "after" },
    ];
    const record = { ...saved, message: { ...saved.message, content } };
    const page = await new PiToolHistoryReader().read(await fixture(line(call()) + line(record)), "call", "result");
    const blocks = page.text!.split("\n\n");
    expect(blocks[0]).toBe("before");
    expect(JSON.parse(blocks[1])).toEqual({ type: "resource", resource: { uri: "file:///report", text: "report body", blob: "[attachment omitted]" } });
    expect(JSON.parse(blocks[2])).toEqual({ type: "audio", mimeType: "audio/wav", data: "[attachment omitted]" });
    expect(JSON.parse(blocks[3])).toEqual({ type: "link", url: "[attachment omitted]" });
    expect(blocks[4]).toBe("after");
    expect(page.attachmentsOmitted).toBe(true);
    expect(page.text).not.toContain("secret-");
  });
  it("returns empty content without exposing outer metadata", async () => {
    const saved = result("");
    saved.message.content = [];
    expect(await new PiToolHistoryReader().read(await fixture(line(call()) + line(saved)), "call", "result"))
      .toEqual({ status: "ready", text: "" });
  });
  it("omits embedded image data while preserving text and image metadata", async () => {
    const saved = result("kept"); saved.message.content.push({ type: "image", mimeType: "image/png", data: "secret-base64" } as never);
    const reader = new PiToolHistoryReader();
    const page = await reader.read(await fixture(line(call()) + line(saved)), "call", "result");
    expect(page.attachmentsOmitted).toBe(true); expect(page.text).toContain("image/png"); expect(page.text).not.toContain("secret-base64"); expect(page.text).toContain("kept");
  });
});
