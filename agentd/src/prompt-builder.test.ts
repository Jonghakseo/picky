import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { buildInitialTaskPrompt, buildMainAgentBootstrapPair, buildMainAgentPrompt, buildSideAgentPrompt } from "./prompt-builder.js";
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

  it("puts standing side-session routing instructions in the main-agent bootstrap", () => {
    const pair = buildMainAgentBootstrapPair();
    expect(pair.user).toContain("picky_side_sessions");
    expect(pair.user).toContain("picky_side_steer");
    expect(pair.user).toContain("instead of starting a duplicate side agent");
  });

  it("puts handoff cwd defaults in the main-agent bootstrap", () => {
    const pair = buildMainAgentBootstrapPair();
    expect(pair.user).toContain("`picky_handoff` accepts an optional `cwd`");
    expect(pair.user).toContain("omit it to use Picky's configured default cwd");
  });

  it("puts compact delta-first handoff and steering guidance in the main-agent bootstrap", () => {
    const pair = buildMainAgentBootstrapPair();
    const turnPrompt = buildMainAgentPrompt(PickyContextPacketSchema.parse(readJson("context/plain-text.context.json")));

    expect(pair.user).toContain("Keep the steer message delta-only");
    expect(pair.user).toContain("Keep `picky_handoff.instructions` compact and action-oriented");
    expect(pair.user).toContain("Do not paste the full current prompt, captured context, screenshot metadata, prior transcript, or tool logs");
    expect(turnPrompt.text).not.toContain("Keep `picky_handoff.instructions` compact and action-oriented");
  });

  it("keeps input modality in each main-agent turn and typed-text handling in bootstrap", () => {
    const context = PickyContextPacketSchema.parse({
      ...readJson("context/plain-text.context.json"),
      source: "text",
      transcript: "느으 الرحيم",
    });

    const prompt = buildMainAgentPrompt(context);
    const pair = buildMainAgentBootstrapPair();

    expect(prompt.text).toContain("Input modality: typed text");
    expect(prompt.text).not.toContain("treat the request text as deliberate typed input, not speech recognition or STT output");
    expect(pair.user).toContain("treat the request text as deliberate typed input, not speech recognition or STT output");
    expect(pair.user).toContain("Do not say the text was misrecognized");
    expect(pair.user).toContain("ask them to retype or clarify");
  });

  it("includes user-provided main-agent extra instructions in the bootstrap pair when present", () => {
    const pairWithInstructions = buildMainAgentBootstrapPair("   으은 답해주세요.   ");
    const pairWithoutInstructions = buildMainAgentBootstrapPair("   ");

    expect(pairWithInstructions.user).toContain("## User-provided main-agent instructions");
    expect(pairWithInstructions.user).toContain("으은 답해주세요.");
    // Bootstrap-only — the per-turn prompt template stays clean of user-additional content.
    const turnPrompt = buildMainAgentPrompt(PickyContextPacketSchema.parse(readJson("context/plain-text.context.json")));
    expect(turnPrompt.text).not.toContain("User-provided main-agent instructions");
    expect(pairWithoutInstructions.user).not.toContain("User-provided main-agent instructions");
  });

  it("puts pointer overlay instructions in the main-agent bootstrap, not every turn", () => {
    const prompt = buildMainAgentPrompt(PickyContextPacketSchema.parse(readJson("context/plain-text.context.json")));
    const pair = buildMainAgentBootstrapPair();
    expect(pair.user).toContain("call `picky_show_pointer`");
    expect(pair.user).toContain("Coordinates are always screenshot pixels");
    expect(pair.user).toContain("Screenshot coordinates use top-left origin");
    expect(prompt.text).not.toContain("Pointer overlay rules");
    expect(prompt.text).not.toContain("Coordinates are always screenshot pixels");
    expect(prompt.text).not.toContain("[POINT:");
  });

  it("does not include pointer overlay instructions in side-agent handoff prompts", () => {
    const prompt = buildSideAgentPrompt(PickyContextPacketSchema.parse(readJson("context/plain-text.context.json")), {
      title: "Side work",
      instructions: "Investigate without showing overlays",
    });

    expect(prompt.text).toContain("# Picky side-agent task");
    expect(prompt.text).toContain("Investigate without showing overlays");
    expect(prompt.text).not.toContain("picky_show_pointer");
    expect(prompt.text).not.toContain("Pointer overlay rules");
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

    expect(prompt.text).toContain("cursorDisplayPoint=100,782");
    expect(prompt.text).toContain("cursorScreenshotPixel=200,1564");
    expect(prompt.text).toContain("cursorGlobalAppKit=100,200");
  });

  it("builds the main-agent bootstrap pair with TTS-friendly Korean rules and a short OK ack", () => {
    const pair = buildMainAgentBootstrapPair();
    expect(pair.user).toContain("마크다운");
    expect(pair.user).toContain("코드블록");
    expect(pair.user).toContain("괄호");
    expect(pair.user).toContain("`( ... )`");
    expect(pair.user).toContain("이 메시지는 사용자가 보낸 것이 아니");
    expect(pair.assistant).toBe("OK");
  });
});
