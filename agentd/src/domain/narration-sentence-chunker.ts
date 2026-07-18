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
    for (let index = 0; index < this.pending.length; index += 1) {
      if (!isSentenceTerminator(this.pending, index)) continue;
      let boundary = index + 1;
      while (boundary < this.pending.length && isClosingPunctuation(this.pending[boundary]!)) boundary += 1;
      if (requiresTrailingWhitespace(this.pending[index]!)) {
        // An ASCII '.', '!' or '?' only ends a sentence when whitespace follows,
        // so a mid-token dot like "schema.gql" is not treated as a break. When the
        // terminator sits at the buffer edge, wait for more input before deciding.
        if (boundary >= this.pending.length) break;
        if (!isWhitespace(this.pending[boundary]!)) continue;
      }
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

// Fullwidth CJK terminators are unambiguous full stops, but ASCII '.', '!' and
// '?' also appear inside tokens (URLs, filenames, versions), so they require a
// following whitespace to count as a sentence break.
function requiresTrailingWhitespace(character: string): boolean {
  return character === "." || character === "!" || character === "?";
}

function isWhitespace(character: string | undefined): boolean {
  return character !== undefined && /\s/.test(character);
}

function isDigit(character: string | undefined): boolean {
  return character !== undefined && character >= "0" && character <= "9";
}

