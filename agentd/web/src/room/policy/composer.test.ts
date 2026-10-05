import { describe, expect, it } from "vitest";

import type { PickyQueueItem } from "../../../../src/protocol";
import {
  afterCurrentReplySubmitKind,
  bashMode,
  canStop,
  defaultSubmitKind,
  draftAppendingTranscript,
  draftRestoringQueuedInputs,
  effectiveBashMode,
  placeholderKey,
  queueItemText,
  returnKeyAction,
  submitStatus,
} from "./composer";

function queued(partial: Partial<PickyQueueItem> & { id: string; text: string }): PickyQueueItem {
  return { enqueuedAt: "2026-10-05T05:00:00.000Z", ...partial };
}

describe("submit kind", () => {
  it("steers a session that is still working and follows up a finished one", () => {
    expect(defaultSubmitKind("running")).toBe("steer");
    expect(defaultSubmitKind("waiting_for_input")).toBe("steer");
    expect(defaultSubmitKind("completed")).toBe("followUp");
    expect(defaultSubmitKind("blocked")).toBe("followUp");
  });

  it("offers no 'after this response' row once there is no reply to follow", () => {
    expect(afterCurrentReplySubmitKind("running")).toBe("followUp");
    expect(afterCurrentReplySubmitKind("cancelled")).toBeNull();
    expect(afterCurrentReplySubmitKind("failed")).toBeNull();
  });
});

describe("a Pickle kept running only by background work", () => {
  it("takes a new message as a follow-up once the agent is idle, like a finished one", () => {
    expect(defaultSubmitKind(submitStatus("running", "idle"))).toBe("followUp");
    expect(defaultSubmitKind(submitStatus("running", "settled"))).toBe("followUp");
    expect(defaultSubmitKind(submitStatus("running", "responding"))).toBe("steer");
    expect(defaultSubmitKind(submitStatus("running", undefined))).toBe("steer");
  });
});

describe("placeholder", () => {
  it("says it is compacting before anything else", () => {
    expect(placeholderKey("running", true)).toBe("hud.composer.placeholder.compacting");
    expect(placeholderKey("completed", true)).toBe("hud.composer.placeholder.compacting");
  });

  it("differs between a working and a finished session", () => {
    expect(placeholderKey("running", false)).not.toBe(placeholderKey("completed", false));
  });
});

describe("bash mode", () => {
  it("reads one ! as visible, !! as private and a bare ! as plain text", () => {
    expect(bashMode("!ls -al")).toBe("visible");
    expect(bashMode("  !!rm -rf /tmp/x")).toBe("private");
    expect(bashMode("!")).toBe("none");
    expect(bashMode("!!   ")).toBe("none");
    expect(bashMode("정말 !중요")).toBe("none");
  });

  it("turns off while photos ride along, because the text is no longer a command", () => {
    expect(effectiveBashMode("!ls", 1)).toBe("none");
    expect(effectiveBashMode("!ls", 0)).toBe("visible");
  });
});

describe("stop button", () => {
  it("appears while running, and on a waiting session only after it said something", () => {
    expect(canStop("running", false)).toBe(true);
    expect(canStop("waiting_for_input", false)).toBe(false);
    expect(canStop("waiting_for_input", true)).toBe(true);
    expect(canStop("completed", true)).toBe(false);
  });
});

describe("queued input restore", () => {
  it("shows the instruction the user typed, not the built prompt", () => {
    expect(queueItemText(queued({ id: "q1", text: "<envelope>", displayText: "표로 정리해 줘" }))).toBe("표로 정리해 줘");
    expect(queueItemText(queued({ id: "q1", text: "표로 정리해 줘", displayText: "   " }))).toBe("표로 정리해 줘");
  });

  it("appends the queue under an existing draft and leaves an empty queue alone", () => {
    const items = [queued({ id: "q1", text: "첫째" }), queued({ id: "q2", text: "둘째" })];
    expect(draftRestoringQueuedInputs("", items)).toBe("첫째\n\n둘째");
    expect(draftRestoringQueuedInputs("쓰던 글", items)).toBe("쓰던 글\n\n첫째\n\n둘째");
    expect(draftRestoringQueuedInputs("쓰던 글", [])).toBeNull();
  });
});

describe("dictation transcript", () => {
  it("adds one space between the draft and the transcript, and never sends by itself", () => {
    expect(draftAppendingTranscript("", "받아쓴 문장")).toBe("받아쓴 문장");
    expect(draftAppendingTranscript("앞 문장", " 받아쓴 문장 ")).toBe("앞 문장 받아쓴 문장");
    expect(draftAppendingTranscript("앞 문장 ", "받아쓴 문장")).toBe("앞 문장 받아쓴 문장");
    expect(draftAppendingTranscript("앞 문장", "   ")).toBe("앞 문장");
  });
});

describe("Return key", () => {
  const key = (overrides: Partial<Parameters<typeof returnKeyAction>[0]> = {}) =>
    returnKeyAction({ key: "Enter", shiftKey: false, altKey: false, metaKey: false, ctrlKey: false, composing: false, hardwareKeyboard: true, ...overrides });

  it("sends with a keyboard the way the HUD does, and opens send timing with Command or Control", () => {
    expect(key()).toBe("submit");
    expect(key({ shiftKey: true })).toBe("newline");
    expect(key({ altKey: true })).toBe("submitAfterReply");
    expect(key({ metaKey: true })).toBe("openSendTiming");
    expect(key({ ctrlKey: true })).toBe("openSendTiming");
  });

  it("leaves Return alone while Korean is composing and on a phone keyboard", () => {
    expect(key({ composing: true })).toBe("none");
    expect(key({ hardwareKeyboard: false })).toBe("none");
    expect(key({ key: "a" })).toBe("none");
  });
});
