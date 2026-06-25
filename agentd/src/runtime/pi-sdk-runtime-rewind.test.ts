import { SessionManager } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import { branchTranscriptFromEntries } from "./pi-sdk-runtime.js";

describe("branchTranscriptFromEntries", () => {
  it("preserves root->leaf order from a real SessionManager branch (guards against reverse)", () => {
    const session = SessionManager.inMemory("/tmp/project");
    session.appendMessage({ role: "user", content: "first", timestamp: 1 });
    session.appendMessage({ role: "user", content: "second", timestamp: 2 });
    session.appendMessage({ role: "user", content: "third", timestamp: 3 });

    const transcript = branchTranscriptFromEntries(session.getBranch());

    expect(transcript.map((message) => message.text)).toEqual(["first", "second", "third"]);
    expect(transcript.every((message) => message.role === "user")).toBe(true);
  });

  it("keeps only user/assistant message entries with non-empty text", () => {
    const entries = [
      { type: "message", message: { role: "user", content: "keep-user" } },
      { type: "message", message: { role: "assistant", content: [{ type: "text", text: "keep-assistant" }] } },
      { type: "message", message: { role: "assistant", content: [{ type: "toolCall", id: "x", name: "bash", arguments: {} }] } },
      { type: "compaction", summary: "ignored" },
      { type: "message", message: { role: "user", content: "   " } },
    ];

    expect(branchTranscriptFromEntries(entries)).toEqual([
      { role: "user", text: "keep-user" },
      { role: "assistant", text: "keep-assistant" },
    ]);
  });
});
