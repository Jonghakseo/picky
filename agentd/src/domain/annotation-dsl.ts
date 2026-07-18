import type { AnnotationInput } from "./annotation-validation.js";

const KNOWN_VERBS = ["POINT", "TARGET", "CIRCLE", "RECT", "LINE", "SPOTLIGHT", "LABEL", "SCREEN"] as const;
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
  "default ttl",
  "duplicate key last-wins",
  "unknown key ignored",
] as const;
type HealReason = typeof HEAL_ORDER[number];

export interface AnnotationDslPointTag {
  kind: "point";
  x: number;
  y: number;
  r?: number;
  label?: string;
  ttlMs: number;
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

export interface AnnotationDslParseResult {
  cleanText: string;
  completedTags: AnnotationDslTag[];
  droppedTags: string[];
  /** Deterministic per-tag healing summaries for the caller's debug log. */
  healedTags: string[];
}

interface ParsedValue {
  value: string;
  quoted: boolean;
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
    const droppedTags: string[] = [];
    const healedTags: string[] = [];
    let cleanText = "";
    let cursor = 0;

    while (cursor < source.length) {
      const open = source.indexOf("[", cursor);
      if (open < 0) {
        cleanText += source.slice(cursor);
        break;
      }
      cleanText += source.slice(cursor, open);
      const remainder = source.slice(open);
      const opener = remainder.match(ANNOTATION_DSL_TAG_OPEN_PATTERN);
      if (!opener) {
        if (isPartialKnownOpener(remainder)) {
          this.pending = remainder;
          break;
        }
        cleanText += "[";
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
    return { cleanText, completedTags, droppedTags, healedTags };
  }

  finish(): AnnotationDslParseResult {
    if (!this.pending) return emptyResult();
    this.pending = "";
    return { cleanText: "", completedTags: [], droppedTags: ["unclosed DSL tag at turn end"], healedTags: [] };
  }

  reset(): void {
    this.pending = "";
    this.screenId = undefined;
    this.tagSequence = 0;
  }

  private parseTag(verb: KnownVerb, body: string, heals: Set<HealReason>): { tag?: AnnotationDslTag; error?: string } {
    const parsedArgs = parseNamedArguments(body);
    if (!parsedArgs) return { error: `malformed ${verb} arguments` };
    for (const heal of parsedArgs.heals) heals.add(heal);
    const args = parsedArgs.values;
    for (const key of Object.keys(args)) {
      if (!allowedKeysFor(verb).has(key)) heals.add("unknown key ignored");
    }

    if (verb === "SCREEN") {
      const screenId = args.id?.value.trim();
      if (!screenId) return { error: "SCREEN requires id" };
      this.screenId = screenId;
      return { tag: { kind: "screen", screenId } };
    }

    const ttlMs = ttlFrom(args, heals);
    if (ttlMs === undefined) return { error: `${verb} has invalid ttl` };
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
      const r = optionalNumber(args, "r", heals);
      if (r === null) return { error: "POINT has invalid r" };
      return { tag: { kind: "point", x: fields.x!, y: fields.y!, ...(r === undefined ? {} : { r }), ...(label === undefined ? {} : { label }), ttlMs, ...(screenId ? { screenId } : {}) } };
    }

    let annotation: AnnotationInput | undefined;
    switch (verb) {
      case "TARGET": {
        const fields = required("x", "y", "r");
        if (!fields) return { error: "TARGET requires x, y, and r" };
        annotation = { ...this.annotationBase("target", ttlMs, label), ...fields };
        break;
      }
      case "CIRCLE": {
        const fields = required("x", "y");
        const r = optionalNumber(args, "r", heals);
        const rx = optionalNumber(args, "rx", heals);
        const ry = optionalNumber(args, "ry", heals);
        if (!fields || r === null || rx === null || ry === null || (r === undefined && (rx === undefined || ry === undefined)) || (r !== undefined && (rx !== undefined || ry !== undefined))) {
          return { error: "CIRCLE requires x, y, and either r or rx with ry" };
        }
        annotation = { ...this.annotationBase("circle", ttlMs, label), ...fields, ...(r === undefined ? { rx: rx!, ry: ry! } : { r }) };
        break;
      }
      case "RECT": {
        const fields = required("x", "y", "w", "h");
        if (!fields) return { error: "RECT requires x, y, w, and h" };
        annotation = { ...this.annotationBase("rect", ttlMs, label), ...fields };
        break;
      }
      case "LINE": {
        const fields = required("x1", "y1", "x2", "y2");
        if (!fields) return { error: "LINE requires x1, y1, x2, and y2" };
        annotation = { ...this.annotationBase("line", ttlMs, label), ...fields };
        break;
      }
      case "SPOTLIGHT": {
        const shape = args.shape?.value;
        if (shape === "circle") {
          const fields = required("x", "y", "r");
          if (!fields) return { error: "SPOTLIGHT circle requires x, y, and r" };
          annotation = { ...this.annotationBase("spotlight", ttlMs, label), spotlightShape: "circle", ...fields };
        } else if (shape === "rect") {
          const fields = required("x", "y", "w", "h");
          if (!fields) return { error: "SPOTLIGHT rect requires x, y, w, and h" };
          annotation = { ...this.annotationBase("spotlight", ttlMs, label), spotlightShape: "rect", ...fields };
        } else {
          return { error: "SPOTLIGHT requires shape=circle or shape=rect" };
        }
        break;
      }
      case "LABEL": {
        const fields = required("x", "y");
        const text = requiredText(args, "text", heals);
        if (!fields || text === undefined) return { error: "LABEL requires x, y, and text" };
        annotation = { ...this.annotationBase("label", ttlMs, text), ...fields };
        break;
      }
      default:
        return { error: `unsupported ${verb} tag` };
    }
    return { tag: { kind: "annotation", annotation, ...(screenId ? { screenId } : {}) } };
  }

