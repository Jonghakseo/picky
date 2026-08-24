import { describe, expect, it } from "vitest";
import { buildToolResultPreview, isJSONObjectOrArrayText } from "./tool-result-preview.js";

describe("buildToolResultPreview", () => {
  it("keeps complete JSON unchanged", () => {
    expect(buildToolResultPreview({ ok: true, count: 2 })).toEqual({
      text: '{"ok":true,"count":2}',
      truncated: false,
      repaired: false,
    });
  });

  it.each([
    ['{"message":"visible text', "visible text"],
    ['{"count":12', "12"],
    ['{"items":[{"name":"first"},{"name":"second', "second"],
    ['[1,2,3', "3"],
  ])("repairs truncated JSON while retaining its visible tail", (source, visibleTail) => {
    const result = buildToolResultPreview(source);

    expect(result.repaired).toBe(true);
    expect(result.text).toBe(source);
    expect(result.jsonText).toContain(visibleTail);
    expect(() => JSON.parse(result.jsonText!)).not.toThrow();
  });

  it("reduces the source prefix until deeply nested repaired JSON fits the budget", () => {
    const source = JSON.stringify({ levels: Array.from({ length: 30 }, (_, index) => ({ index, value: "x".repeat(40) })) });
    const result = buildToolResultPreview(source, 120);

    expect(result.truncated).toBe(true);
    expect(result.repaired).toBe(true);
    expect(result.text).toHaveLength(120);
    expect(result.text?.endsWith("...")).toBe(true);
    expect(result.jsonText!.length).toBeLessThanOrEqual(120);
    expect(() => JSON.parse(result.jsonText!)).not.toThrow();
  });

  it("repairs legacy fixed-budget JSON previews ending in three dots", () => {
    const prefix = '{"content":[{"type":"text","text":"';
    const maxChars = 80;
    const source = `${prefix}${"x".repeat(maxChars - prefix.length - 3)}...`;
    const result = buildToolResultPreview(source, maxChars);

    expect(source).toHaveLength(maxChars);
    expect(result.truncated).toBe(true);
    expect(result.repaired).toBe(true);
    expect(result.text).toBe(source);
    expect(result.text?.endsWith("...")).toBe(true);
    expect(result.jsonText!.length).toBeLessThanOrEqual(maxChars);
    expect(() => JSON.parse(result.jsonText!)).not.toThrow();
  });

  it("repairs malformed JSON below the budget without marking it partial", () => {
    const result = buildToolResultPreview("{name: 'Picky'}");

    expect(result).toEqual({
      text: "{name: 'Picky'}",
      jsonText: '{"name": "Picky"}',
      truncated: false,
      repaired: true,
    });
  });

  it("keeps non-JSON text unchanged and bounds long text with the existing ellipsis", () => {
    expect(buildToolResultPreview("plain output")).toEqual({ text: "plain output", truncated: false, repaired: false });
    expect(buildToolResultPreview("abcdefgh", 6)).toEqual({ text: "abc...", truncated: true, repaired: false });
  });

  it("falls back to bounded plain text when repair cannot produce JSON", () => {
    const result = buildToolResultPreview("{\u0000broken", 8);

    expect(result).toEqual({ text: "{\u0000broken", truncated: false, repaired: false });
  });

  it("never splits a UTF-16 surrogate pair at the preview boundary", () => {
    const result = buildToolResultPreview(`plain ${"x".repeat(4)}😀tail`, 12);

    expect(result.truncated).toBe(true);
    expect(result.text).not.toContain("\ud83d");
    expect(Buffer.from(result.text!, "utf8").toString("utf8")).toBe(result.text);
  });

  it("recognizes only parsed object and array previews as structured JSON", () => {
    expect(isJSONObjectOrArrayText('{"ok":true}')).toBe(true);
    expect(isJSONObjectOrArrayText(" [1,2] ")).toBe(true);
    expect(isJSONObjectOrArrayText('"text"')).toBe(false);
    expect(isJSONObjectOrArrayText("plain")).toBe(false);
  });
});
