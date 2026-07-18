import { describe, expect, it } from "vitest";
import { NarrationSentenceChunker } from "./narration-sentence-chunker.js";

describe("NarrationSentenceChunker", () => {
  it("emits complete Korean and Latin sentences in source order", () => {
    const chunker = new NarrationSentenceChunker();

    expect(chunker.feed("먼저 저장하세요. Then verify it")).toEqual(["먼저 저장하세요."]);
    expect(chunker.feed(" works! 마지막")).toEqual(["Then verify it works!"]);
    expect(chunker.finish()).toEqual(["마지막"]);
  });

  it("does not split decimal values and flushes an unterminated final sentence", () => {
    const chunker = new NarrationSentenceChunker();

    expect(chunker.feed("값은 3.14입니다. 계속")).toEqual(["값은 3.14입니다."]);
    expect(chunker.finish()).toEqual(["계속"]);
  });
});