  private annotationBase(shape: AnnotationInput["shape"], ttlMs: number, label: string | undefined): Pick<AnnotationInput, "id" | "shape" | "ttlMs" | "label"> {
    this.tagSequence += 1;
    return { id: `dsl-${this.tagSequence}`, shape, ttlMs, ...(label === undefined ? {} : { label }) };
  }
}

function emptyResult(): AnnotationDslParseResult {
  return { cleanText: "", completedTags: [], droppedTags: [], healedTags: [] };
}

function healingSummary(verb: KnownVerb, heals: ReadonlySet<HealReason>): string | undefined {
  const reasons = HEAL_ORDER.filter((reason) => heals.has(reason));
  return reasons.length > 0 ? `${verb}: ${reasons.join(", ")}` : undefined;
}

function allowedKeysFor(verb: KnownVerb): ReadonlySet<string> {
  switch (verb) {
    case "POINT": return new Set(["x", "y", "r", "ttl", "label"]);
    case "TARGET": return new Set(["x", "y", "r", "ttl", "label"]);
    case "CIRCLE": return new Set(["x", "y", "r", "rx", "ry", "ttl", "label"]);
    case "RECT": return new Set(["x", "y", "w", "h", "ttl", "label"]);
    case "LINE": return new Set(["x1", "y1", "x2", "y2", "ttl", "label"]);
    case "SPOTLIGHT": return new Set(["shape", "x", "y", "r", "w", "h", "ttl", "label"]);
    case "LABEL": return new Set(["x", "y", "ttl", "text"]);
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
    if (body[index] !== "=") return undefined;
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

function ttlFrom(args: Record<string, ParsedValue>, heals: Set<HealReason>): number | undefined {
  if (!args.ttl) {
    heals.add("default ttl");
    return 6000;
  }
  const ttl = finiteNumber(args.ttl, heals);
  return ttl === undefined ? undefined : Math.max(500, Math.min(60_000, ttl));
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

function optionalNumber(args: Record<string, ParsedValue>, key: string, heals: Set<HealReason>): number | undefined | null {
  if (!(key in args)) return undefined;
  return finiteNumber(args[key], heals) ?? null;
}

function optionalText(args: Record<string, ParsedValue>, key: string, heals: Set<HealReason>): string | undefined | null {
  if (!(key in args)) return undefined;
  return textValue(args[key], heals);
}

function requiredText(args: Record<string, ParsedValue>, key: string, heals: Set<HealReason>): string | undefined {
  return textValue(args[key], heals) ?? undefined;
}

function textValue(value: ParsedValue | undefined, heals: Set<HealReason>): string | null {
  if (!value) return null;
  if (!value.quoted) {
    if (!value.value || /[\s\[\]"'“”‘’]/.test(value.value)) return null;
    heals.add("unquoted single-token label");
  }
  return value.value.length <= 120 ? value.value : null;
}
