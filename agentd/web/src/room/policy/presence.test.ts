import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vitest";

import type { PickyAgentSession, PickyToolActivity } from "../../../../src/protocol";
import { setLocale } from "../i18n";
import { derivePresence } from "./presence";

function running(tool: Partial<PickyToolActivity> & Pick<PickyToolActivity, "name">): PickyAgentSession {
  return {
    status: "running",
    updatedAt: "2026-10-05T06:00:00.000Z",
    tools: [{ toolCallId: "call-1", status: "running", startedAt: "2026-10-05T06:00:01.000Z", ...tool }],
  } as unknown as PickyAgentSession;
}

/** The two catalog strings the policy formats, read from the Mac catalog itself. */
function installCatalogStrings(): void {
  const catalog = JSON.parse(readFileSync(new URL("../../../../../Picky/Resources/Localizable.xcstrings", import.meta.url), "utf8")) as {
    strings: Record<string, { localizations: Record<string, { stringUnit: { value: string } }> }>;
  };
  const tables: Record<string, Record<string, string>> = { ko: {}, en: {} };
  for (const key of ["hud.presence.skill", "hud.presence.subagent"]) {
    for (const locale of ["ko", "en"]) {
      const table = tables[locale];
      const value = catalog.strings[key]?.localizations[locale]?.stringUnit.value;
      if (table && value) table[key] = value;
    }
  }
  (globalThis as { __STRINGS__?: unknown }).__STRINGS__ = tables;
}

describe("presence line detail (HUD parity)", () => {
  beforeAll(() => {
    installCatalogStrings();
    setLocale("ko");
  });

  it("never shows a tool's raw output or arguments", () => {
    // Seen on a real phone: an MCP-style tool whose preview is its JSON result.
    const presence = derivePresence(
      running({
        name: "picky_dock_layout",
        preview: '{"content":[{"type":"text","text":"[\\n {\\n \\"id\\": \\"3118F242"}]}',
        argsPreview: '{"action":"list"}',
      }),
    );
    expect(presence).toEqual({ phase: "working", detail: undefined, startedAt: "2026-10-05T06:00:01.000Z" });
  });

  it("shows a bash title, not the command", () => {
    const presence = derivePresence(
      running({ name: "bash", argsPreview: '{"command":"rm -rf build && make","title":"빌드 다시 하기"}', preview: "rm -rf build && make" }),
    );
    expect(presence?.detail).toBe("빌드 다시 하기");
    expect(derivePresence(running({ name: "bash", argsPreview: '{"command":"ls"}', preview: "ls" }))?.detail).toBeUndefined();
  });

  it("names the file for file tools, even from a cut-off argument preview", () => {
    const presence = derivePresence(running({ name: "edit", argsPreview: '{"path":"/repo/Picky/HUD/View.swift","oldText":"let a = \\"' }));
    expect(presence).toMatchObject({ phase: "editingFile", detail: "View.swift", detailHelp: "/repo/Picky/HUD/View.swift" });
  });

  it("reads a SKILL.md as a skill step", () => {
    const presence = derivePresence(running({ name: "read", argsPreview: '{"path":"/Users/me/.pi/agent/skills/picky-commit/SKILL.md"}' }));
    expect(presence).toMatchObject({ phase: "working", detail: "picky-commit 스킬 사용" });
  });

  it("names delegated subagents", () => {
    const presence = derivePresence(running({ name: "subagent", subagentSummary: { action: "batch", agents: ["worker", "reviewer"] } }));
    expect(presence?.detail).toBe("worker, reviewer에게 맡김");
  });
});
