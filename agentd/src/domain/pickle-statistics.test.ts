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

  it("keeps a bridge summary in statistics while withholding unavailable journal counts", () => {
    const record = pickleStatisticsRecord(session({ messageJournalAvailable: false }));
    expect(record).toMatchObject({ followUpCount: 0, delegationCount: 0, reviewCount: 2, category: "unclassified" });
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
