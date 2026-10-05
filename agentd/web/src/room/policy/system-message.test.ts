import { describe, expect, it } from "vitest";

import type { PickySessionMessage } from "../../../../src/protocol";
import { bubbleKind } from "./message";
import {
  abbreviatedTokenCount,
  compactFailureDetail,
  compactTokenChangeText,
  makeExtensionCustomMessagePresentation,
  stripAnsi,
} from "./system-message";

function system(partial: Partial<PickySessionMessage>): PickySessionMessage {
  return { id: "m", kind: "system", createdAt: "2026-10-05T05:21:00.000Z", ...partial };
}

describe("system message classification", () => {
  it("hides the background work the Mac keeps in its task footer", () => {
    // These two arrive as one very long line; rendering them at all broke the
    // transcript width on a phone.
    expect(
      bubbleKind(
        system({
          customType: "subagent-tool",
          text: "[subagent:worker#67] completed Prompt: Read /tmp/picky-remote/build/spec-web-room.md and follow it exactly.",
        }),
      ),
    ).toBe("hidden");
    expect(
      bubbleKind(system({ customType: "bash-async-completion", text: "[bash_async b06b] 최종 게이트: pnpm run test:ci" })),
    ).toBe("hidden");
  });

  it("hides the bundled subagent tool's lifecycle notices, keeping other notices", () => {
    const lifecycle = [
      "Started subagent #12: worker",
      "Resumed subagent #12: worker",
      "subagent tool run #12 completed",
      "subagent tool run #12 (worker) failed: timed out",
      "subagent batch 9fa2 finished with errors",
    ];
    for (const text of lifecycle) {
      expect(bubbleKind(system({ notifyType: "info", text }))).toBe("hidden");
    }
    expect(bubbleKind(system({ notifyType: "info", text: "subagent 설정을 확인하세요" }))).toBe("notify");
    expect(bubbleKind(system({ notifyType: "warning", text: "토큰이 곧 만료돼요" }))).toBe("notify");
  });

  it("labels any other tagged extension payload", () => {
    expect(bubbleKind(system({ customType: "prompt-suggest-lite-status", text: "ready" }))).toBe("extensionCustomMessage");
    // Tagged but empty: nothing to label, so it falls back to plain text.
    expect(bubbleKind(system({ customType: "prompt-suggest-lite-status", text: "   " }))).toBe("systemText");
  });

  it("recognizes compaction by presentation code, and by text for older journals", () => {
    expect(bubbleKind(system({ presentation: { code: "sessionCompacted" }, text: "Session compacted" }))).toBe("compactCompletion");
    expect(bubbleKind(system({ presentation: { code: "sessionCompactedAfterOverflow" } }))).toBe("compactCompletion");
    expect(bubbleKind(system({ text: "Session compacted after context overflow" }))).toBe("compactCompletion");
    expect(
      bubbleKind(system({ presentation: { code: "sessionCompactionFailed", params: { detail: "요약 모델이 거절했어요" } } })),
    ).toBe("compactFailure");
    expect(bubbleKind(system({ text: "Auto-compaction failed\n요약 모델이 거절했어요" }))).toBe("compactFailure");
  });

  it("leaves plain system prose and tool images alone", () => {
    expect(bubbleKind(system({ text: "작업 폴더를 /tmp/picky로 바꿨어요" }))).toBe("systemText");
    expect(
      bubbleKind(system({ text: "shot.png", toolImage: { toolCallId: "t1", toolName: "read", path: "/tmp/shot.png" } })),
    ).toBe("toolImage");
  });
});

describe("extension custom message fold", () => {
  it("keeps the head of every block so a failed job in a batch stays visible", () => {
    const text = "job 1 완료\n  출력 1\n  출력 2\n\njob 2 실패\n  stderr 한 줄\n";
    const presentation = makeExtensionCustomMessagePresentation("bash-async-completion", text);
    expect(presentation?.previewLines).toEqual(["job 1 완료", "job 2 실패"]);
    expect(presentation?.hiddenLineCount).toBe(4);
    expect(presentation?.isCollapsible).toBe(true);
    expect(presentation?.fullText).toBe("job 1 완료\n  출력 1\n  출력 2\n\njob 2 실패\n  stderr 한 줄");
  });

  it("offers no disclosure when the preview already shows everything", () => {
    const presentation = makeExtensionCustomMessagePresentation("status", "  한 줄  \n");
    expect(presentation?.previewLines).toEqual(["  한 줄  "]);
    expect(presentation?.hiddenLineCount).toBe(0);
    expect(presentation?.isCollapsible).toBe(false);
  });

  it("caps the preview at Pi's 10-line fallback budget", () => {
    const blocks = Array.from({ length: 14 }, (_, index) => `블록 ${index + 1}`).join("\n\n");
    const presentation = makeExtensionCustomMessagePresentation("status", blocks);
    expect(presentation?.previewLines).toHaveLength(10);
    expect(presentation?.hiddenLineCount).toBe(17); // 27 content lines (blocks + separators) - 10
  });

  it("drops terminal escapes instead of showing them as text", () => {
    expect(stripAnsi("\u001B[31m빨강\u001B[0m")).toBe("빨강");
    expect(makeExtensionCustomMessagePresentation("status", "\u001B[1m헤더\u001B[0m")?.fullText).toBe("헤더");
  });

  it("has nothing to show for an empty payload", () => {
    expect(makeExtensionCustomMessagePresentation("status", "\n  \n")).toBeNull();
  });
});

describe("compaction copy", () => {
  it("shows the token change only once Pi reports the kept size", () => {
    expect(compactTokenChangeText({ tokensBefore: 128_000, tokensAfter: 21_400 })).toBe("128k → ~21k");
    expect(compactTokenChangeText({ tokensBefore: 128_000 })).toBe("128k");
    expect(compactTokenChangeText(undefined)).toBeNull();
    expect(abbreviatedTokenCount(940)).toBe("940");
    expect(abbreviatedTokenCount(1_000)).toBe("1k");
    expect(abbreviatedTokenCount(2_450)).toBe("2.5k");
  });

  it("keeps the summarizer's words and the usage it failed at", () => {
    expect(
      compactFailureDetail(
        system({
          presentation: {
            code: "sessionCompactionFailed",
            params: { detail: " 요약 모델이 거절했어요 ", contextTokens: 190_000, contextWindowTokens: 200_000 },
          },
        }),
      ),
    ).toEqual({ detail: "요약 모델이 거절했어요", usage: { tokens: 190_000, windowTokens: 200_000 }, localized: true });
  });

  it("falls back to the lines under the English title on an older journal", () => {
    expect(compactFailureDetail(system({ text: "Auto-compaction failed\nmodel refused" }))).toEqual({
      detail: "model refused",
      usage: null,
      localized: false,
    });
    expect(compactFailureDetail(system({ text: "Auto-compaction failed" }))).toBeNull();
    expect(compactFailureDetail(system({ text: "Session compacted" }))).toBeNull();
  });
});
