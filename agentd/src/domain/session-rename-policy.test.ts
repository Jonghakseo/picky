import { describe, expect, it } from "vitest";
import { PICKLE_NAME_RULE_MESSAGE, isRenameNoOp, isUserAssignedTitle, normalizePickleRenameTitle, userRenameTitlePatch } from "./session-rename-policy.js";

describe("normalizePickleRenameTitle", () => {
  it("keeps the trimmed name a person typed", () => {
    expect(normalizePickleRenameTitle("  조사 결과 정리  ")).toBe("조사 결과 정리");
  });

  it("accepts a 200 codepoint name and rejects the next one", () => {
    expect(normalizePickleRenameTitle("가".repeat(200))).toHaveLength(200);
    expect(() => normalizePickleRenameTitle("가".repeat(201))).toThrow(PICKLE_NAME_RULE_MESSAGE);
  });

  it("measures emoji by codepoint, not UTF-16 unit", () => {
    // 150 astral codepoints are 300 UTF-16 units; the limit is about what a person reads.
    expect(normalizePickleRenameTitle("🥒".repeat(150))).toBe("🥒".repeat(150));
  });

  it("rejects an empty or whitespace-only name", () => {
    for (const raw of ["", "   ", "\t"]) expect(() => normalizePickleRenameTitle(raw)).toThrow(PICKLE_NAME_RULE_MESSAGE);
  });

  it("rejects line breaks and control characters even when trimming would hide them", () => {
    for (const raw of ["first\nsecond", "name\r", "tab\tname", "bell\u0007"]) {
      expect(() => normalizePickleRenameTitle(raw)).toThrow(PICKLE_NAME_RULE_MESSAGE);
    }
  });
});

describe("title origin", () => {
  it("treats only an explicit user origin as owned by the user", () => {
    expect(isUserAssignedTitle({ titleOrigin: "user" })).toBe(true);
    expect(isUserAssignedTitle({ titleOrigin: undefined })).toBe(false);
  });

  it("writes the title and its origin together", () => {
    expect(userRenameTitlePatch("이름")).toEqual({ title: "이름", titleOrigin: "user" });
  });

  it("is a no-op only when the same name is already user-owned", () => {
    expect(isRenameNoOp({ title: "이름", titleOrigin: "user" }, "이름")).toBe(true);
    // Same text, but Pi picked it: the rename must still record the user origin.
    expect(isRenameNoOp({ title: "이름", titleOrigin: undefined }, "이름")).toBe(false);
    expect(isRenameNoOp({ title: "다른 이름", titleOrigin: "user" }, "이름")).toBe(false);
  });
});
