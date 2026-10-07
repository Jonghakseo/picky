import { describe, expect, it } from "vitest";
import { PickyAgentSessionSchema } from "../protocol.js";
import { aggregateUsageSamples, pickleStatisticsRecord, projectNameForCwd } from "./pickle-statistics.js";

function session(overrides: Record<string, unknown> = {}) {
  return PickyAgentSessionSchema.parse({
    id: "pickle-1",
    title: "Investigate cache bug",
    status: "completed",
    cwd: "/Users/example/picky",
    createdAt: "2026-09-01T00:00:00.000Z",
    updatedAt: "2026-09-02T00:00:00.000Z",
    messages: [
      { id: "u-1", kind: "user_text", originatedBy: "user", createdAt: "2026-09-01T00:00:00.000Z", text: "Investigate bug" },
      { id: "u-2", kind: "user_text", originatedBy: "user", createdAt: "2026-09-01T01:00:00.000Z", text: "Add a regression test" },
      { id: "m-1", kind: "user_text", originatedBy: "main_agent", createdAt: "2026-09-01T02:00:00.000Z", text: "Review the failure" },
    ],
    subagentRuns: [
      { runId: 1, agent: "reviewer", task: "review", status: "done" },
      { runId: 2, agent: "worker", task: "implement", status: "done" },
      { runId: 3, agent: "verifier", task: "verify", status: "done" },
    ],
    ...overrides,
  });
}

