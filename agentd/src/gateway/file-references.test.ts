import { describe, expect, it } from "vitest";
import type { PickyAgentSession } from "../protocol.js";
import { extractFileReferences, localLinkTarget } from "./file-references.js";

function session(overrides: Partial<PickyAgentSession>): PickyAgentSession {
  return {
    id: "s1",
    title: "demo",
    status: "running",
    cwd: "/work/repo",
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00Z",
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
    messages: [],
    ...overrides,
  } as PickyAgentSession;
}

describe("link targets", () => {
  it("keeps bare paths and file: urls, drops http and other schemes", () => {
    expect(localLinkTarget("docs/plan.md")).toBe("docs/plan.md");
    expect(localLinkTarget("~/Downloads/a.png")).toBe("~/Downloads/a.png");
    expect(localLinkTarget("/etc/hosts")).toBe("/etc/hosts");
    expect(localLinkTarget("file:///work/repo/a%20b.md")).toBe("/work/repo/a b.md");
    expect(localLinkTarget("https://example.com/x")).toBeUndefined();
    expect(localLinkTarget("mailto:me@example.com")).toBeUndefined();
    expect(localLinkTarget("#section")).toBeUndefined();
  });
});

describe("session file references", () => {
  it("collects markdown links from messages, including relative and ~ paths", () => {
    const references = extractFileReferences(session({
      messages: [
        { id: "m1", kind: "agent_text", createdAt: "2026-01-01T00:00:00Z", text: "see [plan](docs/plan.md) and [log](<~/Library/Logs/a b.log>)" },
        { id: "m2", kind: "agent_text", createdAt: "2026-01-01T00:00:00Z", text: "also [site](https://example.com) which is not a file" },
      ],
    }));
    expect(references).toContain("docs/plan.md");
    expect(references).toContain("~/Library/Logs/a b.log");
    expect(references).not.toContain("https://example.com");
  });

  it("collects path arguments of tool calls", () => {
    const references = extractFileReferences(session({
      tools: [
        { toolCallId: "t1", name: "read", status: "succeeded", argsPreview: JSON.stringify({ file_path: "/work/repo/src/a.ts" }) },
        { toolCallId: "t2", name: "edit", status: "succeeded", argsPreview: JSON.stringify({ edits: [{ path: "src/b.ts" }] }) },
        { toolCallId: "t3", name: "grep", status: "succeeded", argsPreview: JSON.stringify({ paths: ["src/c.ts", "src/d.ts"] }) },
        { toolCallId: "t4", name: "vision", status: "succeeded", argsPreview: JSON.stringify({ imagePath: "shots/one.png" }) },
        { toolCallId: "t5", name: "bash", status: "succeeded", argsPreview: "not json" },
      ],
    }));
    expect(references).toEqual(expect.arrayContaining(["/work/repo/src/a.ts", "src/b.ts", "src/c.ts", "src/d.ts", "shots/one.png"]));
  });

  it("collects artifact and changed-file paths", () => {
    const references = extractFileReferences(session({
      artifacts: [{ id: "a1", kind: "report", title: "Report", path: "/work/repo/report.html", updatedAt: "2026-01-01T00:00:00Z" }],
      changedFiles: [{ path: "src/changed.ts", status: "modified" }],
    }));
    expect(references).toContain("/work/repo/report.html");
    expect(references).toContain("src/changed.ts");
  });

  it("does not invent references from a session with no file mentions", () => {
    expect(extractFileReferences(session({
      messages: [{ id: "m1", kind: "agent_text", createdAt: "2026-01-01T00:00:00Z", text: "all done" }],
    }))).toEqual([]);
  });
});
