import { describe, expect, it, vi } from "vitest";
import { PickyAgentSessionSchema, type PickyAgentSessionParsed } from "../protocol.js";
import { publishSessionProjectionCommit } from "./session-projection-commit-publisher.js";

function session(overrides: Partial<PickyAgentSessionParsed> = {}): PickyAgentSessionParsed {
  return PickyAgentSessionSchema.parse({
    id: "projection-commit-session",
    title: "Projection commit session",
    status: "running",
    cwd: "/tmp/project",
    createdAt: "2026-08-27T00:00:00.000Z",
    updatedAt: "2026-08-27T00:00:01.000Z",
    logs: [],
    tools: [],
    subagentRuns: [],
    artifacts: [],
    changedFiles: [],
    messages: [],
    revision: 1,
    ...overrides,
  });
}

describe("session projection commit publisher", () => {
  it("publishes a snapshot for a newly committed session", () => {
    const emit = vi.fn();
    const after = session();

    publishSessionProjectionCommit({ emit }, undefined, after, {}, "epoch-1");

    expect(emit).toHaveBeenCalledTimes(1);
    expect(emit).toHaveBeenCalledWith("sessionProjectionSnapshot", after, "epoch-1");
  });

  it("publishes the ordered transaction for a changed existing session", () => {
    const emit = vi.fn();
    const before = session();
    const after = session({ title: "Renamed", revision: 2 });

    publishSessionProjectionCommit({ emit }, before, after, {}, "epoch-2");

    expect(emit).toHaveBeenCalledTimes(1);
    expect(emit).toHaveBeenCalledWith(
      "sessionProjectionTransaction",
      after.id,
      before,
      after,
      [{ type: "metaPatch", patch: { title: "Renamed" } }],
      "epoch-2",
    );
  });

  it("does not publish an empty transaction", () => {
    const emit = vi.fn();
    const unchanged = session();

    publishSessionProjectionCommit({ emit }, unchanged, unchanged, {}, "epoch-3");

    expect(emit).not.toHaveBeenCalled();
  });
});
