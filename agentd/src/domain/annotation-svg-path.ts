import type { AnnotationPathCommand } from "./annotation-validation.js";

const MAX_PATH_COMMANDS = 32;
const SUPPORTED_COMMANDS = new Set(["M", "L", "C", "H", "V", "S", "Q", "T", "Z"]);
const NUMBER_PATTERN = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/;

type PathToken = { kind: "command"; value: string } | { kind: "number"; value: number; rounded: boolean };
interface Point { x: number; y: number }

export interface ParsedAnnotationSvgPath {
  commands: AnnotationPathCommand[];
  normalized: boolean;
  rounded: boolean;
}

export function parseAnnotationSvgPath(source: string): ParsedAnnotationSvgPath | undefined {
  const tokens = tokenize(source);
  return tokens && tokens.length > 0 ? new AnnotationSvgPathParser(tokens).parse() : undefined;
}

class AnnotationSvgPathParser {
  private readonly commands: AnnotationPathCommand[] = [];
  private index = 0;
  private activeCommand?: string;
  private current = point(0, 0);
  private subpathStart?: Point;
  private previousCommand?: string;
  private previousCubicControl?: Point;
  private previousQuadraticControl?: Point;
  private normalized = false;
  private readonly rounded: boolean;

  constructor(private readonly tokens: PathToken[]) {
    this.rounded = tokens.some((token) => token.kind === "number" && token.rounded);
  }

  parse(): ParsedAnnotationSvgPath | undefined {
    while (this.index < this.tokens.length) {
      const explicitCommand = this.consumeExplicitCommand();
      if (explicitCommand === undefined || !this.activeCommand) return undefined;
      const upper = this.activeCommand.toUpperCase();
      if (upper === "A" || !SUPPORTED_COMMANDS.has(upper)) return undefined;
      const relative = this.activeCommand !== upper;
      this.normalized ||= relative || !["M", "L", "C"].includes(upper);

      if (upper === "Z") {
        if (!this.closePath(explicitCommand)) return undefined;
        continue;
      }

      const values = this.readNumbers(commandArity(upper));
      if (!values) return undefined;
      if (!explicitCommand) this.normalized = true;
      if (!this.appendCommand(upper, values, relative, explicitCommand)) return undefined;
    }

    if (this.commands.length < 2 || this.commands[0]?.type !== "move" || !hasVisibleExtent(this.commands)) return undefined;
    return { commands: this.commands, normalized: this.normalized, rounded: this.rounded };
  }

  private consumeExplicitCommand(): boolean | undefined {
    const token = this.tokens[this.index];
    if (token?.kind === "command") {
      this.activeCommand = token.value;
      this.index += 1;
      return true;
    }
    return this.activeCommand ? false : undefined;
  }

  private readNumbers(count: number): number[] | undefined {
    const values: number[] = [];
    for (let offset = 0; offset < count; offset += 1) {
      const token = this.tokens[this.index + offset];
      if (!token || token.kind !== "number") return undefined;
      values.push(token.value);
    }
    this.index += count;
    return values;
  }

  private appendCommand(upper: string, values: number[], relative: boolean, explicit: boolean): boolean {
    switch (upper) {
      case "M": return this.appendMove(values, relative, explicit);
      case "L": return this.appendLine(values, relative);
      case "H": return this.appendHorizontal(values[0]!, relative);
      case "V": return this.appendVertical(values[0]!, relative);
      case "C": return this.appendCubic(values, relative);
      case "S": return this.appendSmoothCubic(values, relative);
      case "Q": return this.appendQuadratic(values, relative);
      case "T": return this.appendSmoothQuadratic(values, relative);
      default: return false;
    }
  }

  private appendMove(values: number[], relative: boolean, explicit: boolean): boolean {
    if (!explicit || this.commands.length > 0) return false;
    const destination = this.absolute(values[0]!, values[1]!, relative);
    if (!this.append({ type: "move", x: destination.x, y: destination.y })) return false;
    this.subpathStart = destination;
    this.finish(destination, "M");
    // Additional coordinate pairs after M are SVG shorthand for L.
    this.activeCommand = relative ? "l" : "L";
    return true;
  }

  private appendLine(values: number[], relative: boolean): boolean {
    if (!this.subpathStart) return false;
    const destination = this.absolute(values[0]!, values[1]!, relative);
    if (!this.append({ type: "line", x: destination.x, y: destination.y })) return false;
    this.finish(destination, "L");
    return true;
  }

  private appendHorizontal(value: number, relative: boolean): boolean {
    if (!this.subpathStart) return false;
    const destination = point(relative ? this.current.x + value : value, this.current.y);
    if (!this.append({ type: "line", x: destination.x, y: destination.y })) return false;
    this.finish(destination, "H");
    return true;
  }

  private appendVertical(value: number, relative: boolean): boolean {
    if (!this.subpathStart) return false;
    const destination = point(this.current.x, relative ? this.current.y + value : value);
    if (!this.append({ type: "line", x: destination.x, y: destination.y })) return false;
    this.finish(destination, "V");
    return true;
  }

