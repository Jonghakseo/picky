import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { readPiTerminalSessionMessages } from "./pi-session-syncer.js";

describe("readPiTerminalSessionMessages todo state", () => {
  it("restores the latest trailing todo overlay state on the active Pi branch", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-pi-todo-sync-"));
    const sessionFile = join(dir, "session.jsonl");
    const updatedAt = Date.parse("2026-07-14T01:00:00.000Z");
    await writeFile(sessionFile, [
      JSON.stringify({ type: "session", version: 3, id: "pi-session", timestamp: "2026-07-14T00:59:00.000Z", cwd: "/tmp/project" }),
      JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-07-14T00:59:01.000Z", message: { role: "user", content: "Implement todo HUD" } }),
      JSON.stringify({ type: "message", id: "a1", parentId: "u1", timestamp: "2026-07-14T00:59:02.000Z", message: { role: "assistant", content: [{ type: "text", text: "Working" }] } }),
      JSON.stringify({
        type: "custom",
        customType: "todo-write-overlay-state",
        id: "todo-state-1",
        parentId: "a1",
        timestamp: "2026-07-14T01:00:00.000Z",
        data: {
          updatedAt,
          tasks: [
            { id: "todo-1", content: "Inspect protocol", status: "abandoned" },
            { id: "todo-2", content: "Implement HUD", status: "in_progress", activeForm: "Implementing HUD", notes: "Read-only" },
          ],
        },
      }),
    ].join("\n"));

    const result = await readPiTerminalSessionMessages(sessionFile);

    expect(result.activeLastMessageId).toBe("a1");
    expect(result.todoStateResolved).toBe(true);
    expect(result.todoState).toEqual({
      updatedAt: "2026-07-14T01:00:00.000Z",
      tasks: [
        { id: "todo-1", content: "Inspect protocol", status: "completed" },
        { id: "todo-2", content: "Implement HUD", status: "in_progress", activeForm: "Implementing HUD", notes: "Read-only" },
      ],
    });
  });

  it("ignores malformed todo overlay entries without disturbing message sync", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-pi-invalid-todo-sync-"));
    const sessionFile = join(dir, "session.jsonl");
    await writeFile(sessionFile, [
      JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-07-14T00:59:01.000Z", message: { role: "user", content: "Prompt" } }),
      JSON.stringify({ type: "custom", customType: "todo-write-overlay-state", id: "todo-invalid", parentId: "u1", data: { updatedAt: "invalid", tasks: [{ id: "todo-1", content: "Missing status" }] } }),
      JSON.stringify({ type: "message", id: "a1", parentId: "todo-invalid", timestamp: "2026-07-14T00:59:02.000Z", message: { role: "assistant", content: [{ type: "text", text: "Answer" }] } }),
    ].join("\n"));

    const result = await readPiTerminalSessionMessages(sessionFile);

    expect(result.todoStateResolved).toBe(false);
    expect(result.todoState).toBeUndefined();
    expect(result.messages.map((message) => message.text)).toEqual(["Prompt", "Answer"]);
  });

  it("resolves a todo-free active branch as an authoritative clear", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-pi-todo-branch-clear-"));
    const sessionFile = join(dir, "session.jsonl");
    await writeFile(sessionFile, [
      JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-07-14T00:59:01.000Z", message: { role: "user", content: "Root" } }),
      JSON.stringify({ type: "message", id: "a1", parentId: "u1", timestamp: "2026-07-14T00:59:02.000Z", message: { role: "assistant", content: [{ type: "text", text: "Root answer" }] } }),
      JSON.stringify({ type: "custom", customType: "todo-write-overlay-state", id: "todo-old", parentId: "a1", data: { updatedAt: Date.parse("2026-07-14T00:59:03.000Z"), tasks: [{ id: "todo-1", content: "Old branch", status: "in_progress" }] } }),
      JSON.stringify({ type: "message", id: "u-old", parentId: "todo-old", timestamp: "2026-07-14T00:59:04.000Z", message: { role: "user", content: "Old branch prompt" } }),
      JSON.stringify({ type: "message", id: "u-new", parentId: "a1", timestamp: "2026-07-14T01:00:00.000Z", message: { role: "user", content: "New branch prompt" } }),
      JSON.stringify({ type: "message", id: "a-new", parentId: "u-new", timestamp: "2026-07-14T01:00:01.000Z", message: { role: "assistant", content: [{ type: "text", text: "New branch answer" }] } }),
    ].join("\n"));

    const result = await readPiTerminalSessionMessages(sessionFile);

    expect(result.activeLastMessageId).toBe("a-new");
    expect(result.todoStateResolved).toBe(true);
    expect(result.todoState).toBeUndefined();
    expect(result.messages.map((message) => message.text)).toEqual(["Root", "Root answer", "New branch prompt", "New branch answer"]);
  });
});
