import { describe, expect, it } from "vitest";
import { sessionWithAppendedLog } from "./session-log-append.js";
import type { PickyAgentSession } from "./protocol.js";

const NOW = "2026-08-05T00:00:00.000Z";

function makeSession(overrides: Partial<PickyAgentSession> = {}): PickyAgentSession {
  return {
    id: "session-test",
    title: "Test",
    status: "running",
    cwd: "/tmp",
    createdAt: "2026-08-04T00:00:00.000Z",
    updatedAt: "2026-08-04T00:00:00.000Z",
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
    activitySummary: { read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 },
    ...overrides,
  };
}

describe("sessionWithAppendedLog", () => {
  it("appends the line and stamps updatedAt without mutating the input", () => {
    const session = makeSession({ logs: ["first"] });

    const next = sessionWithAppendedLog(session, "second", NOW);

    expect(next.logs).toEqual(["first", "second"]);
    expect(next.updatedAt).toBe(NOW);
    expect(session.logs).toEqual(["first"]);
  });

  it("merges changed files disclosed by the log line", () => {
    const session = makeSession({ changedFiles: [{ path: "kept.ts", status: "M" }] });

    const next = sessionWithAppendedLog(session, "Changed file: A src/new.ts - added", NOW);

    expect(next.changedFiles).toEqual(
      expect.arrayContaining([
        { path: "kept.ts", status: "M" },
        { path: "src/new.ts", status: "A", summary: "added" },
      ]),
    );
  });

  it("records link artifacts found in user input lines", () => {
    const next = sessionWithAppendedLog(makeSession(), "follow-up: see https://github.com/o/r/pull/7", NOW);

    expect(next.artifacts).toHaveLength(1);
    expect(next.artifacts[0]?.url).toBe("https://github.com/o/r/pull/7");
  });

  it("ignores links in lines that are not user input", () => {
    const next = sessionWithAppendedLog(makeSession(), "tool output https://github.com/o/r/pull/7", NOW);

    expect(next.artifacts).toEqual([]);
  });

  it("does not duplicate a link artifact the session already carries", () => {
    const url = "https://github.com/o/r/pull/7";
    const session = makeSession({
      artifacts: [{ id: "existing", kind: "github", title: "PR #7", url, updatedAt: NOW }],
    });

    const next = sessionWithAppendedLog(session, `follow-up: ${url}`, NOW);

    expect(next.artifacts).toHaveLength(1);
    expect(next.artifacts[0]?.id).toBe("existing");
  });

  it("captures the Pi session file path when the line discloses one", () => {
    const next = sessionWithAppendedLog(makeSession(), "pi session: /tmp/session.jsonl", NOW);

    expect(next.piSessionFilePath).toBe("/tmp/session.jsonl");
  });

  it("leaves an existing Pi session file path untouched for unrelated lines", () => {
    const session = makeSession({ piSessionFilePath: "/tmp/original.jsonl" });

    const next = sessionWithAppendedLog(session, "just a log line", NOW);

    expect(next.piSessionFilePath).toBe("/tmp/original.jsonl");
  });
});
