import { describe, expect, it } from "vitest";

import { neighbourRoom } from "./layout";

describe("moving between rooms with Option-arrows", () => {
  const order = ["main", "s1", "s2"];

  it("opens the next or previous room in list order and stops at the ends", () => {
    expect(neighbourRoom(order, "s1", 1)).toBe("s2");
    expect(neighbourRoom(order, "s1", -1)).toBe("main");
    expect(neighbourRoom(order, "s2", 1)).toBeUndefined();
    expect(neighbourRoom(order, "main", -1)).toBeUndefined();
  });

  it("starts from the top or bottom when no listed room is open", () => {
    expect(neighbourRoom(order, undefined, 1)).toBe("main");
    expect(neighbourRoom(order, "hidden-by-filter", -1)).toBe("s2");
    expect(neighbourRoom([], undefined, 1)).toBeUndefined();
  });
});
