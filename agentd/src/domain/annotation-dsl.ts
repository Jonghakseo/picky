import type { AnnotationInput } from "./annotation-validation.js";

const KNOWN_VERBS = ["POINT", "RECT", "LINE", "SCREEN"] as const;
type KnownVerb = typeof KNOWN_VERBS[number];

/** Matches a complete DSL opener; partial openers are handled incrementally below. */
export const ANNOTATION_DSL_TAG_OPEN_PATTERN = /^\[\s*([A-Za-z]+)\s*:/;
const knownVerbSet = new Set<string>(KNOWN_VERBS);
const HEAL_ORDER = [
  "verb case/whitespace",
  "argument spacing/separator",
  "smart quotes",
  "unquoted single-token label",
  "numeric px unit",
  "rounded float",
  "boolean value",
  "duplicate key last-wins",
  "unknown key ignored",
] as const;
type HealReason = typeof HEAL_ORDER[number];

export interface AnnotationDslPointTag {
  kind: "point";
  x: number;
  y: number;
  label?: string;
  screenId?: string;
}

export interface AnnotationDslAnnotationTag {
  kind: "annotation";
  annotation: AnnotationInput;
  screenId?: string;
}

export interface AnnotationDslScreenTag {
  kind: "screen";
  screenId: string;
}

export type AnnotationDslTag = AnnotationDslPointTag | AnnotationDslAnnotationTag | AnnotationDslScreenTag;

export type AnnotationDslStreamItem =
  | { kind: "text"; text: string }
  | { kind: "tag"; tag: AnnotationDslTag };

export interface AnnotationDslParseResult {
  cleanText: string;
  completedTags: AnnotationDslTag[];
  streamItems: AnnotationDslStreamItem[];
  droppedTags: string[];
  /** Deterministic per-tag healing summaries for the caller's debug log. */
  healedTags: string[];
}

interface ParsedValue {
  value: string;
  quoted: boolean;
  bare?: boolean;
}

interface ParsedArguments {
  values: Record<string, ParsedValue>;
  heals: Set<HealReason>;
}

/**
 * Incrementally removes Picky visual-overlay DSL tags from assistant text. It intentionally
 * retains only a possible tag prefix between feeds, so normal prose is forwarded immediately.
 */
export class AnnotationDslParser {
  private pending = "";
  private screenId?: string;
  private tagSequence = 0;

  feed(delta: string): AnnotationDslParseResult {
    const source = this.pending + delta;
    this.pending = "";
    const completedTags: AnnotationDslTag[] = [];
    const streamItems: AnnotationDslStreamItem[] = [];
    const droppedTags: string[] = [];
    const healedTags: string[] = [];
    let cleanText = "";
    let cursor = 0;
    const appendText = (text: string): void => {
      if (!text) return;
      cleanText += text;
      const previous = streamItems.at(-1);
      if (previous?.kind === "text") previous.text += text;
      else streamItems.push({ kind: "text", text });
    };

    while (cursor < source.length) {
      const open = source.indexOf("[", cursor);
      if (open < 0) {
        appendText(source.slice(cursor));
        break;
      }
      appendText(source.slice(cursor, open));
      const remainder = source.slice(open);
      const opener = remainder.match(ANNOTATION_DSL_TAG_OPEN_PATTERN);
      if (!opener) {
        if (isPartialKnownOpener(remainder)) {
          this.pending = remainder;
          break;
        }
        appendText("[");
        cursor = open + 1;
        continue;
      }

      const close = findTagClose(source, open + opener[0].length);
      if (close === undefined) {
        this.pending = remainder;
        break;
      }

      const rawVerb = opener[1]!;
      const verb = rawVerb.toUpperCase();
      const body = source.slice(open + opener[0].length, close);
      if (!knownVerbSet.has(verb)) {
        droppedTags.push(`unknown verb ${verb}`);
      } else if (hasNestedUnquotedBracket(body)) {
        droppedTags.push(`nested tag in ${verb}`);
      } else {
        const knownVerb = verb as KnownVerb;
        const heals = new Set<HealReason>();
        if (opener[0] !== `[${verb}:` || /\s$/.test(body)) heals.add("verb case/whitespace");
        const parsed = this.parseTag(knownVerb, body, heals);
        if (parsed.tag) {
          completedTags.push(parsed.tag);
          streamItems.push({ kind: "tag", tag: parsed.tag });
          const summary = healingSummary(knownVerb, heals);
          if (summary) healedTags.push(summary);
        } else {
          droppedTags.push(parsed.error ?? `malformed ${verb} tag`);
        }
      }
      cursor = close + 1;
    }

    // Removing an inline tag between prose tokens must not leave a visibly doubled space.
    // Preserve a separator when this delta ends after a tag and its trailing space: the next
    // streamed delta may begin with the next word, so trimEnd would join those words.
    if (completedTags.length > 0 || droppedTags.length > 0) {
      cleanText = cleanText.replace(/[ \t]{2,}/g, " ");
      if (!cleanText.trim()) cleanText = "";
      else if (/\]$/.test(source)) cleanText = cleanText.trimEnd();
    }
    return { cleanText, completedTags, streamItems, droppedTags, healedTags };
  }

  finish(): AnnotationDslParseResult {
    if (!this.pending) return emptyResult();
    this.pending = "";
    return { cleanText: "", completedTags: [], streamItems: [], droppedTags: ["unclosed DSL tag at turn end"], healedTags: [] };
  }

  reset(): void {
    this.pending = "";
    this.screenId = undefined;
    this.tagSequence = 0;
  }

  // eslint-disable-next-line complexity -- The parser keeps grammar validation and healing decisions together so malformed tags cannot be partially accepted.
  private parseTag(verb: KnownVerb, body: string, heals: Set<HealReason>): { tag?: AnnotationDslTag; error?: string } {
    const parsedArgs = parseNamedArguments(body);
    if (!parsedArgs) return { error: `malformed ${verb} arguments` };
    for (const heal of parsedArgs.heals) heals.add(heal);
    const args = parsedArgs.values;
    for (const [key, value] of Object.entries(args)) {
      if (value.bare && key !== "spotlight") {
        delete args[key];
        heals.add("unknown key ignored");
      } else if (!allowedKeysFor(verb).has(key)) {
        heals.add("unknown key ignored");
      }
    }

    if (verb === "SCREEN") {
      const screenId = args.id?.value.trim();
      if (!screenId) return { error: "SCREEN requires id" };
      this.screenId = screenId;
      return { tag: { kind: "screen", screenId } };
    }

    const label = optionalText(args, "label", heals);
    if (label === null) return { error: `${verb} has invalid label` };
    const screenId = this.screenId;
    const coordinate = (key: string): number | undefined => finiteNumber(args[key], heals);
    const required = (...keys: string[]): Record<string, number> | undefined => {
      const fields: Record<string, number> = {};
      for (const key of keys) {
        const value = coordinate(key);
        if (value === undefined) return undefined;
        fields[key] = value;
      }
      return fields;
    };

    if (verb === "POINT") {
      const fields = required("x", "y");
      if (!fields) return { error: "POINT requires x and y" };
      return { tag: { kind: "point", x: fields.x!, y: fields.y!, ...(label === undefined ? {} : { label }), ...(screenId ? { screenId } : {}) } };
    }

    const spotlight = verb === "RECT" || verb === "LINE"
      ? optionalBoolean(args, "spotlight", heals)
      : undefined;
    if (spotlight === null) return { error: `${verb} has invalid spotlight` };

    let annotation: AnnotationInput | undefined;
    switch (verb) {
      case "RECT": {
        const fields = required("x", "y", "w", "h");
        if (!fields) return { error: "RECT requires x, y, w, and h" };
        annotation = { ...this.annotationBase("rect", label), ...fields, ...(spotlight === undefined ? {} : { spotlight }) };
        break;
      }
      case "LINE": {
        const fields = required("x1", "y1", "x2", "y2");
        if (!fields) return { error: "LINE requires x1, y1, x2, and y2" };
        annotation = { ...this.annotationBase("line", label), ...fields, ...(spotlight === undefined ? {} : { spotlight }) };
        break;
      }
      default:
        return { error: `unsupported ${verb} tag` };
    }
    return { tag: { kind: "annotation", annotation, ...(screenId ? { screenId } : {}) } };
  }

  private annotationBase(shape: AnnotationInput["shape"], label: string | undefined): Pick<AnnotationInput, "id" | "shape" | "label"> {
    this.tagSequence += 1;
    return { id: `dsl-${this.tagSequence}`, shape, ...(label === undefined ? {} : { label }) };
  }
}

