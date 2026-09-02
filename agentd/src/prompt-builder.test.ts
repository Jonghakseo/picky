import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { buildFollowUpPrompt, buildInitialTaskPrompt, buildMainAgentBootstrapPair, buildMainAgentPickleCompletionPrompt, buildMainAgentPrompt, buildPicklePrompt, buildSteerPrompt } from "./prompt-builder.js";
import { PickyContextPacketSchema } from "./protocol.js";

const root = join(process.cwd(), "..", "contracts");
const readJson = (path: string) => JSON.parse(readFileSync(join(root, path), "utf8"));
const readText = (path: string) => readFileSync(join(root, path), "utf8");

describe("neutral prompt builder", () => {
  it("matches the issue URL prompt fixture without workflow instructions", () => {
    const context = PickyContextPacketSchema.parse(readJson("context/sentry-url.context.json"));
    const prompt = buildInitialTaskPrompt(context);
    expect(prompt.text).toBe(readText("prompts/sentry-url.expected.md"));
    expect(prompt.text).not.toContain("sentry-investigate");
    expect(prompt.text).not.toMatch(/use .*sentry/i);
    expect(prompt.imagePaths).toEqual(["/tmp/picky/shot-1.png"]);
  });

  it("matches the chat URL prompt fixture without workflow instructions", () => {
    const context = PickyContextPacketSchema.parse(readJson("context/slack-url.context.json"));
    const prompt = buildInitialTaskPrompt(context);
    expect(prompt.text).toBe(readText("prompts/slack-url.expected.md"));
    expect(prompt.text).not.toContain("slack-thread-context");
    expect(prompt.text).not.toMatch(/use .*slack/i);
  });

  it("preserves multi-screen labels", () => {
    const context = PickyContextPacketSchema.parse(readJson("context/multi-screen.context.json"));
    const prompt = buildInitialTaskPrompt(context);
    expect(prompt.text).toContain("left-display (screen1)");
    expect(prompt.text).toContain("right-display (screen2)");
    expect(prompt.imagePaths).toHaveLength(2);
  });

  it("defers persona and Pickle routing rules to the cwd's AGENTS.md", () => {
    const pair = buildMainAgentBootstrapPair();
    expect(pair.user).toContain("picky pickle-create");
    expect(pair.user).toContain("picky pickle-list");
    // Persona + routing thresholds belong in the user-editable AGENTS.md, not
    // hard-coded prompt text.
    expect(pair.user).toContain("AGENTS.md");
    expect(pair.user).not.toContain("4 tool calls");
    expect(pair.user).not.toContain("ideally about 300 Korean characters");
    expect(pair.user).not.toContain("Korean-speaking");
    expect(pair.user).not.toContain("Korean filler line");
    expect(pair.user).not.toContain("You are Picky, the always-on assistant");
  });

  it("surfaces typed-text source per turn", () => {
    const context = PickyContextPacketSchema.parse({
      ...readJson("context/plain-text.context.json"),
      source: "text",
      transcript: "느으 الرحيم",
    });

    expect(buildMainAgentPrompt(context).text).toContain("- Source: text");
  });

  it("keeps standing runtime rules out of the bootstrap message so compaction cannot drop them", () => {
    const pair = buildMainAgentBootstrapPair();

    // These rules moved to the system prompt (`buildPickyRuntimeContract`). Re-adding any of
    // them here would reintroduce the loss-on-compaction bug this guard exists for.
    expect(pair.user).not.toContain("[RECT:");
    expect(pair.user).not.toContain("[LINE:");
    expect(pair.user).not.toContain("[PATH:");
    expect(pair.user).not.toContain("## Picky visual overlay DSL");
    expect(pair.user).not.toContain("Direct reply style for Picky TTS");
    expect(pair.user).not.toContain("Never call `picky submit`");
    expect(pair.user).toContain("system prompt on every turn");
  });

  it("adds Pickle visual DSL guidance only for an enabled turn with screenshots", () => {
    const withScreenshots = PickyContextPacketSchema.parse(readJson("context/multi-screen.context.json"));
    const withoutScreenshots = PickyContextPacketSchema.parse(readJson("context/plain-text.context.json"));

    const enabledFollowUp = buildFollowUpPrompt("show this", withScreenshots, { visualDslEnabled: true });
    const enabledSteer = buildSteerPrompt("show this", withScreenshots, { visualDslEnabled: true });
    const disabled = buildFollowUpPrompt("show this", withScreenshots);
    const missingScreenshot = buildFollowUpPrompt("show this", withoutScreenshots, { visualDslEnabled: true });

    expect(enabledFollowUp.text).toContain("## Picky visual overlay DSL for this turn");
    expect(enabledFollowUp.text).toContain("[RECT: x=<number>");
    expect(enabledFollowUp.text).toContain("[PATH: d=\"M <x> <y>");
    expect(enabledSteer.text).toContain("## Picky visual overlay DSL for this turn");
    expect(disabled.text).not.toContain("## Picky visual overlay DSL for this turn");
    expect(missingScreenshot.text).not.toContain("## Picky visual overlay DSL for this turn");
  });

  it("places the handoff title before Pickle boilerplate so auto-name sees it early", () => {
    const prompt = buildPicklePrompt(PickyContextPacketSchema.parse(readJson("context/plain-text.context.json")), {
      title: "셀렉 결제 프론트·백엔드 원인 조사",
      instructions: "Investigate payment failure causes.",
    });

    expect(prompt.text.startsWith("# Picky Pickle task\n\n## Handoff title\n셀렉 결제 프론트·백엔드 원인 조사")).toBe(true);
    expect(prompt.text.indexOf("## Handoff title")).toBeLessThan(prompt.text.indexOf("You are Pickle, a delegated Pi agent"));
  });

  it("includes user-drawn ink marks as screen-region context", () => {
    const context = PickyContextPacketSchema.parse({
      ...readJson("context/plain-text.context.json"),
      screenshots: [
        {
          id: "shot-ink",
          label: "cursor screen",
          path: "/tmp/picky/ink.jpg",
          screenId: "screen1",
          bounds: { x: 0, y: 0, width: 1512, height: 982 },
          screenshotWidthInPixels: 3024,
          screenshotHeightInPixels: 1964,
          isCursorScreen: true,
        },
      ],
      inkMarks: [
        {
          id: "ink-1-stroke-1",
          source: "voice",
          kind: "freehand-highlight",
          screenId: "screen1",
          points: [{ x: 20, y: 30 }, { x: 40, y: 50 }, { x: 60, y: 70 }],
          bounds: { x: 20, y: 30, width: 40, height: 40 },
          strokeWidth: 12.5,
          opacity: 0.34,
        },
      ],
    });

    const prompt = buildInitialTaskPrompt(context);

    expect(prompt.text).toContain("## User-marked screen regions");
    expect(prompt.text).toContain("semi-transparent Picky highlighter strokes");
    expect(prompt.text).toContain("- mark1 on screen1");
    expect(prompt.text).not.toContain("strokeWidth");
    expect(prompt.text).not.toContain("points=");
  });

  it("builds follow-up prompts with nonvisual grounding context", () => {
    const context = PickyContextPacketSchema.parse({
      id: "context-follow-up-browser",
      source: "text-follow-up",
      capturedAt: "2026-05-01T00:00:00.000Z",
      transcript: "이 내용을 확인해줘",
      browser: {
        title: "Picky issue",
        url: "https://github.com/creatrip/picky/issues/128",
      },
      selectedText: "The selected error details",
      screenshots: [],
      inkMarks: [],
      warnings: [],
    });

    const prompt = buildFollowUpPrompt("이 내용을 확인해줘", context);

    expect(prompt.text).toContain("# Picky follow-up");
    expect(prompt.text).toContain("- Browser title: Picky issue");
    expect(prompt.text).toContain("- Browser URL: https://github.com/creatrip/picky/issues/128");
    expect(prompt.text).toContain("## Selected text\nThe selected error details");
    expect(prompt.imagePaths).toEqual([]);
  });

  it("keeps follow-up text plain when context has no grounding", () => {
    const context = PickyContextPacketSchema.parse({
      id: "context-follow-up-empty",
      source: "text-follow-up",
      capturedAt: "2026-05-01T00:00:00.000Z",
      transcript: "계속해줘",
      screenshots: [],
      inkMarks: [],
      warnings: [],
    });

    const prompt = buildFollowUpPrompt("계속해줘", context);

    expect(prompt).toEqual({ text: "계속해줘", imagePaths: [] });
  });

  it("builds follow-up prompts with screen context and images", () => {
    const context = PickyContextPacketSchema.parse({
      ...readJson("context/plain-text.context.json"),
      screenshots: [
        {
          id: "shot-follow-up",
          label: "cursor screen",
          path: "/tmp/picky/follow-up.jpg",
          screenId: "screen1",
          isCursorScreen: true,
        },
      ],
    });

    const prompt = buildFollowUpPrompt("표시한 부분 다시 봐줘", context);

    expect(prompt.text).toContain("# Picky follow-up");
    expect(prompt.text).toContain("## User follow-up\n- Source: text\n\n표시한 부분 다시 봐줘");
    expect(prompt.text).toContain("## Captured context");
    expect(prompt.imagePaths).toEqual(["/tmp/picky/follow-up.jpg"]);
  });

  it("includes captured cursor coordinates when available", () => {
    const context = PickyContextPacketSchema.parse({
      ...readJson("context/plain-text.context.json"),
      screenshots: [
        {
          id: "shot-cursor",
          label: "cursor screen",
          path: "/tmp/picky/cursor.jpg",
          screenId: "screen1",
          bounds: { x: 0, y: 0, width: 1512, height: 982 },
          screenshotWidthInPixels: 3024,
          screenshotHeightInPixels: 1964,
          isCursorScreen: true,
          cursor: {
            globalPoint: { x: 100, y: 200 },
            displayPoint: { x: 100, y: 782 },
            screenshotPixel: { x: 200, y: 1564 },
          },
        },
      ],
    });

    const prompt = buildInitialTaskPrompt(context);

    expect(prompt.text).toContain("cursorScreenshotPixel=200,1564");
    expect(prompt.text).not.toContain("cursorDisplayPoint");
    expect(prompt.text).not.toContain("cursorGlobalAppKit");
  });

  it("builds the Picky bootstrap pair with a short OK ack", () => {
    const pair = buildMainAgentBootstrapPair();
    expect(pair.user).toContain("This message was not sent by the user");
    expect(pair.assistant).toBe("OK");
  });

  it("builds language-neutral Pickle completion instructions", () => {
    const prompt = buildMainAgentPickleCompletionPrompt({ id: "p1", title: "Pickle work", status: "completed", finalAnswer: "Done" });
    expect(prompt.text).toContain("Tell the user in the user's language");
    expect(prompt.text).not.toContain("Tell the user in Korean");
  });
});
