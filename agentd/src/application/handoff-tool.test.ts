import { describe, expect, it } from "vitest";
import type { PickyAgentSession } from "../protocol.js";
import { createPickyHandoffTool, createPickySideSessionsTool, createPickySideSteerTool, type PickyHandoffRequest } from "./handoff-tool.js";

describe("handoff tools", () => {
  it("passes an optional cwd override to the handoff callback and result details", async () => {
    let received: PickyHandoffRequest | undefined;
    const tool = createPickyHandoffTool(async (request) => {
      received = request;
      return { sessionId: "session-1", title: request.title, cwd: request.cwd };
    });

    const result = await tool.execute(
      "tool-1",
      { title: "사이드 조사", instructions: "Inspect this repo", cwd: "  /tmp/override-project  " } as never,
      undefined,
      undefined,
      {} as never,
    );

    expect(received).toMatchObject({ title: "사이드 조사", instructions: "Inspect this repo", cwd: "/tmp/override-project" });
    expect(result.details).toMatchObject({ sessionId: "session-1", title: "사이드 조사", cwd: "/tmp/override-project" });
  });

  it("guides main-agent handoffs toward compact delta-first instructions", () => {
    const tool = createPickyHandoffTool(async (request) => ({ sessionId: "session-1", title: request.title, cwd: request.cwd }));
    const definition = tool as unknown as { promptGuidelines?: string[]; parameters?: unknown };
    const guidelines = definition.promptGuidelines?.join("\n") ?? "";
    const parameters = JSON.stringify(definition.parameters);

    expect(guidelines).toContain("compact, action-oriented brief");
    expect(guidelines).toContain("Do not paste the full current prompt");
    expect(guidelines).toContain("picky_side_steer");
    expect(parameters).toContain("Compact delta-first brief");
    expect(parameters).toContain("Do not paste full prompts");
  });

  it("guides side steering toward delta-only messages", () => {
    const tool = createPickySideSteerTool(async () => makeSession(1));
    const definition = tool as unknown as { promptGuidelines?: string[]; parameters?: unknown };
    const guidelines = definition.promptGuidelines?.join("\n") ?? "";
    const parameters = JSON.stringify(definition.parameters);

    expect(guidelines).toContain("new delta instruction");
    expect(guidelines).toContain("do not restate the whole task");
    expect(parameters).toContain("Delta-only steering instruction");
    expect(parameters).toContain("Do not restate the whole task");
  });

  it("caps side-session list requests to one small page without exposing totals", async () => {
    const sessions = Array.from({ length: 25 }, (_, index) => makeSession(index + 1));
    const tool = createPickySideSessionsTool(() => sessions);

    const result = await tool.execute("tool-1", { limit: 50 } as never, undefined, undefined, {} as never);
    const details = result.details as { sessions: Array<{ id: string }>; page: number; pageSize: number; hasMore: boolean; nextPage?: number; total?: number; omitted?: number };

    expect(details.sessions).toHaveLength(10);
    expect(details.sessions.map((session) => session.id)).toEqual(["side-1", "side-2", "side-3", "side-4", "side-5", "side-6", "side-7", "side-8", "side-9", "side-10"]);
    expect(details).toMatchObject({ page: 1, pageSize: 10, hasMore: true, nextPage: 2 });
    expect(details.total).toBeUndefined();
    expect(details.omitted).toBeUndefined();
    const content = result.content[0];
    expect(content?.type).toBe("text");
    if (content?.type !== "text") throw new Error("expected text content");
    expect(content.text).toContain("more available, request page 2");
    expect(content.text).not.toContain("15 omitted");
  });

  it("returns subsequent side-session pages with the same maximum page size", async () => {
    const sessions = Array.from({ length: 25 }, (_, index) => makeSession(index + 1));
    const tool = createPickySideSessionsTool(() => sessions);

    const result = await tool.execute("tool-1", { page: 2, limit: 50 } as never, undefined, undefined, {} as never);
    const details = result.details as { sessions: Array<{ id: string }>; page: number; pageSize: number; hasMore: boolean; nextPage?: number };

    expect(details.sessions).toHaveLength(10);
    expect(details.sessions.map((session) => session.id)).toEqual(["side-11", "side-12", "side-13", "side-14", "side-15", "side-16", "side-17", "side-18", "side-19", "side-20"]);
    expect(details).toMatchObject({ page: 2, pageSize: 10, hasMore: true, nextPage: 3 });
  });

  it("paginates side sessions after filtering terminal sessions", async () => {
    const sessions = [
      makeSession(1, "completed"),
      makeSession(2, "running"),
      makeSession(3, "failed"),
      makeSession(4, "waiting_for_input"),
      makeSession(5, "cancelled"),
      makeSession(6, "blocked"),
    ];
    const tool = createPickySideSessionsTool(() => sessions);

    const result = await tool.execute("tool-1", { includeTerminal: false, limit: 2 } as never, undefined, undefined, {} as never);
    const details = result.details as { sessions: Array<{ id: string }>; pageSize: number; hasMore: boolean; nextPage?: number };

    expect(details.sessions.map((session) => session.id)).toEqual(["side-2", "side-4"]);
    expect(details).toMatchObject({ pageSize: 2, hasMore: true, nextPage: 2 });
  });

  it("sends side-agent messages through the steering tool", async () => {
    let received: { sessionId: string; message: string } | undefined;
    const tool = createPickySideSteerTool(async (request) => {
      received = request;
      return makeSession(7, "running");
    });

    const result = await tool.execute("tool-1", { sessionId: "side-7", message: "stay focused" } as never, undefined, undefined, {} as never);

    expect(received).toEqual({ sessionId: "side-7", message: "stay focused" });
    expect(result.content[0]).toMatchObject({ type: "text" });
    if (result.content[0]?.type !== "text") throw new Error("expected text content");
    expect(result.content[0].text).toContain("Steering sent to side agent");
  });
});

function makeSession(index: number, status: PickyAgentSession["status"] = "running"): PickyAgentSession {
  return {
    id: `side-${index}`,
    title: `사이드 작업 ${index}`,
    status,
    createdAt: `2026-05-02T18:${String(index).padStart(2, "0")}:00.000Z`,
    updatedAt: `2026-05-02T18:${String(index).padStart(2, "0")}:30.000Z`,
    logs: [`log ${index}`],
    tools: [],
    artifacts: [],
    changedFiles: [],
  };
}
