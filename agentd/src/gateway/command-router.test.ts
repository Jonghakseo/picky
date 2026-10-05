/**
 * The routing table. Every command the phone can send ends up either as the
 * exact daemon command the HUD sends, or as a hub request for something only
 * the app owns. A wrong entry here is a phone button that silently does
 * nothing, or worse, the wrong thing.
 */
import { describe, expect, it } from "vitest";
import { RemoteCommandSchema, type RemoteCommand } from "../remote/protocol.js";
import { commandText, planCommand, roomIdForCommand, type CommandPlan } from "./command-router.js";

const SESSION = "s1";

function plan(command: RemoteCommand, text?: string): CommandPlan {
  return planCommand({ command, ...(text !== undefined ? { text } : {}) });
}

function daemonCommand(command: RemoteCommand): Record<string, unknown> {
  const result = plan(command);
  expect(result.target).toBe("daemon");
  if (result.target !== "daemon") throw new Error("not a daemon plan");
  expect(result.sessionId).toBe(SESSION);
  return result.command as unknown as Record<string, unknown>;
}

/** One case per command type; the last test proves none is missing. */
const CASES: Record<RemoteCommand["type"], () => void> = {
  "session.send": () => {
    expect(daemonCommand({ type: "session.send", sessionId: SESSION, text: "go", kind: "followUp" }))
      .toEqual({ type: "followUp", sessionId: SESSION, text: "go" });
    expect(daemonCommand({ type: "session.send", sessionId: SESSION, text: "stop that", kind: "steer" }))
      .toEqual({ type: "steer", sessionId: SESSION, text: "stop that" });
  },
  "session.schedule": () => {
    expect(daemonCommand({ type: "session.schedule", sessionId: SESSION, text: "later", delayMs: 60_000 }))
      .toEqual({ type: "scheduleMessage", sessionId: SESSION, text: "later", delayMs: 60_000 });
  },
  "session.abort": () => {
    expect(daemonCommand({ type: "session.abort", sessionId: SESSION, scope: "all" }))
      .toEqual({ type: "abort", sessionId: SESSION, scope: "all" });
  },
  "session.answer": () => {
    expect(daemonCommand({ type: "session.answer", sessionId: SESSION, requestId: "r1", value: { choice: 2 } }))
      .toEqual({ type: "answerExtensionUi", sessionId: SESSION, requestId: "r1", value: { choice: 2 } });
  },
  "session.queue.remove": () => {
    expect(daemonCommand({ type: "session.queue.remove", sessionId: SESSION, itemId: "q1" }))
      .toEqual({ type: "removeQueuedInput", sessionId: SESSION, itemId: "q1" });
  },
  "session.queue.edit": () => {
    expect(daemonCommand({ type: "session.queue.edit", sessionId: SESSION, itemId: "q1", text: "fixed" }))
      .toEqual({ type: "editQueuedFollowUp", sessionId: SESSION, itemId: "q1", text: "fixed" });
  },
  "session.queue.sendNow": () => {
    expect(daemonCommand({ type: "session.queue.sendNow", sessionId: SESSION, itemId: "q1" }))
      .toEqual({ type: "sendQueuedFollowUpNow", sessionId: SESSION, itemId: "q1" });
  },
  "session.queue.clear": () => {
    expect(daemonCommand({ type: "session.queue.clear", sessionId: SESSION, kind: "all" }))
      .toEqual({ type: "clearQueue", sessionId: SESSION, kind: "all" });
  },
  "session.scheduled.cancel": () => {
    expect(daemonCommand({ type: "session.scheduled.cancel", sessionId: SESSION, scheduledId: "d1" }))
      .toEqual({ type: "cancelScheduledMessage", sessionId: SESSION, scheduledId: "d1" });
  },
  "session.scheduled.sendNow": () => {
    expect(daemonCommand({ type: "session.scheduled.sendNow", sessionId: SESSION, scheduledId: "d1" }))
      .toEqual({ type: "sendScheduledMessageNow", sessionId: SESSION, scheduledId: "d1" });
  },
  "session.scheduled.edit": () => {
    expect(daemonCommand({ type: "session.scheduled.edit", sessionId: SESSION, scheduledId: "d1", text: "later text" }))
      .toEqual({ type: "editScheduledMessage", sessionId: SESSION, scheduledId: "d1", text: "later text" });
  },
  "session.setModel": () => {
    expect(daemonCommand({ type: "session.setModel", sessionId: SESSION, provider: "anthropic", modelId: "claude" }))
      .toEqual({ type: "setSessionModel", sessionId: SESSION, provider: "anthropic", modelId: "claude" });
  },
  "session.setThinking": () => {
    expect(daemonCommand({ type: "session.setThinking", sessionId: SESSION, thinkingLevel: "high" }))
      .toEqual({ type: "setSessionThinkingLevel", sessionId: SESSION, thinkingLevel: "high" });
  },
  "session.setFast": () => {
    expect(daemonCommand({ type: "session.setFast", sessionId: SESSION, enabled: true }))
      .toEqual({ type: "setSessionFastMode", sessionId: SESSION, enabled: true });
  },
  "session.setNotify": () => {
    // Two different daemon commands behind one phone toggle pair.
    expect(daemonCommand({ type: "session.setNotify", sessionId: SESSION, target: "main", enabled: true }))
      .toEqual({ type: "setNotifyMainOnCompletion", sessionId: SESSION, enabled: true });
    expect(daemonCommand({ type: "session.setNotify", sessionId: SESSION, target: "macos", enabled: false }))
      .toEqual({ type: "setNotifyMacOSOnCompletion", sessionId: SESSION, enabled: false });
  },
  "session.markRead": () => {
    expect(plan({ type: "session.markRead", sessionId: SESSION }))
      .toEqual({ target: "hub", request: { type: "session.markRead", sessionId: SESSION } });
  },
  "session.archive": () => {
    expect(plan({ type: "session.archive", sessionId: SESSION, archived: true }))
      .toEqual({ target: "hub", request: { type: "session.archive", sessionId: SESSION, archived: true } });
  },
  "pickle.create": () => {
    expect(plan({ type: "pickle.create", cwd: "/work" }))
      .toEqual({ target: "pickleCreate", cwd: "/work" });
    expect(plan({ type: "pickle.create", cwd: "/work", text: "start here" }))
      .toEqual({ target: "pickleCreate", cwd: "/work", text: "start here" });
  },
  "main.send": () => {
    expect(plan({ type: "main.send", text: "hi" }))
      .toEqual({ target: "hub", request: { type: "main.send", text: "hi" } });
  },
  "main.abort": () => {
    expect(plan({ type: "main.abort" })).toEqual({ target: "hub", request: { type: "main.abort" } });
  },
  "main.answer": () => {
    expect(plan({ type: "main.answer", requestId: "r1", value: true }))
      .toEqual({ target: "hub", request: { type: "main.answer", requestId: "r1", value: true } });
  },
};