function emptyResult(): AnnotationDslParseResult {
  return { cleanText: "", completedTags: [], streamItems: [], droppedTags: [], healedTags: [] };
}

function healingSummary(verb: KnownVerb, heals: ReadonlySet<HealReason>): string | undefined {
  const reasons = HEAL_ORDER.filter((reason) => heals.has(reason));
  return reasons.length > 0 ? `${verb}: ${reasons.join(", ")}` : undefined;
}

function allowedKeysFor(verb: KnownVerb): ReadonlySet<string> {
  switch (verb) {
    case "POINT": return new Set(["x", "y", "label"]);
    case "RECT": return new Set(["x", "y", "w", "h", "label", "spotlight"]);
    case "LINE": return new Set(["x1", "y1", "x2", "y2", "label", "spotlight"]);
    case "SCREEN": return new Set(["id"]);
  }
}

function isPartialKnownOpener(value: string): boolean {
  const partial = value.match(/^\[\s*([A-Za-z]*)\s*$/)?.[1];
  return partial !== undefined && KNOWN_VERBS.some((verb) => verb.startsWith(partial.toUpperCase()));
}

function findTagClose(source: string, start: number): number | undefined {
  let quoteEnd: string | undefined;
  let escaped = false;
  let nestedDepth = 0;
  for (let index = start; index < source.length; index += 1) {
    const character = source[index]!;
    if (escaped) {
      escaped = false;
      continue;
    }
    if (character === "\\") {
      escaped = true;
      continue;
    }
    if (quoteEnd) {
      if (character === quoteEnd) quoteEnd = undefined;
      continue;
    }
    quoteEnd = closingQuoteFor(character);
    if (character === "[") {
      nestedDepth += 1;
      continue;
    }
    if (character === "]") {
      if (nestedDepth === 0) return index;
      nestedDepth -= 1;
    }
  }
  return undefined;
}

function hasNestedUnquotedBracket(body: string): boolean {
  let quoteEnd: string | undefined;
  let escaped = false;
  for (const character of body) {
    if (escaped) {
      escaped = false;
      continue;
    }
    if (character === "\\") {
      escaped = true;
      continue;
    }
    if (quoteEnd) {
      if (character === quoteEnd) quoteEnd = undefined;
      continue;
    }
    quoteEnd = closingQuoteFor(character);
    if (character === "[") return true;
  }
  return false;
}

function closingQuoteFor(character: string): string | undefined {
  if (character === '"') return '"';
  if (character === "“") return "”";
  if (character === "‘") return "’";
  return undefined;
}

// eslint-disable-next-line complexity -- This single-pass parser deliberately couples cursor movement with healing diagnostics for deterministic recovery.
function parseNamedArguments(body: string): ParsedArguments | undefined {
  const values: Record<string, ParsedValue> = {};
  const heals = new Set<HealReason>();
  let index = 0;
  while (index < body.length) {
    const beforeToken = index;
    while (/\s/.test(body[index] ?? "")) index += 1;
    if (index - beforeToken > 1 && index < body.length) heals.add("argument spacing/separator");
    if (index === body.length) break;

    if (body[index] === "," || body[index] === ";") {
      heals.add("argument spacing/separator");
      index += 1;
      while (/\s/.test(body[index] ?? "")) index += 1;
      if (index === body.length) break;
      if (body[index] === "," || body[index] === ";") return undefined;
    }

    const key = body.slice(index).match(/^[a-z][a-z0-9]*/i)?.[0];
    if (!key) return undefined;
    index += key.length;
    const beforeEquals = index;
    while (/\s/.test(body[index] ?? "")) index += 1;
    if (index > beforeEquals) heals.add("argument spacing/separator");
    if (body[index] !== "=") {
      if (values[key]) heals.add("duplicate key last-wins");
      values[key] = { value: "true", quoted: false, bare: true };
      continue;
    }
    index += 1;
    const afterEquals = index;
    while (/\s/.test(body[index] ?? "")) index += 1;
    if (index > afterEquals) heals.add("argument spacing/separator");

    const parsedValue = parseArgumentValue(body, index, heals);
    if (!parsedValue) return undefined;
    index = parsedValue.nextIndex;
    if (values[key]) heals.add("duplicate key last-wins");
    values[key] = parsedValue.value;
  }
  return { values, heals };
}

function parseArgumentValue(body: string, start: number, heals: Set<HealReason>): { value: ParsedValue; nextIndex: number } | undefined {
  const opener = body[start];
  const quoteEnd = opener ? closingQuoteFor(opener) : undefined;
  if (quoteEnd) {
    if (opener !== '"') heals.add("smart quotes");
    let index = start + 1;
    let value = "";
    while (index < body.length) {
      const character = body[index++]!;
      if (character === "\\") {
        const escaped = body[index++];
        if (escaped === undefined) return undefined;
        value += escaped === '"' || escaped === "\\" ? escaped : `\\${escaped}`;
        continue;
      }
      if (character === quoteEnd) {
        if (index < body.length && !/\s|,|;/.test(body[index]!)) return undefined;
        return { value: { value, quoted: true }, nextIndex: index };
      }
      value += character;
    }
    return undefined;
  }

  let index = start;
  while (index < body.length && !/\s|,|;/.test(body[index]!)) {
    if (body[index] === "[") return undefined;
    index += 1;
  }
  if (index === start) return undefined;
  return { value: { value: body.slice(start, index), quoted: false }, nextIndex: index };
}

function finiteNumber(value: ParsedValue | undefined, heals: Set<HealReason>): number | undefined {
  if (!value || value.quoted) return undefined;
  let raw = value.value;
  if (/px$/i.test(raw)) {
    raw = raw.slice(0, -2);
    heals.add("numeric px unit");
  }
  if (!/^-?(?:\d+(?:\.\d+)?|\.\d+)$/.test(raw)) return undefined;
  const number = Number(raw);
  if (!Number.isFinite(number)) return undefined;
  if (!Number.isInteger(number)) heals.add("rounded float");
  return Math.round(number);
}

function optionalBoolean(args: Record<string, ParsedValue>, key: string, heals: Set<HealReason>): boolean | undefined | null {
  const value = args[key];
  if (!value) return undefined;
  if (value.quoted) return null;
  const normalized = value.value.toLowerCase();
  if (normalized === "true") return true;
  if (normalized === "false") return false;
  if (["1", "yes", "on"].includes(normalized)) {
    heals.add("boolean value");
    return true;
  }
  if (["0", "no", "off"].includes(normalized)) {
    heals.add("boolean value");
    return false;
  }
  return null;
}

function optionalText(args: Record<string, ParsedValue>, key: string, heals: Set<HealReason>): string | undefined | null {
  if (!(key in args)) return undefined;
  const value = textValue(args[key], heals);
  if (value === null) return null;
  return value.trim() ? value : undefined;
}

function textValue(value: ParsedValue | undefined, heals: Set<HealReason>): string | null {
  if (!value) return null;
  if (!value.quoted) {
    if (!value.value || /[\s\[\]"'“”‘’]/.test(value.value)) return null;
    heals.add("unquoted single-token label");
  }
  return value.value.length <= 120 ? value.value : null;
}
