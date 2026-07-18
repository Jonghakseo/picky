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

  it("does not split a dot inside a token such as a filename", () => {
    const chunker = new NarrationSentenceChunker();

    // The dot in "schema.gql" is followed by a letter, not whitespace, so it must
    // not end the sentence.
    expect(chunker.feed("apps/**/schema.gql 파일이 변경될 때만 실행됩니다. 먼저")).toEqual([
      "apps/**/schema.gql 파일이 변경될 때만 실행됩니다.",
    ]);
    expect(chunker.finish()).toEqual(["먼저"]);
  });

  it("treats a newline after a terminator as a sentence break", () => {
    const chunker = new NarrationSentenceChunker();

    expect(chunker.feed("첫 문장.\n둘째 문장")).toEqual(["첫 문장."]);
    expect(chunker.finish()).toEqual(["둘째 문장"]);
  });

  it("waits for the following whitespace when a terminator lands at the buffer edge", () => {
    const chunker = new NarrationSentenceChunker();

    // A '.' at the very end could still be a mid-token dot once more text streams
    // in, so hold it until the next delta reveals the separator.
    expect(chunker.feed("schema.")).toEqual([]);
    expect(chunker.feed("gql을 병합합니다. 다음")).toEqual(["schema.gql을 병합합니다."]);
    expect(chunker.finish()).toEqual(["다음"]);
  });
});