describe("every remote command is routed", () => {
  for (const [type, check] of Object.entries(CASES)) {
    it(`routes ${type}`, check);
  }

  it("covers every command the protocol accepts", () => {
    const declared = RemoteCommandSchema.options.map((option) => option.shape.type.value as string);
    expect(Object.keys(CASES).sort()).toEqual([...declared].sort());
  });
});

describe("text and uploads", () => {
  it("prefers the text the caller already merged with the attachment paths", () => {
    expect(daemonCommand({ type: "session.send", sessionId: SESSION, text: "look", kind: "followUp" }).text).toBe("look");
    const merged = plan({ type: "session.send", sessionId: SESSION, text: "look", kind: "followUp" }, "look\n/tmp/a.png");
    expect(merged.target === "daemon" && (merged.command as { text?: string }).text).toBe("look\n/tmp/a.png");
    expect(plan({ type: "main.send", text: "look" }, "look\n/tmp/a.png"))
      .toEqual({ target: "hub", request: { type: "main.send", text: "look\n/tmp/a.png" } });
    expect(plan({ type: "pickle.create", cwd: "/work", text: "look" }, "look\n/tmp/a.png"))
      .toEqual({ target: "pickleCreate", cwd: "/work", text: "look\n/tmp/a.png" });
  });
});

describe("the room a command belongs to", () => {
  it("is the session for session commands and `main` for the main conversation", () => {
    expect(roomIdForCommand({ type: "session.abort", sessionId: SESSION, scope: "response" })).toBe(SESSION);
    expect(roomIdForCommand({ type: "main.send", text: "hi" })).toBe("main");
    expect(roomIdForCommand({ type: "main.abort" })).toBe("main");
    expect(roomIdForCommand({ type: "main.answer", requestId: "r1", value: 1 })).toBe("main");
    expect(roomIdForCommand({ type: "pickle.create", cwd: "/work" })).toBeUndefined();
  });

  it("exposes the typed text for the audit log only when the user wrote one", () => {
    expect(commandText({ type: "session.send", sessionId: SESSION, text: "hi", kind: "steer" })).toBe("hi");
    expect(commandText({ type: "main.abort" })).toBeUndefined();
  });
});
