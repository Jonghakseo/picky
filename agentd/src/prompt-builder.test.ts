import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { buildFollowUpPrompt, buildInitialTaskPrompt, buildMainAgentPrompt } from "./prompt-builder.js";
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

  it("builds follow-up prompts for an existing session", () => {
    const prompt = buildFollowUpPrompt("session-001", "Please continue", PickyContextPacketSchema.parse(readJson("context/plain-text.context.json")));
    expect(prompt.text).toContain("Session: session-001");
    expect(prompt.text).toContain("Please continue");
  });

  it("tells the main agent to inspect and steer existing side sessions before duplicating handoff", () => {
    const prompt = buildMainAgentPrompt(PickyContextPacketSchema.parse(readJson("context/plain-text.context.json")));
    expect(prompt.text).toContain("picky_side_sessions");
    expect(prompt.text).toContain("picky_side_steer");
    expect(prompt.text).toContain("instead of starting a duplicate side agent");
  });

  it("tells the main agent that handoff cwd is optional and defaults to configured cwd", () => {
    const prompt = buildMainAgentPrompt(PickyContextPacketSchema.parse(readJson("context/plain-text.context.json")));
    expect(prompt.text).toContain("`picky_handoff` accepts an optional `cwd`");
    expect(prompt.text).toContain("omit it to use Picky's configured default cwd");
  });
});