  private appendCubic(values: number[], relative: boolean): boolean {
    if (!this.subpathStart) return false;
    const control1 = this.absolute(values[0]!, values[1]!, relative);
    const control2 = this.absolute(values[2]!, values[3]!, relative);
    const destination = this.absolute(values[4]!, values[5]!, relative);
    if (!this.append(cubic(control1, control2, destination))) return false;
    this.finish(destination, "C", control2);
    return true;
  }

  private appendSmoothCubic(values: number[], relative: boolean): boolean {
    if (!this.subpathStart) return false;
    const control1 = this.previousCommand === "C" || this.previousCommand === "S"
      ? reflected(this.previousCubicControl ?? this.current, this.current)
      : this.current;
    const control2 = this.absolute(values[0]!, values[1]!, relative);
    const destination = this.absolute(values[2]!, values[3]!, relative);
    if (!this.append(cubic(control1, control2, destination))) return false;
    this.finish(destination, "S", control2);
    return true;
  }

  private appendQuadratic(values: number[], relative: boolean): boolean {
    if (!this.subpathStart) return false;
    const control = this.absolute(values[0]!, values[1]!, relative);
    const destination = this.absolute(values[2]!, values[3]!, relative);
    if (!this.append(quadraticAsCubic(this.current, control, destination))) return false;
    this.finish(destination, "Q", undefined, control);
    return true;
  }

  private appendSmoothQuadratic(values: number[], relative: boolean): boolean {
    if (!this.subpathStart) return false;
    const control = this.previousCommand === "Q" || this.previousCommand === "T"
      ? reflected(this.previousQuadraticControl ?? this.current, this.current)
      : this.current;
    const destination = this.absolute(values[0]!, values[1]!, relative);
    if (!this.append(quadraticAsCubic(this.current, control, destination))) return false;
    this.finish(destination, "T", undefined, control);
    return true;
  }

  private closePath(explicit: boolean): boolean {
    if (!explicit || !this.subpathStart || this.commands.length === 0) return false;
    if (!samePoint(this.current, this.subpathStart)
        && !this.append({ type: "line", x: this.subpathStart.x, y: this.subpathStart.y })) return false;
    this.finish(this.subpathStart, "Z");
    this.activeCommand = undefined;
    return true;
  }

  private append(command: AnnotationPathCommand): boolean {
    this.commands.push(command);
    return this.commands.length <= MAX_PATH_COMMANDS;
  }

  private absolute(x: number, y: number, relative: boolean): Point {
    return relative ? point(this.current.x + x, this.current.y + y) : point(x, y);
  }

  private finish(destination: Point, command: string, cubicControl?: Point, quadraticControl?: Point): void {
    this.current = destination;
    this.previousCommand = command;
    this.previousCubicControl = cubicControl;
    this.previousQuadraticControl = quadraticControl;
  }
}

function tokenize(source: string): PathToken[] | undefined {
  const tokens: PathToken[] = [];
  let index = 0;
  while (index < source.length) {
    const character = source[index]!;
    if (/\s|,/.test(character)) {
      index += 1;
      continue;
    }
    if (/[A-Za-z]/.test(character)) {
      tokens.push({ kind: "command", value: character });
      index += 1;
      continue;
    }
    const match = source.slice(index).match(NUMBER_PATTERN)?.[0];
    if (!match) return undefined;
    const parsed = Number(match);
    if (!Number.isFinite(parsed)) return undefined;
    const value = Math.round(parsed);
    tokens.push({ kind: "number", value, rounded: value !== parsed });
    index += match.length;
  }
  return tokens;
}

function commandArity(command: string): number {
  switch (command) {
    case "M": case "L": case "T": return 2;
    case "H": case "V": return 1;
    case "S": case "Q": return 4;
    case "C": return 6;
    default: return 0;
  }
}

function point(x: number, y: number): Point { return { x, y }; }
function samePoint(lhs: Point, rhs: Point): boolean { return lhs.x === rhs.x && lhs.y === rhs.y; }
function reflected(value: Point, origin: Point): Point { return point(origin.x * 2 - value.x, origin.y * 2 - value.y); }

function cubic(control1: Point, control2: Point, destination: Point): AnnotationPathCommand {
  return { type: "cubic", c1x: control1.x, c1y: control1.y, c2x: control2.x, c2y: control2.y, x: destination.x, y: destination.y };
}

function quadraticAsCubic(start: Point, control: Point, destination: Point): AnnotationPathCommand {
  return cubic(
    point(start.x + (control.x - start.x) * 2 / 3, start.y + (control.y - start.y) * 2 / 3),
    point(destination.x + (control.x - destination.x) * 2 / 3, destination.y + (control.y - destination.y) * 2 / 3),
    destination,
  );
}

function hasVisibleExtent(commands: AnnotationPathCommand[]): boolean {
  const first = commands[0];
  if (!first) return false;
  return commands.some((command) => {
    if (command.x !== first.x || command.y !== first.y) return true;
    return command.type === "cubic"
      && (command.c1x !== first.x || command.c1y !== first.y || command.c2x !== first.x || command.c2y !== first.y);
  });
}
