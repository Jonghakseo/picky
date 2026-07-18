/**
 * Buffers clean assistant prose until a speakable sentence boundary is available.
 * Inline visual DSL has already been removed before text reaches this policy.
 */
export class NarrationSentenceChunker {
  private pending = "";

  feed(text: string): string[] {
    this.pending += text;
    return this.takeCompletedSentences();
  }

  finish(): string[] {
    const sentences = this.takeCompletedSentences();
    const trailing = this.pending.trim();
    this.pending = "";
    return trailing ? [...sentences, trailing] : sentences;
  }

  reset(): void {
    this.pending = "";
  }

  private takeCompletedSentences(): string[] {
    const sentences: string[] = [];
    let boundary: number | undefined;
    for (let index = 0; index < this.pending.length; index += 1) {
      if (!isSentenceTerminator(this.pending, index)) continue;
      boundary = index + 1;
      while (boundary < this.pending.length && isClosingPunctuation(this.pending[boundary]!)) boundary += 1;
      const sentence = this.pending.slice(0, boundary).trim();
      if (sentence) sentences.push(sentence);
      this.pending = this.pending.slice(boundary);
      index = -1;
    }
    return sentences;
  }
}

function isSentenceTerminator(text: string, index: number): boolean {
  const character = text[index];
  if (character === ".") {
    // Do not split decimal values such as 3.14.
    return !(isDigit(text[index - 1]) && isDigit(text[index + 1]));
  }
  return character === "!" || character === "?" || character === "。" || character === "！" || character === "？";
}

function isClosingPunctuation(character: string): boolean {
  return character === '"' || character === "'" || character === "”" || character === "’" || character === ")" || character === "]";
}

function isDigit(character: string | undefined): boolean {
  return character !== undefined && character >= "0" && character <= "9";
}