describe("pickle statistics", () => {
  it("derives Hub record counts from persisted Pickle history", () => {
    const record = pickleStatisticsRecord(session(), {
      category: "fix",
      fingerprint: "fingerprint",
      classifiedAt: "2026-09-03T00:00:00.000Z",
      attempts: 1,
    });

    expect(record).toMatchObject({
      project: "picky",
      followUpCount: 1,
      delegationCount: 1,
      reviewCount: 2,
      category: "fix",
      lastActivityAt: "2026-09-02T00:00:00.000Z",
    });
  });

  it("counts only user instructions after the ordered user or main-agent kickoff", () => {
    const userText = (id: string, originatedBy: "user" | "main_agent" | "pi_extension") => ({
      id,
      kind: "user_text" as const,
      originatedBy,
      createdAt: "2026-09-01T00:00:00.000Z",
      text: id,
    });
    const nonInstruction = {
      id: "agent-progress",
      kind: "agent_activity" as const,
      createdAt: "2026-09-01T00:00:00.000Z",
      text: "working",
    };

    expect(pickleStatisticsRecord(session({ messages: [userText("user-kickoff", "user")] })).followUpCount).toBe(0);
    expect(pickleStatisticsRecord(session({ messages: [userText("user-kickoff", "user"), nonInstruction, userText("later-user", "user")] })).followUpCount).toBe(1);
    expect(pickleStatisticsRecord(session({ messages: [userText("user-kickoff", "user"), userText("later-one", "user"), userText("later-two", "user")] })).followUpCount).toBe(2);

    expect(pickleStatisticsRecord(session({ messages: [userText("main-kickoff", "main_agent")] })).followUpCount).toBe(0);
    expect(pickleStatisticsRecord(session({ messages: [userText("main-kickoff", "main_agent"), nonInstruction, userText("later-user", "user")] })).followUpCount).toBe(1);
    expect(pickleStatisticsRecord(session({ messages: [userText("main-kickoff", "main_agent"), userText("later-one", "user"), userText("later-two", "user")] })).followUpCount).toBe(2);

    // Extension reports are not a user or main-agent instruction and cannot turn
    // the first later user instruction into a follow-up.
    expect(pickleStatisticsRecord(session({ messages: [userText("extension-report", "pi_extension"), nonInstruction, userText("user-kickoff", "user")] })).followUpCount).toBe(0);
  });

  it("counts Pickle results and measures work time without idle gaps between turns", () => {
    const at = (minutes: number) => new Date(Date.UTC(2026, 8, 1, 0, minutes)).toISOString();
    const record = pickleStatisticsRecord(session({
      messages: [
        { id: "u-1", kind: "user_text", originatedBy: "user", createdAt: at(0), text: "Start" },
        { id: "a-1", kind: "agent_activity", createdAt: at(10), text: "working" },
        { id: "a-2", kind: "agent_text", createdAt: at(30), text: "done" },
        // The user replies two hours later; the wait is not work time.
        { id: "u-2", kind: "user_text", originatedBy: "user", createdAt: at(150), text: "One more" },
        { id: "a-3", kind: "agent_text", createdAt: at(165), text: "done again" },
        { id: "s-1", kind: "system", createdAt: at(400), text: "compacted" },
      ],
      tools: [
        { toolCallId: "t-1", name: "bash", status: "succeeded" },
        { toolCallId: "t-2", name: "edit", status: "failed" },
      ],
      artifacts: [{ id: "r-1", kind: "report", title: "Report", updatedAt: at(30) }],
      changedFiles: [{ path: "a.swift", status: "modified" }, { path: "b.swift", status: "added" }],
    }));

    expect(record).toMatchObject({
      activeDurationMs: 45 * 60_000,
      toolCallCount: 2,
      artifactCount: 1,
      changedFileCount: 2,
      subagentCount: 3,
      totalTokens: 0,
    });
  });

  it("counts successful file mutations once alongside explicitly reported files", () => {
    const record = pickleStatisticsRecord(session({
      changedFiles: [{ path: "src/app.ts", status: "M" }, { path: "deleted.ts", status: "D" }],
      tools: [
        { toolCallId: "edit-1", name: "edit", status: "succeeded", argsPreview: JSON.stringify({ path: "./src/app.ts", edits: [] }) },
        { toolCallId: "write-1", name: "write", status: "succeeded", argsPreview: JSON.stringify({ path: "/Users/example/picky/src/app.ts", content: "updated" }) },
        { toolCallId: "write-2", name: "write", status: "succeeded", argsPreview: JSON.stringify({ content: "new", path: "src/new.ts" }) },
        { toolCallId: "read-1", name: "read", status: "succeeded", argsPreview: '{"path":"read-only.ts"}' },
        { toolCallId: "edit-2", name: "edit", status: "failed", argsPreview: '{"path":"failed.ts"}' },
        { toolCallId: "write-3", name: "write", status: "running", argsPreview: '{"path":"pending.ts"}' },
      ],
    }));

    expect(record.changedFileCount).toBe(3);
  });

  it("recovers complete paths from truncated mutation previews without guessing missing paths", () => {
    const record = pickleStatisticsRecord(session({
      tools: [
        { toolCallId: "write-1", name: "write", status: "succeeded", argsPreview: '{"path":"src/quoted \\"name\\".ts","content":"long...' },
        { toolCallId: "edit-1", name: "edit", status: "succeeded", argsPreview: '{"path":"src/quoted \\"name\\".ts","edits":[...' },
        { toolCallId: "write-2", name: "write", status: "succeeded", argsPreview: '{"path":"src/incomplete...' },
        { toolCallId: "write-3", name: "write", status: "succeeded", argsPreview: '{"content":"\\"path\\":\\"fake.ts\\"...' },
        { toolCallId: "write-4", name: "write", status: "succeeded" },
        { toolCallId: "edit-2", name: "edit", status: "succeeded", argsPreview: '{"path":42}' },
        { toolCallId: "write-5", name: "write", status: "succeeded", argsPreview: '{"path":""}' },
      ],
    }));

    expect(record.changedFileCount).toBe(1);
  });

  it("keeps a bridge summary in statistics while withholding unavailable journal counts", () => {
    const record = pickleStatisticsRecord(session({ messageJournalAvailable: false }));
    expect(record).toMatchObject({ followUpCount: 0, delegationCount: 0, reviewCount: 2, category: "unclassified", activeDurationMs: 0 });
  });

  it("uses stable project labels for blank, home, and normal cwd values", () => {
    expect(projectNameForCwd(undefined, "/Users/example")).toBe("Picky");
    expect(projectNameForCwd("~", "/Users/example")).toBe("Picky");
    expect(projectNameForCwd("/Users/example", "/Users/example")).toBe("Home");
    expect(projectNameForCwd("/work/mobile/", "/Users/example")).toBe("mobile");
  });

  it("keeps Pi reasoning tokens within the reported output total", () => {
    const samples = aggregateUsageSamples([
      { messageId: "answer-1", timestamp: "2026-09-02T10:00:00.000Z", provider: "anthropic", model: "claude", inputTokens: 10, outputTokens: 20, cacheReadTokens: 4, cacheWriteTokens: 5 },
      { messageId: "answer-2", timestamp: "2026-09-02T12:00:00.000Z", provider: "anthropic", model: "claude", inputTokens: 1, outputTokens: 2, cacheReadTokens: 0, cacheWriteTokens: 1 },
    ], "picky");

    expect(samples).toEqual([{
      day: "2026-09-02",
      provider: "anthropic",
      model: "claude",
      project: "picky",
      inputTokens: 11,
      outputTokens: 22,
      cacheTokens: 10,
    }]);
  });
});
