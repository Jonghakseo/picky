import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { PickyAgentSessionSchema } from "../protocol.js";
import {
  persistedSessionFieldOwnership,
  parseSessionFieldOwnership,
  parseSessionTransientOwnership,
  requiredTransientOwnershipIds,
  transientSessionOwnership,
} from "./session-projection-ownership.js";

const dedicatedFields = new Set([
  "messages",
  "logs",
  "tools",
  "todoState",
  "subagentRuns",
  "artifacts",
  "changedFiles",
  "queuedSteers",
  "queuedFollowUps",
  "steeringMode",
  "followUpMode",
  "activitySummary",
  "finalAnswer",
  "pendingExtensionUiRequest",
]);

describe("session projection ownership", () => {
  it("covers exactly every persisted session field", () => {
    expect(new Set(persistedSessionFieldOwnership.map((entry) => entry.field))).toEqual(
      new Set(Object.keys(PickyAgentSessionSchema.shape)),
    );
  });

  it("assigns dedicated mutations to live projection fields", () => {
    for (const entry of persistedSessionFieldOwnership) {
      if (!dedicatedFields.has(entry.field)) continue;
      expect(entry.v2Mutation).not.toEqual("metaPatch");
    }
  });

  it("documents exactly the terminal-relevant transient owners", () => {
    expect(new Set(transientSessionOwnership.map((entry) => entry.id))).toEqual(
      new Set(requiredTransientOwnershipIds),
    );
  });

  it("rejects malformed and duplicate manifest rows", () => {
    expect(() => parseSessionFieldOwnership("not json")).toThrow();

    const persisted = JSON.parse(readFileSync(new URL("../../../contracts/projection/session-field-ownership.json", import.meta.url), "utf8"));
    persisted.push({ ...persisted[0] });
    expect(() => parseSessionFieldOwnership(JSON.stringify(persisted))).toThrow(/Duplicate/);

    const transient = JSON.parse(readFileSync(new URL("../../../contracts/projection/session-transient-ownership.json", import.meta.url), "utf8"));
    transient.push({ ...transient[0] });
    expect(() => parseSessionTransientOwnership(JSON.stringify(transient))).toThrow(/Duplicate/);
  });
});
