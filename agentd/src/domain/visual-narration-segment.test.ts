import { describe, expect, it } from "vitest";
import { VisualNarrationSegmentAssembler } from "./visual-narration-segment.js";

type Segment = { id: string };

function segment(id: string): Segment {
  return { id };
}

describe("VisualNarrationSegmentAssembler", () => {
  it("emits completed sentences progressively before committing the segment", () => {
    const assembler = new VisualNarrationSegmentAssembler<Segment>();
    const first = segment("A");

    expect(assembler.prepare(first)).toEqual([{ kind: "prepared", segment: first }]);
    expect(assembler.appendText("첫 문장. 둘째")).toEqual([
      { kind: "sentence", segment: first, index: 0, text: "첫 문장." },
    ]);
    expect(assembler.appendText(" 문장! trailing")).toEqual([
      { kind: "sentence", segment: first, index: 1, text: "둘째 문장!" },
    ]);
    expect(assembler.boundary()).toEqual([
      { kind: "sentence", segment: first, index: 2, text: "trailing" },
      { kind: "committed", segment: first, text: "첫 문장. 둘째 문장! trailing", sentenceCount: 3 },
    ]);
  });

  it("commits the previous segment at a boundary before preparing the next", () => {
    const assembler = new VisualNarrationSegmentAssembler<Segment>();
    const first = segment("A");
    const second = segment("B");

    assembler.prepare(first);
    assembler.appendText("A 설명.");

    expect(assembler.boundary()).toEqual([
      { kind: "committed", segment: first, text: "A 설명.", sentenceCount: 1 },
    ]);
    expect(assembler.prepare(second)).toEqual([{ kind: "prepared", segment: second }]);
    expect(assembler.appendText("B 설명.")).toEqual([
      { kind: "sentence", segment: second, index: 0, text: "B 설명." },
    ]);
  });

  it("keeps prose orphaned after a malformed visual boundary", () => {
    const assembler = new VisualNarrationSegmentAssembler<Segment>();
    const first = segment("A");

    assembler.prepare(first);
    assembler.appendText("A 설명.");
    assembler.boundary();

    expect(assembler.appendText("orphan prose.")).toEqual([
      { kind: "orphanText", text: "orphan prose." },
    ]);
  });

  it("preserves an empty segment without synthesizing a sentence", () => {
    const assembler = new VisualNarrationSegmentAssembler<Segment>();
    const first = segment("A");

    assembler.prepare(first);

    expect(assembler.boundary()).toEqual([
      { kind: "committed", segment: first, sentenceCount: 0 },
    ]);
  });

  it("keeps text around transparent selectors in one normalized segment", () => {
    const assembler = new VisualNarrationSegmentAssembler<Segment>();
    const first = segment("A");

    assembler.prepare(first);
    assembler.appendText("설명 A. ");
    assembler.appendText(" 계속 A.");

    expect(assembler.finish()).toEqual([
      { kind: "committed", segment: first, text: "설명 A. 계속 A.", sentenceCount: 2 },
    ]);
  });

  it("flushes the last trailing sentence before the final commit", () => {
    const assembler = new VisualNarrationSegmentAssembler<Segment>();
    const first = segment("A");

    assembler.prepare(first);
    assembler.appendText("마지막 설명");

    expect(assembler.finish()).toEqual([
      { kind: "sentence", segment: first, index: 0, text: "마지막 설명" },
      { kind: "committed", segment: first, text: "마지막 설명", sentenceCount: 1 },
    ]);
  });

  it("reset discards prepared text without emitting it", () => {
    const assembler = new VisualNarrationSegmentAssembler<Segment>();
    assembler.prepare(segment("A"));
    assembler.appendText("미완성");

    assembler.reset();

    expect(assembler.finish()).toEqual([]);
    expect(assembler.appendText("ordinary")).toEqual([{ kind: "orphanText", text: "ordinary" }]);
  });
});
