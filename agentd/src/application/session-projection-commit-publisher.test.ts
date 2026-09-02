import { describe, expect, it, vi } from "vitest";
import { PickyAgentSessionSchema, type PickyAgentSessionParsed } from "../protocol.js";
import { projectionCommitRevision, publishSessionProjectionCommit, sessionProjectionCommitMutations } from "./session-projection-commit-publisher.js";

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

    publishSessionProjectionCommit({ emit }, undefined, after, [], "epoch-1");

    expect(emit).toHaveBeenCalledTimes(1);
    expect(emit).toHaveBeenCalledWith("sessionProjectionSnapshot", after, "epoch-1");
  });

  it("publishes the ordered transaction for a changed existing session", () => {
    const emit = vi.fn();
    const before = session();
    const after = session({ title: "Renamed", revision: 2 });

    publishSessionProjectionCommit({ emit }, before, after, sessionProjectionCommitMutations(before, after), "epoch-2");

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

    publishSessionProjectionCommit({ emit }, unchanged, unchanged, sessionProjectionCommitMutations(unchanged, unchanged), "epoch-3");

    expect(emit).not.toHaveBeenCalled();
  });
});

describe("projectionCommitRevision", () => {
  it("advances the chain only when the commit produces a mutation", () => {
    expect(projectionCommitRevision(41, [{ type: "metaPatch", patch: { title: "Renamed" } }])).toBe(42);
  });

  // A projection-invisible commit that still bumped the revision left the next
  // transaction pointing at a revision the client never received, permanently
  // stalling that session cursor.
  it("keeps the revision when the commit produces no mutation", () => {
    expect(projectionCommitRevision(41, [])).toBe(41);
  });

  it("leaves no gap across a projection-invisible commit", () => {
    const before = session({ revision: 41 });
    // Same projected content, different object: the old reference-inequality
    // check treated this as a change and burned revision 42.
    const invisible = { ...before };
    const invisibleMutations = sessionProjectionCommitMutations(before, invisible);
    const afterInvisible = { ...invisible, revision: projectionCommitRevision(before.revision ?? 0, invisibleMutations) };

    const visible = { ...afterInvisible, title: "Renamed" };
    const visibleMutations = sessionProjectionCommitMutations(afterInvisible, visible);
    const afterVisible = { ...visible, revision: projectionCommitRevision(afterInvisible.revision ?? 0, visibleMutations) };

    expect(invisibleMutations).toHaveLength(0);
    expect(afterInvisible.revision).toBe(41);
    expect(afterVisible.revision).toBe(42);
    // baseRevision the client receives is the last revision it actually saw.
    expect(afterInvisible.revision).toBe(before.revision);
  });
});
