import { describe, expect, it } from "vitest";
import type { PickyAgentSession } from "../protocol.js";
import { createPickyAbortPickleTool, createPickyPickleSessionsTool, createPickyStartPickleTool, createPickySteerPickleTool, type PickyHandoffRequest } from "./handoff-tool.js";

describe("handoff tools", () => {
  it("passes an optional cwd override to the handoff callback and result details", async () => {
    let received: PickyHandoffRequest | undefined;
    const tool = createPickyStartPickleTool(async (request) => {
      received = request;
      return { sessionId: "session-1", title: request.title, cwd: request.cwd };
    });

    const result = await tool.execute(
      "tool-1",
      { title: "피클 조사", instructions: "Inspect this repo", cwd: "  /tmp/override-project  " } as never,
      undefined,
      undefined,
      {} as never,
    );

    expect(received).toMatchObject({ title: "피클 조사", instructions: "Inspect this repo", cwd: "/tmp/override-project" });
    expect(result.details).toMatchObject({ sessionId: "session-1", title: "피클 조사", cwd: "/tmp/override-project" });
  });

  it("guides Picky handoffs toward compact delta-first instructions", () => {
    const tool = createPickyStartPickleTool(async (request) => ({ sessionId: "session-1", title: request.title, cwd: request.cwd }));
    const definition = tool as unknown as { promptGuidelines?: string[]; parameters?: unknown };
    const guidelines = definition.promptGuidelines?.join("\n") ?? "";
    const parameters = JSON.stringify(definition.parameters);

    expect(guidelines).toContain("Deltas only");
    expect(guidelines).toContain("picky_steer_pickle");
    expect(parameters).toContain("Compact delta-first brief");
    expect(parameters).toContain("~300 chars");
    expect(parameters).toContain("No full prompts");
  });

  it("guides Pickle steering toward delta-only messages", () => {
    const tool = createPickySteerPickleTool(async () => makeSession(1));
    const definition = tool as unknown as { promptGuidelines?: string[]; parameters?: unknown };
    const guidelines = definition.promptGuidelines?.join("\n") ?? "";
    const parameters = JSON.stringify(definition.parameters);

    expect(guidelines).toContain("Delta only");
    expect(guidelines).toContain("no full-task restate");
    expect(parameters).toContain("Delta-only steering instruction");
    expect(parameters).toContain("Do not restate the whole task");
  });

  it("caps Pickle session list requests to one small page without exposing totals", async () => {
    const sessions = Array.from({ length: 25 }, (_, index) => makeSession(index + 1));
    const tool = createPickyPickleSessionsTool(() => sessions);

    const result = await tool.execute("tool-1", { limit: 50 } as never, undefined, undefined, {} as never);
    const details = result.details as { sessions: Array<{ id: string }>; page: number; pageSize: number; hasMore: boolean; nextPage?: number; total?: number; omitted?: number };

    expect(details.sessions).toHaveLength(10);
    expect(details.sessions.map((session) => session.id)).toEqual(["pickle-1", "pickle-2", "pickle-3", "pickle-4", "pickle-5", "pickle-6", "pickle-7", "pickle-8", "pickle-9", "pickle-10"]);
    expect(details).toMatchObject({ page: 1, pageSize: 10, hasMore: true, nextPage: 2 });
    expect(details.total).toBeUndefined();
    expect(details.omitted).toBeUndefined();
    const content = result.content[0];
    expect(content?.type).toBe("text");
    if (content?.type !== "text") throw new Error("expected text content");
    expect(content.text).toContain("more available, request page 2");
    expect(content.text).not.toContain("15 omitted");
  });

  it("returns subsequent Pickle session pages with the same maximum page size", async () => {
    const sessions = Array.from({ length: 25 }, (_, index) => makeSession(index + 1));
    const tool = createPickyPickleSessionsTool(() => sessions);

    const result = await tool.execute("tool-1", { page: 2, limit: 50 } as never, undefined, undefined, {} as never);
    const details = result.details as { sessions: Array<{ id: string }>; page: number; pageSize: number; hasMore: boolean; nextPage?: number };

    expect(details.sessions).toHaveLength(10);
    expect(details.sessions.map((session) => session.id)).toEqual(["pickle-11", "pickle-12", "pickle-13", "pickle-14", "pickle-15", "pickle-16", "pickle-17", "pickle-18", "pickle-19", "pickle-20"]);
    expect(details).toMatchObject({ page: 2, pageSize: 10, hasMore: true, nextPage: 3 });
  });

  it("paginates Pickle sessions after filtering terminal sessions", async () => {
    const sessions = [
      makeSession(1, "completed"),
      makeSession(2, "running"),
      makeSession(3, "failed"),
      makeSession(4, "waiting_for_input"),
      makeSession(5, "cancelled"),
      makeSession(6, "blocked"),
    ];
    const tool = createPickyPickleSessionsTool(() => sessions);

    const result = await tool.execute("tool-1", { includeTerminal: false, limit: 2 } as never, undefined, undefined, {} as never);
    const details = result.details as { sessions: Array<{ id: string }>; pageSize: number; hasMore: boolean; nextPage?: number };

    expect(details.sessions.map((session) => session.id)).toEqual(["pickle-2", "pickle-4"]);
    expect(details).toMatchObject({ pageSize: 2, hasMore: true, nextPage: 2 });
  });

  it("sends Pickle messages through the steering tool", async () => {
    let received: { sessionId: string; message: string } | undefined;
    const tool = createPickySteerPickleTool(async (request) => {
      received = request;
      return makeSession(7, "running");
    });

    const result = await tool.execute("tool-1", { sessionId: "pickle-7", message: "stay focused" } as never, undefined, undefined, {} as never);

    expect(received).toEqual({ sessionId: "pickle-7", message: "stay focused" });
    expect(result.content[0]).toMatchObject({ type: "text" });
    if (result.content[0]?.type !== "text") throw new Error("expected text content");
    expect(result.content[0].text).toContain("Steering sent to Pickle");
  });

  it("aborts a Pickle through the abort tool and reports the cancelled status", async () => {
    let received: { sessionId: string } | undefined;
    const tool = createPickyAbortPickleTool(async (request) => {
      received = request;
      return makeSession(9, "cancelled");
    });

    const result = await tool.execute("tool-1", { sessionId: "pickle-9" } as never, undefined, undefined, {} as never);

    expect(received).toEqual({ sessionId: "pickle-9" });
    if (result.content[0]?.type !== "text") throw new Error("expected text content");
    expect(result.content[0].text).toContain("Pickle aborted");
    expect(result.content[0].text).toContain("cancelled");
    expect((result.details as { session: { status: string } }).session.status).toBe("cancelled");
  });

  it("requires explicit user intent before calling picky_abort_pickle", () => {
    const tool = createPickyAbortPickleTool(async () => makeSession(1, "cancelled"));
    const definition = tool as unknown as { name: string; promptGuidelines?: string[] };
    expect(definition.name).toBe("picky_abort_pickle");
    const guidelines = definition.promptGuidelines?.join("\n") ?? "";
    expect(guidelines).toContain("explicit");
    expect(guidelines).toContain("picky_pickle_sessions");
  });
});

function makeSession(index: number, status: PickyAgentSession["status"] = "running"): PickyAgentSession {
  return {
    id: `pickle-${index}`,
    title: `피클 작업 ${index}`,
    status,
    createdAt: `2026-05-02T18:${String(index).padStart(2, "0")}:00.000Z`,
    updatedAt: `2026-05-02T18:${String(index).padStart(2, "0")}:30.000Z`,
    logs: [`log ${index}`],
    tools: [],
    artifacts: [],
    changedFiles: [],
  };
}
