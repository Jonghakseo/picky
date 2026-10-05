/**
 * The phone's home screen. Order and preview are the whole screen: if a room
 * sorts wrong or previews the wrong line, the user opens the wrong Pickle.
 */
import { describe, expect, it } from "vitest";
import type { PickyAgentSession } from "../protocol.js";
import { MAIN_ROOM_ID } from "../remote/constants.js";
import type { HubOverlay } from "./hub-link.js";
import { buildRoomList, MAIN_ROOM_TITLE, truncatePreview, type MainRoomInput } from "./rooms.js";

const IDLE_MAIN: MainRoomInput = { busy: false, pendingQuestion: false, unread: false };

function session(id: string, overrides: Partial<PickyAgentSession> = {}): PickyAgentSession {
  return {
    id,
    title: id,
    status: "running",
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

function overlay(overrides: Partial<Omit<HubOverlay, "type">> = {}): HubOverlay {
  return {
    type: "hub.overlay",
    activeSessionIds: [],
    archivedSessionIds: [],
    unreadSessionIds: [],
    groups: [],
    folders: { pinned: [], recent: [] },
    ...overrides,
  };
}

function build(sessions: PickyAgentSession[], options: { overlay?: HubOverlay; main?: MainRoomInput } = {}) {
  return buildRoomList({
    sessions: new Map(sessions.map((item) => [item.id, item])),
    main: options.main ?? IDLE_MAIN,
    ...(options.overlay ? { overlay: options.overlay } : {}),
  });
}

describe("room ordering", () => {
  it("keeps the main room first, then pinned, then most recent activity", () => {
    const rooms = build([
      session("old", { updatedAt: "2026-01-01T00:00:00Z" }),
      session("new", { updatedAt: "2026-01-03T00:00:00Z" }),
      session("pinned", { updatedAt: "2026-01-02T00:00:00Z", pinned: true }),
    ]).rooms;

    expect(rooms.map((room) => room.id)).toEqual([MAIN_ROOM_ID, "pinned", "new", "old"]);
    expect(rooms[0].kind).toBe("main");
    expect(rooms[0].title).toBe(MAIN_ROOM_TITLE);
  });

  it("orders two pinned rooms by recent activity as well", () => {
    const rooms = build([
      session("a", { updatedAt: "2026-01-01T00:00:00Z", pinned: true }),
      session("b", { updatedAt: "2026-01-05T00:00:00Z", pinned: true }),
    ]).rooms;
    expect(rooms.map((room) => room.id)).toEqual([MAIN_ROOM_ID, "b", "a"]);
  });
});

describe("what the HUD overlay decides", () => {
  it("shows the dock and the archive, and nothing the HUD is hiding", () => {
    const result = build(
      [session("docked"), session("filed"), session("hidden")],
      { overlay: overlay({ activeSessionIds: ["docked"], archivedSessionIds: ["filed"] }) },
    );
    expect(result.rooms.map((room) => room.id)).toEqual([MAIN_ROOM_ID, "docked", "filed"]);
    expect(result.rooms.find((room) => room.id === "filed")?.archived).toBe(true);
    expect(result.rooms.find((room) => room.id === "docked")?.archived).toBe(false);
  });

  it("carries unread, groups and folders through", () => {
    const result = build([session("s1")], {
      overlay: overlay({
        activeSessionIds: ["s1"],
        unreadSessionIds: ["s1"],
        groups: [{ id: "g1", name: "작업", color: "blue", memberIds: ["s1"] }],
        folders: { pinned: ["/work"], recent: ["/tmp"] },
      }),
    });
    const room = result.rooms.find((item) => item.id === "s1");
    expect(room?.unread).toBe(true);
    expect(room?.groupIds).toEqual(["g1"]);
    expect(result.groups).toEqual([{ id: "g1", name: "작업", color: "blue" }]);
    expect(result.folders).toEqual({ pinned: ["/work"], recent: ["/tmp"] });
  });

  it("falls back to the session's own archived flag before the overlay arrives", () => {
    const rooms = build([session("s1", { archived: true })]).rooms;
    expect(rooms.find((room) => room.id === "s1")?.archived).toBe(true);
  });

  it("never lists a session twice when it is in both overlay lists", () => {
    const result = build([session("s1")], {
      overlay: overlay({ activeSessionIds: ["s1"], archivedSessionIds: ["s1"] }),
    });
    expect(result.rooms.filter((room) => room.id === "s1")).toHaveLength(1);
  });
});

describe("preview priority", () => {
  const withEverything = (extra: Partial<PickyAgentSession>) => session("s1", {
    lastSummary: "summary line",
    finalAnswer: "final answer",
    messages: [{ id: "m1", kind: "agent_text", createdAt: "2026-01-01T00:00:00Z", text: "last reply" }],
    ...extra,
  } as Partial<PickyAgentSession>);

  const previewOf = (item: PickyAgentSession) => build([item]).rooms.find((room) => room.id === "s1")?.preview;

  it("shows a pending question before anything else", () => {
    const room = build([withEverything({
      pendingExtensionUiRequest: { id: "r1", sessionId: "s1", createdAt: "2026-01-01T00:00:00Z", requestId: "r1", method: "confirm", prompt: "이대로 진행할까요?" },
    } as Partial<PickyAgentSession>)]).rooms.find((item) => item.id === "s1");
    expect(room?.preview).toBe("이대로 진행할까요?");
    expect(room?.pendingQuestion).toBe(true);
    expect(room?.status).toBe("running");
  });

  it("ignores a notify request, which does not block on the user", () => {
    const room = build([withEverything({
      pendingExtensionUiRequest: { id: "r1", sessionId: "s1", createdAt: "2026-01-01T00:00:00Z", requestId: "r1", method: "notify", prompt: "저장했어요" },
    } as Partial<PickyAgentSession>)]).rooms.find((item) => item.id === "s1");
    expect(room?.preview).toBe("last reply");
    expect(room?.pendingQuestion).toBe(false);
  });

  it("shows the newest message, never the daemon's status line", () => {
    // Seen on a phone: every running Pickle read "Agent started".
    expect(previewOf(withEverything({ lastSummary: "Agent started" }))).toBe("last reply");
    // A turn the agent has not answered yet shows what the user asked.
    expect(previewOf(session("s1", {
      status: "running",
      lastSummary: "Agent started",
      messages: [
        { id: "m1", kind: "agent_text", createdAt: "2026-01-01T00:00:00Z", text: "older reply" },
        { id: "m2", kind: "user_text", createdAt: "2026-01-01T00:01:00Z", text: "PR 올려 줘" },
        { id: "m3", kind: "agent_activity", createdAt: "2026-01-01T00:01:05Z" },
      ],
    } as Partial<PickyAgentSession>))).toBe("PR 올려 줘");
    // A summary-only projection has no journal; the final answer stands in.
    expect(previewOf(session("s1", { lastSummary: "Completed", finalAnswer: "final answer" } as Partial<PickyAgentSession>))).toBe("final answer");
    expect(previewOf(session("s1", { lastSummary: "Agent started" } as Partial<PickyAgentSession>))).toBeUndefined();
  });

  it("reads markdown as text", () => {
    expect(truncatePreview("**머지했어요.** [#5633](https://github.com/x/y/pull/5633)의 `main` 반영을 확인했어요"))
      .toBe("머지했어요. #5633의 main 반영을 확인했어요");
    expect(truncatePreview("## 결과\n- 첫째\n> 인용")).toBe("결과 첫째 인용");
  });

  it("collapses whitespace and cuts long text to one line", () => {
    expect(truncatePreview("  두\n줄짜리   요약  ")).toBe("두 줄짜리 요약");
    const long = truncatePreview("x".repeat(400));
    expect(long).toHaveLength(160);
    expect(long?.endsWith("…")).toBe(true);
    expect(truncatePreview("   ")).toBeUndefined();
    expect(truncatePreview(undefined)).toBeUndefined();
  });
});

describe("the main room", () => {
  it("waits for input, runs, or idles", () => {
    const statusOf = (main: MainRoomInput) => build([], { main }).rooms[0].status;
    expect(statusOf(IDLE_MAIN)).toBe("idle");
    expect(statusOf({ ...IDLE_MAIN, busy: true })).toBe("running");
    expect(statusOf({ ...IDLE_MAIN, busy: true, pendingQuestion: true })).toBe("waiting_for_input");
  });

  it("previews the question it is waiting on, otherwise its last reply", () => {
    expect(build([], { main: { ...IDLE_MAIN, pendingQuestion: true, questionPrompt: "어느 쪽으로 할까요?", lastAssistantText: "했어요" } })
      .rooms[0].preview).toBe("어느 쪽으로 할까요?");
    expect(build([], { main: { ...IDLE_MAIN, lastAssistantText: "했어요" } }).rooms[0].preview).toBe("했어요");
  });

  it("is never pinned, archived or grouped", () => {
    const main = build([session("s1", { pinned: true })]).rooms[0];
    expect({ pinned: main.pinned, archived: main.archived, groupIds: main.groupIds, backgroundTasks: main.backgroundTasks })
      .toEqual({ pinned: false, archived: false, groupIds: [], backgroundTasks: 0 });
  });
});

describe("background work", () => {
  it("reports the active root count so the phone can show the chip", () => {
    const rooms = build([session("s1", { asyncWorkSummary: { activeRootCount: 3 } } as Partial<PickyAgentSession>)]).rooms;
    expect(rooms.find((room) => room.id === "s1")?.backgroundTasks).toBe(3);
  });
});
