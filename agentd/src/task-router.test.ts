import { describe, expect, it } from "vitest";
import type { PickyContextPacket } from "./protocol.js";
import { immediateQuickReply } from "./task-router.js";

const context = (transcript: string, screenshots = 0): PickyContextPacket => ({
  id: `context-${transcript}`,
  source: "voice",
  capturedAt: "2026-05-01T00:00:00.000Z",
  transcript,
  cwd: "/tmp/project",
  screenshots: Array.from({ length: screenshots }, (_, index) => ({ id: `shot-${index + 1}`, label: `screen ${index + 1}`, path: `/tmp/shot-${index + 1}.jpg` })),
  warnings: [],
});

describe("immediateQuickReply", () => {
  it("answers screen visibility checks without handoff", () => {
    expect(immediateQuickReply(context("이 화면 보여?", 3))).toBe("네, 현재 화면 캡처 3장을 받고 있어요.");
    expect(immediateQuickReply(context("내 화면 보이나", 1))).toBe("네, 현재 화면 캡처 1장을 받고 있어요.");
  });

  it("does not answer screen analysis requests directly", () => {
    expect(immediateQuickReply(context("이 화면 분석해줘", 3))).toBeUndefined();
    expect(immediateQuickReply(context("이 화면에 있는 이슈 정리해줘", 3))).toBeUndefined();
  });

  it("does not route test-like utterances through deterministic quick-reply regexes", () => {
    expect(immediateQuickReply(context("테스트"))).toBeUndefined();
    expect(immediateQuickReply(context("마이크 테스트"))).toBeUndefined();
    expect(immediateQuickReply(context("테스트 코드 작성해줘"))).toBeUndefined();
    expect(immediateQuickReply(context("test the codebase for obvious bugs"))).toBeUndefined();
    expect(immediateQuickReply(context("마이크 설정 코드 수정해줘"))).toBeUndefined();
  });
});
