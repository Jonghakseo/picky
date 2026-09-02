import { describe, expect, it } from "vitest";
import { buildPickyRuntimeContract, PICKY_RUNTIME_CONTRACT_HEADING, PICKY_SCREEN_OVERLAY_TOOL } from "./picky-runtime-contract.js";

describe("buildPickyRuntimeContract", () => {
  it("carries the literal overlay DSL tags the annotation parser accepts", () => {
    const contract = buildPickyRuntimeContract(new Set());

    expect(contract).toContain(PICKY_RUNTIME_CONTRACT_HEADING);
    expect(contract).toContain("[RECT: x=<number>");
    expect(contract).toContain("[LINE: x1=<number>");
    expect(contract).toContain("[PATH: d=\"M <x> <y> L <x> <y> C");
    expect(contract).toContain("[SCREEN: id=<screenId>]");
    expect(contract).toContain("canonical v1 subset is uppercase M (move), L (line), and C (cubic Bézier)");
    expect(contract).toContain("Elliptical arc A/a is unsupported");
    expect(contract).toContain("PATH does not support `spotlight`");
  });

  it("keeps the CLI and reply-style rules that used to share the bootstrap message", () => {
    const contract = buildPickyRuntimeContract(new Set());

    expect(contract).toContain("picky pickle-create");
    expect(contract).toContain("Always pass `--from-main`");
    expect(contract).toContain("Never call `picky submit`");
    expect(contract).toContain("### Direct reply style for Picky TTS");
    expect(contract).toContain("natural sentences in the user's language");
    expect(contract).toContain("no markdown, code blocks, bullet points, or tables");
    expect(contract).toContain("`( ... )`");
    expect(contract).toContain("deliberate typed input, not speech recognition output");
    expect(contract).toContain("Do not expose internal tool logs verbatim");
  });

  it("overrides stale bootstrap copies still sitting in the transcript", () => {
    expect(buildPickyRuntimeContract(new Set())).toContain("supersede any older Picky bootstrap notice");
  });

  it("forbids the tags outright when screen overlay is disabled", () => {
    const contract = buildPickyRuntimeContract(new Set([PICKY_SCREEN_OVERLAY_TOOL]));

    // A negative rule, not just an omission: an older bootstrap message may still be telling
    // the agent to draw, and only an explicit prohibition can outrank it.
    expect(contract).toContain("Never emit `[RECT:`, `[LINE:`, `[PATH:`, or `[SCREEN:` tags");
    expect(contract).not.toContain("[RECT: x=<number>");
    expect(contract).toContain("picky pickle-create");
    expect(contract).toContain("### Direct reply style for Picky TTS");
  });

  it("is byte-identical for the same toggle set so the system-prompt cache prefix survives", () => {
    expect(buildPickyRuntimeContract(new Set())).toBe(buildPickyRuntimeContract(new Set()));
    expect(buildPickyRuntimeContract(new Set([PICKY_SCREEN_OVERLAY_TOOL])))
      .toBe(buildPickyRuntimeContract(new Set([PICKY_SCREEN_OVERLAY_TOOL])));
    expect(buildPickyRuntimeContract(new Set())).not.toBe(buildPickyRuntimeContract(new Set([PICKY_SCREEN_OVERLAY_TOOL])));
  });
});
