import { describe, expect, it } from "vitest";
import { nextRevision } from "./session-revision-policy.js";

describe("nextRevision", () => {
  it("increments a changed commit exactly once", () => {
    expect(nextRevision(4, true)).toBe(5);
  });

  it("preserves revision for a semantic no-op", () => {
    expect(nextRevision(4, false)).toBe(4);
  });

  it("rejects changed commits at the safe integer ceiling", () => {
    expect(() => nextRevision(Number.MAX_SAFE_INTEGER, true)).toThrow(/maximum safe revision/i);
  });

  it.each([
    [-1, true],
    [-1, false],
    [1.5, true],
    [Number.NaN, true],
    [Number.POSITIVE_INFINITY, true],
    [Number.MAX_SAFE_INTEGER + 1, true],
  ])("rejects invalid current revision %p", (current, changed) => {
    expect(() => nextRevision(current, changed)).toThrow(/invalid session revision/i);
  });
});
