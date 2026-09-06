import { EventEmitter } from "node:events";
import { describe, expect, it } from "vitest";
import type { PickyAgentSession } from "../protocol.js";
import { awaitPickleSessionTerminal } from "./pickle-terminal-waiter.js";

function session(overrides: Partial<PickyAgentSession> = {}): PickyAgentSession {
  return {
    id: "pickle-1",
    title: "Pickle",
    status: "running",
    createdAt: "2026-05-01T00:00:00.000Z",
    updatedAt: "2026-05-01T00:00:00.000Z",
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
    ...overrides,
  } as PickyAgentSession;
}

class FakeSource extends EventEmitter {
  constructor(private readonly sessions: Map<string, PickyAgentSession>) { super(); }
  get(sessionId: string): PickyAgentSession | undefined { return this.sessions.get(sessionId); }
}

describe("awaitPickleSessionTerminal", () => {
  it("replies immediately when the session is already terminal", () => {
    const source = new FakeSource(new Map([["pickle-1", session({ status: "completed" })]]));
    const socket = new EventEmitter();
    const replies: PickyAgentSession[] = [];

    awaitPickleSessionTerminal(source, socket, "pickle-1", (value) => replies.push(value));

    expect(replies.map((value) => value.status)).toEqual(["completed"]);
    expect(source.listenerCount("sessionProjectionTransaction")).toBe(0);
  });

  it("replies once on the first terminal commit for that session and then unsubscribes", () => {
    const running = session();
    const source = new FakeSource(new Map([["pickle-1", running]]));
    const socket = new EventEmitter();
    const replies: PickyAgentSession[] = [];

    awaitPickleSessionTerminal(source, socket, "pickle-1", (value) => replies.push(value));
    source.emit("sessionProjectionTransaction", "pickle-2", running, session({ id: "pickle-2", status: "completed" }));
    source.emit("sessionProjectionTransaction", "pickle-1", running, session({ status: "running", lastSummary: "still going" }));
    expect(replies).toEqual([]);

    source.emit("sessionProjectionTransaction", "pickle-1", running, session({ status: "failed" }));
    source.emit("sessionProjectionTransaction", "pickle-1", running, session({ status: "failed" }));

    expect(replies.map((value) => value.status)).toEqual(["failed"]);
    expect(source.listenerCount("sessionProjectionTransaction")).toBe(0);
    expect(socket.listenerCount("close")).toBe(0);
  });

  it("stops listening when the socket closes before the session finishes", () => {
    const source = new FakeSource(new Map([["pickle-1", session()]]));
    const socket = new EventEmitter();
    const replies: PickyAgentSession[] = [];

    awaitPickleSessionTerminal(source, socket, "pickle-1", (value) => replies.push(value));
    socket.emit("close");
    source.emit("sessionProjectionTransaction", "pickle-1", session(), session({ status: "completed" }));

    expect(replies).toEqual([]);
    expect(source.listenerCount("sessionProjectionTransaction")).toBe(0);
  });

  it("rejects unknown sessions", () => {
    const source = new FakeSource(new Map());
    expect(() => awaitPickleSessionTerminal(source, new EventEmitter(), "missing", () => undefined)).toThrow(/Unknown session/);
  });
});
