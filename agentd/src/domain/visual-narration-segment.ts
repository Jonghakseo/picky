import { NarrationSentenceChunker } from "./narration-sentence-chunker.js";

export type VisualNarrationSegmentAction<Segment> =
  | { kind: "prepared"; segment: Segment }
  | { kind: "sentence"; segment: Segment; index: number; text: string }
  | { kind: "committed"; segment: Segment; text?: string; sentenceCount: number }
  | { kind: "orphanText"; text: string };

interface OpenSegment<Segment> {
  segment: Segment;
  text: string;
  sentenceCount: number;
  sentenceChunker: NarrationSentenceChunker;
}

/**
 * Owns the prose lifecycle for one source-ordered visual segment at a time.
 * Parser boundaries close the prior segment even when the following visual tag
 * later proves malformed; SCREEN selectors never reach this policy.
 */
export class VisualNarrationSegmentAssembler<Segment> {
  private open?: OpenSegment<Segment>;

  prepare(segment: Segment): VisualNarrationSegmentAction<Segment>[] {
    const actions = this.commitOpenSegment();
    this.open = {
      segment,
      text: "",
      sentenceCount: 0,
      sentenceChunker: new NarrationSentenceChunker(),
    };
    actions.push({ kind: "prepared", segment });
    return actions;
  }

  appendText(text: string): VisualNarrationSegmentAction<Segment>[] {
    if (!text) return [];
    const open = this.open;
    if (!open) return [{ kind: "orphanText", text }];

    open.text += text;
    return open.sentenceChunker.feed(text).map((sentence) => this.sentenceAction(open, sentence));
  }

  boundary(): VisualNarrationSegmentAction<Segment>[] {
    return this.commitOpenSegment();
  }

  finish(): VisualNarrationSegmentAction<Segment>[] {
    return this.commitOpenSegment();
  }

  reset(): void {
    this.open = undefined;
  }

  private commitOpenSegment(): VisualNarrationSegmentAction<Segment>[] {
    const open = this.open;
    if (!open) return [];
    this.open = undefined;

    const actions: VisualNarrationSegmentAction<Segment>[] = open.sentenceChunker
      .finish()
      .map((sentence) => this.sentenceAction(open, sentence));
    const text = normalizeProse(open.text);
    actions.push({
      kind: "committed",
      segment: open.segment,
      ...(text ? { text } : {}),
      sentenceCount: open.sentenceCount,
    });
    return actions;
  }

  private sentenceAction(open: OpenSegment<Segment>, sentence: string): VisualNarrationSegmentAction<Segment> {
    const index = open.sentenceCount;
    open.sentenceCount += 1;
    return {
      kind: "sentence",
      segment: open.segment,
      index,
      text: normalizeProse(sentence),
    };
  }
}

function normalizeProse(text: string): string {
  return text.replace(/[ \t]{2,}/g, " ").trim();
}
