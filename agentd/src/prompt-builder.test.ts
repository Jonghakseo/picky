import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { PICKLE_TOOL_NAMES } from "./application/picky-tool-names.js";
import { buildFollowUpPrompt, buildInitialTaskPrompt, buildMainAgentBootstrapPair, buildMainAgentPickleCompletionPrompt, buildMainAgentPrompt, buildPicklePrompt } from "./prompt-builder.js";
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
    // Tool names must still be advertised so the agent knows what is available.
    for (const toolName of Object.values(PICKLE_TOOL_NAMES)) {
      expect(pair.user).toContain(toolName);
    }
    // Narration tooling (legacy `picky_narrate_progress` and its replacement
    // `picky_tell_plan`) is now provided by a seeded Pi extension in the
    // workspace `.pi/extensions/`, so its tool snippet/guidelines come from
    // the extension itself and must not leak into the bootstrap pair under
    // either name.
    expect(pair.user).not.toContain("picky_narrate_progress");
    expect(pair.user).not.toContain("picky_tell_plan");
    expect(pair.user).not.toContain("before a long step runs");
    // Persona + routing thresholds belong in the user-editable AGENTS.md, not
    // hard-coded prompt text.
    expect(pair.user).toContain("AGENTS.md");
    expect(pair.user).not.toContain("4 tool calls");
    expect(pair.user).not.toContain("ideally about 300 Korean characters");
    expect(pair.user).not.toContain("Korean-speaking");
    expect(pair.user).not.toContain("Korean filler line");
    expect(pair.user).not.toContain("You are Picky, the always-on assistant");
  });

  it("surfaces typed-text source per turn while runtime guard rails stay in the bootstrap", () => {
    const context = PickyContextPacketSchema.parse({
      ...readJson("context/plain-text.context.json"),
      source: "text",
      transcript: "느으 الرحيم",
    });

    const prompt = buildMainAgentPrompt(context);
    const pair = buildMainAgentBootstrapPair();

    expect(prompt.text).toContain("- Source: text");
    expect(pair.user).toContain("deliberate typed input, not speech recognition output");
    expect(pair.user).toContain("Do not expose internal tool logs verbatim");
  });

  it("does not include pointer tag instructions in Picky prompts", () => {
    const turnPrompt = buildMainAgentPrompt(PickyContextPacketSchema.parse(readJson("context/plain-text.context.json")));
    const pair = buildMainAgentBootstrapPair();
    const picklePrompt = buildPicklePrompt(PickyContextPacketSchema.parse(readJson("context/plain-text.context.json")), {
      title: "Pickle work",
      instructions: "Investigate without showing overlays",
    });

    expect(pair.user).not.toContain("[POINT:");
    expect(pair.user).not.toContain("append pointer tags");
    expect(turnPrompt.text).not.toContain("[POINT:");
    expect(picklePrompt.text).not.toContain("[POINT:");
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
    expect(prompt.text).toContain("## User follow-up\n표시한 부분 다시 봐줘");
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

  it("builds the Picky bootstrap pair with TTS-friendly reply rules and a short OK ack", () => {
    const pair = buildMainAgentBootstrapPair();
    expect(pair.user).toContain("natural sentences in the user's language");
    expect(pair.user).toContain("no markdown, code blocks, bullet points, or tables");
    expect(pair.user).toContain("parentheses");
    expect(pair.user).toContain("`( ... )`");
    expect(pair.user).toContain("This message was not sent by the user");
    expect(pair.assistant).toBe("OK");
  });

  it("omits the TTS parenthesis hint for Realtime runtimes that lack the post-processing hook", () => {
    // OpenAI Realtime synthesises audio directly from the model output — there
    // is no Picky-side TTS layer to strip `( ... )` before playback — so the
    // hint must not reach the model or it will start reading URLs aloud.
    const pair = buildMainAgentBootstrapPair({ omitTtsParenthesisHint: true });
    expect(pair.user).not.toContain("`( ... )`");
    expect(pair.user).not.toContain("automatically skips parenthesised content");
    // The TTS-friendly framing (no markdown, concise) still applies.
    expect(pair.user).toContain("natural sentences in the user's language");
    expect(pair.user).toContain("no markdown, code blocks, bullet points, or tables");
    expect(pair.user).toContain("read aloud verbatim in this mode");
  });

  it("still threads through the previous-epoch summary when the TTS hint is omitted", () => {
    const pair = buildMainAgentBootstrapPair({ compactSummary: "earlier summary", omitTtsParenthesisHint: true });
    expect(pair.user).toContain("## Previous Picky epoch summary");
    expect(pair.user).toContain("earlier summary");
    expect(pair.user).not.toContain("`( ... )`");
  });

  it("builds language-neutral Pickle completion instructions", () => {
    const prompt = buildMainAgentPickleCompletionPrompt({ id: "p1", title: "Pickle work", status: "completed", finalAnswer: "Done" });
    expect(prompt.text).toContain("Tell the user in the user's language");
    expect(prompt.text).not.toContain("Tell the user in Korean");
  });
});
