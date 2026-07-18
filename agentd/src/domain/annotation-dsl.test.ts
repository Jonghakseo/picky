import { describe, expect, it } from "vitest";
import { AnnotationDslParser, ANNOTATION_DSL_TAG_OPEN_PATTERN } from "./annotation-dsl.js";

describe("AnnotationDslParser", () => {
  it("extracts valid tags and removes them from clean text", () => {
    const parser = new AnnotationDslParser();
    const result = parser.feed('먼저 여기예요. [RECT: x=200 y=100 w=30 h=30 label="저장"] 다음을 보세요.');

    expect(result.cleanText).toBe("먼저 여기예요. 다음을 보세요.");
    expect(result.droppedTags).toEqual([]);
    expect(result.healedTags).toEqual([]);
    expect(result.completedTags).toEqual([
      {
        kind: "annotation",
        annotation: { id: "dsl-1", shape: "rect", x: 200, y: 100, w: 30, h: 30, label: "저장" },
      },
    ]);
    expect(result.streamItems).toEqual([
      { kind: "text", text: "먼저 여기예요. " },
      { kind: "tag", tag: result.completedTags[0] },
      { kind: "text", text: " 다음을 보세요." },
    ]);
  });

  it("parses optional RECT and LINE spotlight flags", () => {
    const parser = new AnnotationDslParser();
    const result = parser.feed("[RECT: x=95 y=157 w=120 h=35 spotlight] [LINE: x1=1 y1=2 x2=3 y2=4 spotlight=true] [RECT: x=5 y=6 w=7 h=8 spotlight=false] [LINE: x1=1 y1=2 x2=3 y2=4]");

    expect(result.completedTags).toEqual([
      { kind: "annotation", annotation: { id: "dsl-1", shape: "rect", x: 95, y: 157, w: 120, h: 35, spotlight: true } },
      { kind: "annotation", annotation: { id: "dsl-2", shape: "line", x1: 1, y1: 2, x2: 3, y2: 4, spotlight: true } },
      { kind: "annotation", annotation: { id: "dsl-3", shape: "rect", x: 5, y: 6, w: 7, h: 8, spotlight: false } },
      { kind: "annotation", annotation: { id: "dsl-4", shape: "line", x1: 1, y1: 2, x2: 3, y2: 4 } },
    ]);
  });

  it("treats empty and whitespace-only labels as omitted", () => {
    const parser = new AnnotationDslParser();
    const result = parser.feed('[POINT: x=1 y=2 label=""] [RECT: x=3 y=4 w=5 h=6 label="   "] [LINE: x1=7 y1=8 x2=9 y2=10 label=""]');

    expect(result.completedTags).toEqual([
      { kind: "point", x: 1, y: 2 },
      { kind: "annotation", annotation: { id: "dsl-1", shape: "rect", x: 3, y: 4, w: 5, h: 6 } },
      { kind: "annotation", annotation: { id: "dsl-2", shape: "line", x1: 7, y1: 8, x2: 9, y2: 10 } },
    ]);
    expect(result.droppedTags).toEqual([]);
  });

  it("heals truthy spotlight values and ignores unknown bare arguments deterministically", () => {
    const parser = new AnnotationDslParser();
    const result = parser.feed("[RECT: x=1 y=2 w=3 h=4 spotlight=on extraneous]");

    expect(result.completedTags[0]).toMatchObject({ kind: "annotation", annotation: { shape: "rect", spotlight: true } });
    expect(result.healedTags).toEqual(["RECT: boolean value, unknown key ignored"]);
  });

  it("buffers a tag split across deltas and supports quoted brackets and escapes", () => {
    const parser = new AnnotationDslParser();
    expect(parser.feed("설명을 ")).toMatchObject({ cleanText: "설명을 ", completedTags: [] });
    expect(parser.feed("[RECT: x=20 y=30 w=40")).toMatchObject({ cleanText: "", completedTags: [] });
    const result = parser.feed(' h=40 label="A ] \\"B\\""] 계속');

    expect(result.cleanText).toBe(" 계속");
    expect(result.completedTags).toEqual([
      {
        kind: "annotation",
        annotation: { id: "dsl-1", shape: "rect", x: 20, y: 30, w: 40, h: 40, label: 'A ] "B"' },
      },
    ]);
  });

  it("drops unknown and malformed tags without exposing them", () => {
    const parser = new AnnotationDslParser();
    const result = parser.feed("A [POINT: x=1] B [UNKNOWN: x=1] C [LINE: x1=1 y1=2 x2=3]");

    expect(result.cleanText).toBe("A B C");
    expect(result.completedTags).toEqual([]);
    expect(result.droppedTags).toHaveLength(3);
  });

  it("passes markdown through and drops a partial DSL tag at turn end", () => {
    const parser = new AnnotationDslParser();
    expect(parser.feed("[guide](https://example.test) and [POI")).toEqual({
      cleanText: "[guide](https://example.test) and ",
      completedTags: [],
      streamItems: [{ kind: "text", text: "[guide](https://example.test) and " }],
      droppedTags: [],
      healedTags: [],
    });
    expect(parser.finish()).toEqual({ cleanText: "", completedTags: [], streamItems: [], droppedTags: ["unclosed DSL tag at turn end"], healedTags: [] });
  });

  it("keeps SCREEN state for subsequent tags", () => {
    const parser = new AnnotationDslParser();
    const result = parser.feed("[SCREEN: id=screen-2] [POINT: x=1 y=2] [RECT: x=3 y=4 w=5 h=6]");

    expect(result.cleanText).toBe("");
    expect(result.healedTags).toEqual([]);
    expect(result.completedTags).toEqual([
      { kind: "screen", screenId: "screen-2" },
      { kind: "point", x: 1, y: 2, screenId: "screen-2" },
      { kind: "annotation", screenId: "screen-2", annotation: { id: "dsl-1", shape: "rect", x: 3, y: 4, w: 5, h: 6 } },
    ]);
  });

  it("heals verb case and surrounding whitespace, while unknown verbs still drop", () => {
    const parser = new AnnotationDslParser();
    const result = parser.feed("[ Point : x=1 y=2 ] [ARROW: x=1 y=2]");

    expect(result.completedTags).toEqual([{ kind: "point", x: 1, y: 2 }]);
    expect(result.healedTags).toEqual(["POINT: verb case/whitespace"]);
    expect(result.droppedTags).toEqual(["unknown verb ARROW"]);
  });

  it("heals argument spacing and single separators but rejects consecutive separators", () => {
    const parser = new AnnotationDslParser();
    const healed = parser.feed("[RECT: x = 120, y = 340, w=20; h=30]");
    const dropped = parser.feed("[RECT: x=1,, y=2 w=3 h=4]");

    expect(healed.completedTags[0]).toMatchObject({ kind: "annotation", annotation: { shape: "rect", x: 120, y: 340, w: 20, h: 30 } });
    expect(healed.healedTags).toEqual(["RECT: argument spacing/separator"]);
    expect(dropped.completedTags).toEqual([]);
    expect(dropped.droppedTags).toHaveLength(1);
  });

  it("heals smart quotes and unquoted single-token labels but rejects multi-word bare labels", () => {
    const parser = new AnnotationDslParser();
    const smart = parser.feed("[POINT: x=1 y=2 label=“저장”]");
    const bare = parser.feed("[POINT: x=3 y=4 label=저장버튼]");
    const multiWord = parser.feed("[POINT: x=5 y=6 label=저장 버튼]");

    expect(smart.completedTags[0]).toMatchObject({ kind: "point", label: "저장" });
    expect(smart.healedTags).toEqual(["POINT: smart quotes"]);
    expect(bare.completedTags[0]).toMatchObject({ kind: "point", label: "저장버튼" });
    expect(bare.healedTags).toEqual(["POINT: unquoted single-token label"]);
    expect(multiWord.completedTags).toEqual([]);
    expect(multiWord.droppedTags).toHaveLength(1);
  });

  it("heals px units and rounds float coordinates while rejecting unparseable coordinates", () => {
    const parser = new AnnotationDslParser();
    const healed = parser.feed("[RECT: x=120.5px y=340.4px w=24.5 h=10]");
    const dropped = parser.feed("[RECT: x=left y=340 w=24 h=10]");

    expect(healed.completedTags[0]).toMatchObject({ kind: "annotation", annotation: { x: 121, y: 340, w: 25, h: 10 } });
    expect(healed.healedTags).toEqual(["RECT: numeric px unit, rounded float"]);
    expect(dropped.completedTags).toEqual([]);
    expect(dropped.droppedTags).toHaveLength(1);
  });

  it("lets the last duplicate key win", () => {
    const parser = new AnnotationDslParser();
    const duplicate = parser.feed("[POINT: x=1 x=9 y=2]");

    expect(duplicate.completedTags).toEqual([{ kind: "point", x: 9, y: 2 }]);
    expect(duplicate.healedTags).toEqual(["POINT: duplicate key last-wins"]);
  });

  it("ignores unknown extra keys but hard-drops nested tags and unterminated quotes", () => {
    const parser = new AnnotationDslParser();
    const extra = parser.feed("[POINT: x=1 y=2 confidence=high]");
    const nested = parser.feed("[POINT: x=1 y=[RECT: x=2 y=3 w=4 h=4]]");
    const unterminated = parser.feed("[POINT: x=1 y=2 label=\"broken]");

    expect(extra.completedTags).toEqual([{ kind: "point", x: 1, y: 2 }]);
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
    expect(first.completedTags).toEqual([{ kind: "point", x: 2, y: 2, label: "저장" }]);
    expect(first.droppedTags).toEqual(["unknown verb ARROW"]);
    expect(first.healedTags).toEqual(["POINT: verb case/whitespace, argument spacing/separator, unquoted single-token label, numeric px unit, rounded float"]);
  });

  it("preserves one trailing separator space when the next delta begins with a word", () => {
    const parser = new AnnotationDslParser();
    const first = parser.feed("먼저 [POINT: x=1 y=2] ");
    const second = parser.feed("다음");

    expect(`${first.cleanText}${second.cleanText}`).toBe("먼저 다음");
  });

  it("recognizes lowercase and whitespace-tolerant bracketed DSL tags", () => {
    expect(ANNOTATION_DSL_TAG_OPEN_PATTERN.test("[ POINT : x=1]")).toBe(true);
    expect(ANNOTATION_DSL_TAG_OPEN_PATTERN.test("[point: x=1]")).toBe(true);
  });
});
