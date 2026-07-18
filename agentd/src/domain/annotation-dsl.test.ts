import { describe, expect, it } from "vitest";
import { AnnotationDslParser, ANNOTATION_DSL_TAG_OPEN_PATTERN } from "./annotation-dsl.js";

describe("AnnotationDslParser", () => {
  it("extracts valid tags and removes them from clean text", () => {
    const parser = new AnnotationDslParser();
    const result = parser.feed('먼저 여기예요. [TARGET: x=200 y=100 r=30 ttl=8000 label="저장"] 다음을 보세요.');

    expect(result.cleanText).toBe("먼저 여기예요. 다음을 보세요.");
    expect(result.droppedTags).toEqual([]);
    expect(result.healedTags).toEqual([]);
    expect(result.completedTags).toEqual([
      {
        kind: "annotation",
        annotation: { id: "dsl-1", shape: "target", x: 200, y: 100, r: 30, ttlMs: 8000, label: "저장" },
      },
    ]);
  });

  it("buffers a tag split across three deltas and supports quoted brackets and escapes", () => {
    const parser = new AnnotationDslParser();
    expect(parser.feed("설명을 ")).toMatchObject({ cleanText: "설명을 ", completedTags: [] });
    expect(parser.feed('[CIRCLE: x=20 y=30 r=40 ttl=')).toMatchObject({ cleanText: "", completedTags: [] });
    const result = parser.feed('6000 label="A ] \\"B\\""] 계속');

    expect(result.cleanText).toBe(" 계속");
    expect(result.completedTags).toEqual([
      {
        kind: "annotation",
        annotation: { id: "dsl-1", shape: "circle", x: 20, y: 30, r: 40, ttlMs: 6000, label: 'A ] "B"' },
      },
    ]);
  });

  it("drops unknown and malformed tags without exposing them", () => {
    const parser = new AnnotationDslParser();
    const result = parser.feed("A [POINT: x=1] B [UNKNOWN: x=1] C [LABEL: x=1 y=2 ttl=500]");

    expect(result.cleanText).toBe("A B C");
    expect(result.completedTags).toEqual([]);
    expect(result.droppedTags).toHaveLength(3);
  });

  it("passes markdown through and drops a partial DSL tag at turn end", () => {
    const parser = new AnnotationDslParser();
    expect(parser.feed("[guide](https://example.test) and [POI")).toEqual({ cleanText: "[guide](https://example.test) and ", completedTags: [], droppedTags: [], healedTags: [] });
    expect(parser.finish()).toEqual({ cleanText: "", completedTags: [], droppedTags: ["unclosed DSL tag at turn end"], healedTags: [] });
  });

  it("keeps SCREEN state for subsequent tags and clamps ttl", () => {
    const parser = new AnnotationDslParser();
    const result = parser.feed("[SCREEN: id=screen-2] [POINT: x=1 y=2 ttl=1] [RECT: x=3 y=4 w=5 h=6 ttl=999999]");

    expect(result.cleanText).toBe("");
    expect(result.healedTags).toEqual([]);
    expect(result.completedTags).toEqual([
      { kind: "screen", screenId: "screen-2" },
      { kind: "point", x: 1, y: 2, ttlMs: 500, screenId: "screen-2" },
      { kind: "annotation", screenId: "screen-2", annotation: { id: "dsl-1", shape: "rect", x: 3, y: 4, w: 5, h: 6, ttlMs: 60000 } },
    ]);
  });

  it("heals verb case and surrounding whitespace, while unknown verbs still drop", () => {
    const parser = new AnnotationDslParser();
    const result = parser.feed("[ Point : x=1 y=2 ttl=6000 ] [ARROW: x=1 y=2 ttl=6000]");

    expect(result.completedTags).toEqual([{ kind: "point", x: 1, y: 2, ttlMs: 6000 }]);
    expect(result.healedTags).toEqual(["POINT: verb case/whitespace"]);
    expect(result.droppedTags).toEqual(["unknown verb ARROW"]);
  });

  it("heals argument spacing and single separators but rejects consecutive separators", () => {
    const parser = new AnnotationDslParser();
    const healed = parser.feed("[RECT: x = 120, y = 340, w=20; h=30, ttl=6000]");
    const dropped = parser.feed("[RECT: x=1,, y=2 w=3 h=4 ttl=6000]");

    expect(healed.completedTags[0]).toMatchObject({ kind: "annotation", annotation: { shape: "rect", x: 120, y: 340, w: 20, h: 30 } });
    expect(healed.healedTags).toEqual(["RECT: argument spacing/separator"]);
    expect(dropped.completedTags).toEqual([]);
    expect(dropped.droppedTags).toHaveLength(1);
  });

  it("heals smart quotes and unquoted single-token label values but rejects multi-word bare labels", () => {
    const parser = new AnnotationDslParser();
    const smart = parser.feed("[POINT: x=1 y=2 ttl=6000 label=“저장”]");
    const bare = parser.feed("[POINT: x=3 y=4 ttl=6000 label=저장버튼]");
    const multiWord = parser.feed("[POINT: x=5 y=6 ttl=6000 label=저장 버튼]");

    expect(smart.completedTags[0]).toMatchObject({ kind: "point", label: "저장" });
    expect(smart.healedTags).toEqual(["POINT: smart quotes"]);
    expect(bare.completedTags[0]).toMatchObject({ kind: "point", label: "저장버튼" });
    expect(bare.healedTags).toEqual(["POINT: unquoted single-token label"]);
    expect(multiWord.completedTags).toEqual([]);
    expect(multiWord.droppedTags).toHaveLength(1);
  });

  it("heals px units and rounds float coordinates while rejecting unparseable coordinates", () => {
    const parser = new AnnotationDslParser();
    const healed = parser.feed("[TARGET: x=120.5px y=340.4px r=24.5 ttl=6000]");
    const dropped = parser.feed("[TARGET: x=left y=340 r=24 ttl=6000]");

    expect(healed.completedTags[0]).toMatchObject({ kind: "annotation", annotation: { x: 121, y: 340, r: 25 } });
    expect(healed.healedTags).toEqual(["TARGET: numeric px unit, rounded float"]);
    expect(dropped.completedTags).toEqual([]);
    expect(dropped.droppedTags).toHaveLength(1);
  });

  it("defaults missing ttl, clamps explicit ttl, and lets the last duplicate key win", () => {
    const parser = new AnnotationDslParser();
    const defaulted = parser.feed("[POINT: x=1 y=2]");
    const duplicate = parser.feed("[POINT: x=1 x=9 y=2 ttl=999999]");
    const invalidTtl = parser.feed("[POINT: x=1 y=2 ttl=forever]");

    expect(defaulted.completedTags).toEqual([{ kind: "point", x: 1, y: 2, ttlMs: 6000 }]);
    expect(defaulted.healedTags).toEqual(["POINT: default ttl"]);
    expect(duplicate.completedTags).toEqual([{ kind: "point", x: 9, y: 2, ttlMs: 60000 }]);
    expect(duplicate.healedTags).toEqual(["POINT: duplicate key last-wins"]);
    expect(invalidTtl.completedTags).toEqual([]);
    expect(invalidTtl.droppedTags).toHaveLength(1);
  });

  it("ignores unknown extra keys but hard-drops nested tags and unterminated quotes", () => {
    const parser = new AnnotationDslParser();
    const extra = parser.feed("[POINT: x=1 y=2 ttl=6000 confidence=high]");
    const nested = parser.feed("[POINT: x=1 y=[TARGET: x=2 y=3 r=4 ttl=6000] ttl=6000]");
    const unterminated = parser.feed("[POINT: x=1 y=2 ttl=6000 label=\"broken]");

    expect(extra.completedTags).toEqual([{ kind: "point", x: 1, y: 2, ttlMs: 6000 }]);
    expect(extra.healedTags).toEqual(["POINT: unknown key ignored"]);
    expect(nested.completedTags).toEqual([]);
    expect(nested.droppedTags).toHaveLength(1);
    expect(nested.cleanText).toBe("");
    expect(unterminated.completedTags).toEqual([]);
    expect(unterminated.cleanText).toBe("");
    expect(parser.finish().droppedTags).toEqual(["unclosed DSL tag at turn end"]);
  });

  it("is deterministic and can mix a healed tag with a dropped tag", () => {
    const input = "앞 [point: x=1.5 y=2px label=저장,] 중간 [ARROW: x=1 y=2] 뒤";
    const first = new AnnotationDslParser().feed(input);
    const second = new AnnotationDslParser().feed(input);

    expect(first).toEqual(second);
    expect(first.cleanText).toBe("앞 중간 뒤");
    expect(first.completedTags).toEqual([{ kind: "point", x: 2, y: 2, label: "저장", ttlMs: 6000 }]);
    expect(first.droppedTags).toEqual(["unknown verb ARROW"]);
    expect(first.healedTags).toEqual(["POINT: verb case/whitespace, argument spacing/separator, unquoted single-token label, numeric px unit, rounded float, default ttl"]);
  });

  it("preserves one trailing separator space when the next delta begins with a word", () => {
    const parser = new AnnotationDslParser();
    const first = parser.feed("먼저 [POINT: x=1 y=2 ttl=6000] ");
    const second = parser.feed("다음");

    expect(`${first.cleanText}${second.cleanText}`).toBe("먼저 다음");
  });

  it("recognizes lowercase and whitespace-tolerant bracketed DSL tags", () => {
    expect(ANNOTATION_DSL_TAG_OPEN_PATTERN.test("[ POINT : x=1]")).toBe(true);
    expect(ANNOTATION_DSL_TAG_OPEN_PATTERN.test("[point: x=1]")).toBe(true);
  });
});
