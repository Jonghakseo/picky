import { describe, expect, it } from "vitest";
import type { PickyAgentSession } from "../protocol.js";
import { isSemanticNoOpPatch } from "./session-patch-policy.js";

const current = (): PickyAgentSession => ({
  id: "session-1",
  title: "Investigate completion lag",
  status: "running",
  createdAt: "2026-08-24T13:00:00.000Z",
  updatedAt: "2026-08-24T13:00:01.000Z",
  logs: [],
  tools: [],
  artifacts: [{
    id: "artifact-1",
    kind: "link",
    title: "Pull request",
    url: "https://github.com/creatrip/picky/pull/123",
    updatedAt: "2026-08-24T13:00:01.000Z",
  }],
  changedFiles: [],
  messages: [],
  thinkingPreview: "Inspecting runtime events",
});

describe("isSemanticNoOpPatch", () => {
  it("treats an equal scalar patch as a no-op and detects a changed scalar", () => {
    expect(isSemanticNoOpPatch(current(), { title: "Investigate completion lag" })).toBe(true);
    expect(isSemanticNoOpPatch(current(), { title: "Investigate a different problem" })).toBe(false);
  });

  it("compares nested arrays and objects structurally", () => {
    expect(isSemanticNoOpPatch(current(), {
      artifacts: [{
        id: "artifact-1",
        kind: "link",
        title: "Pull request",
        url: "https://github.com/creatrip/picky/pull/123",
        updatedAt: "2026-08-24T13:00:01.000Z",
      }],
    })).toBe(true);
    expect(isSemanticNoOpPatch(current(), {
      artifacts: [{
        id: "artifact-1",
        kind: "link",
        title: "Different pull request",
        url: "https://github.com/creatrip/picky/pull/123",
        updatedAt: "2026-08-24T13:00:01.000Z",
      }],
    })).toBe(false);
  });

  it("distinguishes an absent key from an own undefined key", () => {
    expect(isSemanticNoOpPatch(current(), {})).toBe(true);
    expect(isSemanticNoOpPatch(current(), { thinkingPreview: undefined })).toBe(false);
    expect(isSemanticNoOpPatch({ ...current(), thinkingPreview: undefined }, { thinkingPreview: undefined })).toBe(true);
  });

  it("always excludes updatedAt from semantic equality", () => {
    expect(isSemanticNoOpPatch(current(), { updatedAt: "2030-01-01T00:00:00.000Z" })).toBe(true);
  });

  it("detects a changed key among otherwise equal values", () => {
    expect(isSemanticNoOpPatch(current(), {
      title: "Investigate completion lag",
      status: "completed",
      updatedAt: "2030-01-01T00:00:00.000Z",
    })).toBe(false);
  });
});
