import { describe, expect, it } from "vitest";
import { parsePointerTags } from "./pointer-tag-parser.js";

describe("pointer tag parser", () => {
  it("strips a single point tag and returns screenshot-pixel coordinates", () => {
    expect(parsePointerTags("여기를 누르면 돼요. [POINT:420,180:검색창:screen1]")).toEqual({
      text: "여기를 누르면 돼요.",
      points: [{ x: 420, y: 180, label: "검색창", screenId: "screen1" }],
      explicitNone: false,
    });
  });

  it("parses multiple point tags in order", () => {
    expect(parsePointerTags("첫 번째, 그다음 두 번째예요. [POINT:10,20:첫 번째:screen1] [POINT:30,40:두 번째:screen2]")).toEqual({
      text: "첫 번째, 그다음 두 번째예요.",
      points: [
        { x: 10, y: 20, label: "첫 번째", screenId: "screen1" },
        { x: 30, y: 40, label: "두 번째", screenId: "screen2" },
      ],
      explicitNone: false,
    });
  });

  it("supports POINT none and suppresses point output", () => {
    expect(parsePointerTags("개념 설명이라 가리킬 건 없어요. [POINT:none]")).toEqual({
      text: "개념 설명이라 가리킬 건 없어요.",
      points: [],
      explicitNone: true,
    });
  });
});
