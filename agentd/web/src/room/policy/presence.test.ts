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

describe("presence while only background work runs", () => {
  it("drops the line once the agent has answered, even though the session is still running", () => {
    const base = { status: "running", updatedAt: "2026-10-05T06:00:00.000Z", tools: [] } as unknown as PickyAgentSession;
    const cycle = (phase: string) => ({ cycleId: "c", runtimeInstanceId: "r", phase, controlGeneration: 0 });
    expect(derivePresence({ ...base, agentCycle: cycle("responding") } as PickyAgentSession)?.phase).toBe("thinking");
    expect(derivePresence({ ...base, agentCycle: cycle("idle") } as PickyAgentSession)).toBeNull();
    expect(derivePresence({ ...base, agentCycle: cycle("settled") } as PickyAgentSession)).toBeNull();
  });
});

describe("presence right after a step finishes (HUD parity)", () => {
  const ended = "2026-10-05T06:00:10.000Z";
  const at = (seconds: number) => Date.parse(ended) + seconds * 1000;
  const finished = (name: string, status: string): PickyAgentSession =>
    running({ name, status, argsPreview: '{"command":"x","title":"빈도 측정 재실행"}', endedAt: ended } as Partial<PickyToolActivity> & { name: string });

  it("reads done or failed with the step title for five seconds, then thinking", () => {
    expect(derivePresence(finished("bash", "succeeded"), at(0.5))).toMatchObject({ phase: "workCompleted", detail: "빈도 측정 재실행" });
    expect(derivePresence(finished("bash", "failed"), at(4.9))).toMatchObject({ phase: "workFailed", detail: "빈도 측정 재실행" });
    expect(derivePresence(finished("bash", "succeeded"), at(5))?.phase).toBe("thinking");
  });

  it("gives way to a running tool and skips tools that only launch background work", () => {
    const session = finished("bash", "succeeded");
    const next = { toolCallId: "call-2", name: "read", status: "running", argsPreview: '{"path":"/a/b.ts"}' } as PickyToolActivity;
    expect(derivePresence({ ...session, tools: [...(session.tools ?? []), next] }, at(1))?.phase).toBe("readingFile");
    expect(derivePresence(finished("bash_async", "succeeded"), at(1))?.phase).toBe("thinking");
    expect(derivePresence(finished("subagent", "succeeded"), at(1))?.phase).toBe("thinking");
  });
});
