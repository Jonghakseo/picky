import { describe, expect, it } from "vitest";
import { decideSnapshot, decideTransaction } from "./room-sync";

describe("decideTransaction", () => {
  const held = { epoch: "e1", revision: 7 };

  it("applies the transaction that continues the revision chain", () => {
    expect(decideTransaction(held, { epoch: "e1", baseRevision: 7, revision: 8 }, false)).toBe("apply");
  });

  it("asks for a snapshot when a revision is missing", () => {
    expect(decideTransaction(held, { epoch: "e1", baseRevision: 9, revision: 10 }, false)).toBe("resync");
  });

  it("asks for a snapshot when the owning daemon changed epoch", () => {
    expect(decideTransaction(held, { epoch: "e2", baseRevision: 7, revision: 8 }, false)).toBe("resync");
  });

  it("asks for a snapshot before the first one arrives", () => {
    expect(decideTransaction(undefined, { epoch: "e1", baseRevision: 0, revision: 1 }, false)).toBe("resync");
  });

  it("drops a frame that was already folded instead of resyncing", () => {
    expect(decideTransaction(held, { epoch: "e1", baseRevision: 5, revision: 6 }, false)).toBe("ignore");
  });

  it("drops every frame while a resync is in flight", () => {
    expect(decideTransaction(held, { epoch: "e1", baseRevision: 7, revision: 8 }, true)).toBe("ignore");
    expect(decideTransaction(held, { epoch: "e2", baseRevision: 0, revision: 1 }, true)).toBe("ignore");
  });
});

describe("decideSnapshot", () => {
  it("takes a snapshot from a new epoch", () => {
    expect(decideSnapshot({ epoch: "e1", revision: 9 }, { epoch: "e2", revision: 1 })).toBe("apply");
  });

  it("takes a newer snapshot of the same epoch", () => {
    expect(decideSnapshot({ epoch: "e1", revision: 9 }, { epoch: "e1", revision: 12 })).toBe("apply");
  });

  it("drops a stale snapshot of the same epoch", () => {
    expect(decideSnapshot({ epoch: "e1", revision: 9 }, { epoch: "e1", revision: 4 })).toBe("ignore");
  });
});
