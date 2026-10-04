#!/usr/bin/env python3
"""Generate tokens.css for the remote PWA prototypes from the HUD design system.

The HUD is the visual source of truth, so this script only reads Swift sources:

  Picky/DesignSystem.swift            DS.Colors, GroupAccent, Integration, Spacing,
                                      CornerRadius, Elevation, Animation, StateLayer
  Picky/HUD/PickyHUDTypography.swift  text sizes and text roles

Usage:
  python3 tools/extract-tokens.py           write tokens.css
  python3 tools/extract-tokens.py --check   exit 1 when tokens.css differs from the sources

Anything the evaluator cannot read is reported on stderr instead of guessed.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

PROTO = Path(__file__).resolve().parent.parent
REPO = PROTO.parents[2]
DESIGN_SYSTEM = REPO / "Picky/DesignSystem.swift"
TYPOGRAPHY = REPO / "Picky/HUD/PickyHUDTypography.swift"
OUTPUT = PROTO / "tokens.css"

WEIGHTS = {
    "ultraLight": 100, "thin": 200, "light": 300, "regular": 400, "medium": 500,
    "semibold": 600, "bold": 700, "heavy": 800, "black": 900,
}
FAMILIES = {
    None: "var(--hud-font-family)",
    "default": "var(--hud-font-family)",
    "monospaced": "var(--hud-font-family-mono)",
    "rounded": "var(--hud-font-family-rounded)",
}
SYSTEM_COLORS = {"white": (255, 255, 255, 1.0), "black": (0, 0, 0, 1.0), "clear": (0, 0, 0, 0.0)}

warnings: list[str] = []


def warn(message: str) -> None:
    warnings.append(message)


def kebab(name: str) -> str:
    """camelCase -> kebab-case; digits stay on the word before them (surface1, blue600)."""
    return re.sub(r"(?<=[a-z0-9])([A-Z])", r"-\1", name).lower()


def strip_comments(source: str) -> str:
    """Remove // comments outside string literals, keeping line numbers."""
    out_lines = []
    for line in source.splitlines():
        in_string = False
        cut = len(line)
        i = 0
        while i < len(line):
            ch = line[i]
            if ch == '"' and (i == 0 or line[i - 1] != "\\"):
                in_string = not in_string
            elif not in_string and line.startswith("//", i):
                cut = i
                break
            i += 1
        out_lines.append(line[:cut])
    return "\n".join(out_lines)


@dataclass
class Statement:
    path: tuple[str, ...]
    name: str
    expr: str
    line: int


def iter_statements(source: str) -> list[Statement]:
    """Collect `static let NAME = EXPR` and `static var NAME: T { EXPR }` with their enum path."""
    lines = strip_comments(source).splitlines()
    statements: list[Statement] = []
    enum_stack: list[tuple[str, int]] = []  # (enum name, brace depth inside the enum)
    depth = 0
    i = 0
    while i < len(lines):
        line = lines[i]
        enum_match = re.match(r"\s*(?:private\s+|fileprivate\s+)?enum\s+(\w+)\b[^{]*\{", line)
        let_match = re.match(r"\s*(?:private\s+)?static\s+let\s+(\w+)\s*(?::\s*[\w.]+)?\s*=\s*(.*)$", line)
        var_match = re.match(r"\s*(?:private\s+)?static\s+var\s+(\w+)\s*:\s*[\w.]+\s*\{(.*)$", line)
        path = tuple(name for name, _ in enum_stack)
        if let_match:
            expr = let_match.group(2)
            start = i
            while expr.count("(") > expr.count(")") and i + 1 < len(lines):
                i += 1
                expr += " " + lines[i].strip()
            statements.append(Statement(path, let_match.group(1), expr.strip(), start + 1))
            depth += expr.count("{") - expr.count("}")
        elif var_match:
            body = var_match.group(2)
            start = i
            balance = 1 + body.count("{") - body.count("}")
            while balance > 0 and i + 1 < len(lines):
                i += 1
                balance += lines[i].count("{") - lines[i].count("}")
                body += " " + lines[i].strip()
            body = body.strip()
            if body.endswith("}"):
                body = body[:-1].strip()
            statements.append(Statement(path, var_match.group(1), body, start + 1))
        else:
            if enum_match:
                depth += 1
                enum_stack.append((enum_match.group(1), depth))
                line = line[enum_match.end():]
            for ch in line:
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    if enum_stack and enum_stack[-1][1] == depth:
                        enum_stack.pop()
                    depth -= 1
        i += 1
    return statements


# ---------------------------------------------------------------- colors

RGBA = tuple  # (r, g, b, a)


class ColorEvaluator:
    """Evaluates the small Color expression grammar used by DS tokens."""

    def __init__(self) -> None:
        self.values: dict[str, tuple[RGBA, RGBA]] = {}

    def lookup(self, ident: str, enum: str) -> tuple[RGBA, RGBA] | None:
        candidates = [ident] if "." in ident else [f"{enum}.{ident}", ident]
        if ident.startswith("Colors."):
            candidates = [ident]
        for key in candidates:
            if key in self.values:
                return self.values[key]
        return None

    def evaluate(self, expr: str, enum: str) -> tuple[RGBA, RGBA] | None:
        self.text = expr.replace("\n", " ").strip()
        self.pos = 0
        self.enum = enum
        try:
            value = self.parse_expr()
            self.skip_ws()
            if self.pos != len(self.text):
                return None
            return value
        except ValueError:
            return None

    # grammar helpers
    def skip_ws(self) -> None:
        while self.pos < len(self.text) and self.text[self.pos].isspace():
            self.pos += 1

    def take(self, literal: str) -> bool:
        self.skip_ws()
        if self.text.startswith(literal, self.pos):
            self.pos += len(literal)
            return True
        return False

    def expect(self, literal: str) -> None:
        if not self.take(literal):
            raise ValueError(f"expected {literal!r} at {self.pos} in {self.text!r}")

    def number(self) -> float:
        self.skip_ws()
        match = re.match(r"-?\d+(?:\.\d+)?", self.text[self.pos:])
        if not match:
            raise ValueError("number")
        self.pos += match.end()
        return float(match.group(0))

    def ident(self) -> str:
        self.skip_ws()
        match = re.match(r"[A-Za-z_][\w.]*", self.text[self.pos:])
        if not match:
            raise ValueError("identifier")
        # Leave a trailing `.opacity` for the postfix loop.
        name = match.group(0)
        if ".opacity" in name:
            name = name.split(".opacity", 1)[0]
        self.pos += len(name)
        return name

    def parse_expr(self) -> tuple[RGBA, RGBA]:
        value = self.parse_primary()
        while self.take(".opacity("):
            alpha = self.number()
            self.expect(")")
            value = tuple((r, g, b, round(a * alpha, 4)) for r, g, b, a in value)  # type: ignore[assignment]
        return value

    def parse_primary(self) -> tuple[RGBA, RGBA]:
        if self.take("Color("):
            if self.take("hex:"):
                self.skip_ws()
                match = re.match(r'"#?([0-9A-Fa-f]{6})"', self.text[self.pos:])
                if not match:
                    raise ValueError("hex")
                self.pos += match.end()
                self.expect(")")
                hex_value = match.group(1)
                rgba = (int(hex_value[0:2], 16), int(hex_value[2:4], 16), int(hex_value[4:6], 16), 1.0)
                return (rgba, rgba)
            if self.take("light:"):
                light = self.parse_expr()
                self.expect(",")
                self.expect("dark:")
                dark = self.parse_expr()
                self.expect(")")
                return (light[0], dark[1])
            raise ValueError("unsupported Color initializer")
        if self.take("."):
            name = self.ident()
            if name not in SYSTEM_COLORS:
                raise ValueError(f"system color {name}")
            rgba = SYSTEM_COLORS[name]
            return (rgba, rgba)
        name = self.ident()
        found = self.lookup(name, self.enum)
        if found is None:
            raise ValueError(f"unknown reference {name}")
        return found


def css_color(rgba: RGBA) -> str:
    r, g, b, a = rgba
    if a >= 1:
        return f"#{r:02x}{g:02x}{b:02x}"
    alpha = f"{a:.4f}".rstrip("0").rstrip(".")
    return f"rgba({r}, {g}, {b}, {alpha})"


# ---------------------------------------------------------------- numbers

def number_value(expr: str) -> float | None:
    expr = expr.strip()
    if expr == ".infinity":
        return float("inf")
    if re.fullmatch(r"-?\d+(?:\.\d+)?", expr):
        return float(expr)
    return None


def fmt(value: float) -> str:
    text = f"{value:.4f}".rstrip("0").rstrip(".")
    return text if text else "0"


def scalar_tokens(statements: list[Statement]) -> list[tuple[str, str]]:
    """Spacing, radii, elevation, durations, and state layers as CSS custom properties."""
    out: list[tuple[str, str]] = []
    prefixes = {
        "Spacing": "--ds-space-",
        "CornerRadius": "--ds-radius-",
        "Elevation": "--ds-elevation-",
        "Animation": "--ds-duration-",
        "StateLayer": "--ds-state-",
    }

    def var_name(enum: str, name: str) -> str:
        if enum == "Spacing":
            match = re.fullmatch(r"space(\d+)", name)
            if match:
                return f"--ds-space-{match.group(1)}"
        return prefixes[enum] + kebab(name)

    for st in statements:
        if len(st.path) != 2 or st.path[0] != "DS" or st.path[1] not in prefixes:
            continue
        enum = st.path[1]
        name = var_name(enum, st.name)
        value = number_value(st.expr)
        if value is None:
            if re.fullmatch(r"\w+", st.expr):
                out.append((name, f"var({var_name(enum, st.expr)})"))
            else:
                warn(f"DesignSystem.swift:{st.line} DS.{enum}.{st.name} = {st.expr!r} is not a literal")
            continue
        if enum == "Animation":
            out.append((name, f"{fmt(value * 1000)}ms"))
        elif enum == "StateLayer" or "Opacity" in st.name:
            out.append((name, fmt(value)))
        elif value == float("inf"):
            out.append((name, "9999px"))
        else:
            out.append((name, f"{fmt(value)}px"))
    return out


def color_tokens(statements: list[Statement]) -> list[tuple[str, RGBA, RGBA]]:
    evaluator = ColorEvaluator()
    out: list[tuple[str, RGBA, RGBA]] = []
    color_enums = {("DS", "Colors"), ("DS", "GroupAccent"), ("DS", "Integration", "GitHub"), ("DS", "Integration", "Sentry")}
    for st in statements:
        if st.path not in color_enums:
            continue
        enum_key = ".".join(st.path[1:])
        value = evaluator.evaluate(st.expr, enum_key)
        if value is None:
            warn(f"DesignSystem.swift:{st.line} DS.{enum_key}.{st.name} = {st.expr!r} could not be evaluated")
            continue
        evaluator.values[f"{enum_key}.{st.name}"] = value
        if st.path[1] == "Colors":
            name = f"--ds-color-{kebab(st.name)}"
        elif st.path[1] == "GroupAccent":
            name = f"--ds-group-{kebab(st.name)}"
        else:
            name = "--ds-" + "-".join(kebab(part) for part in st.path[1:]) + f"-{kebab(st.name)}"
        out.append((name, value[0], value[1]))
    return out


# ---------------------------------------------------------------- typography

def typography_tokens(source: str) -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    text = strip_comments(source)
    base: dict[str, float] = {}
    for st in iter_statements(text):
        if st.path[-1:] == ("BaseSize",):
            value = number_value(st.expr)
            if value is None:
                warn(f"PickyHUDTypography.swift:{st.line} BaseSize.{st.name} is not a literal")
            else:
                base[st.name] = value

    sizes: list[tuple[str, str]] = []
    for st in iter_statements(text):
        if st.path[-1:] != ("Size",):
            continue
        match = re.fullmatch(r"(?:BaseSize\.(\w+)|(\d+(?:\.\d+)?))\s*\*\s*scale", st.expr)
        if not match:
            warn(f"PickyHUDTypography.swift:{st.line} Size.{st.name} = {st.expr!r} could not be read")
            continue
        points = base.get(match.group(1)) if match.group(1) else float(match.group(2))
        if points is None:
            warn(f"PickyHUDTypography.swift:{st.line} Size.{st.name} references unknown BaseSize")
            continue
        sizes.append((f"--hud-size-{kebab(st.name)}", f"calc({fmt(points)}px * var(--hud-font-scale))"))

    size_names = {name for name, _ in sizes}
    roles: list[tuple[str, str]] = []
    font_pattern = r"\.system\(size:\s*Size\.(\w+),\s*weight:\s*\.(\w+)(?:,\s*design:\s*\.(\w+))?\)"

    def role_value(size: str, weight: str, design: str | None, where: str) -> str | None:
        size_var = f"--hud-size-{kebab(size)}"
        if size_var not in size_names or weight not in WEIGHTS or design not in FAMILIES:
            warn(f"PickyHUDTypography.swift {where}: unsupported font {size}/{weight}/{design}")
            return None
        return f"{WEIGHTS[weight]} var({size_var}) {FAMILIES[design]}"

    for st in iter_statements(text):
        if st.path != ("PickyHUDTypography",):
            continue
        match = re.fullmatch(font_pattern, st.expr)
        if match:
            value = role_value(match.group(1), match.group(2), match.group(3), f"line {st.line}")
            if value:
                roles.append((f"--hud-type-{kebab(st.name)}", value))
        elif re.fullmatch(r"\w+", st.expr):
            roles.append((f"--hud-type-{kebab(st.name)}", f"var(--hud-type-{kebab(st.expr)})"))
    # heading(level:) is a function, not a static var.
    for match in re.finditer(r"case\s+\d+:\s*return\s+" + font_pattern, text):
        value = role_value(match.group(1), match.group(2), match.group(3), "heading(level:)")
        if value:
            roles.append((f"--hud-type-{kebab(match.group(1))}", value))
    for match in re.finditer(r"default:\s*return\s+" + font_pattern, text):
        value = role_value(match.group(1), match.group(2), match.group(3), "heading(level:) default")
        if value and all(name != f"--hud-type-{kebab(match.group(1))}" for name, _ in roles):
            roles.append((f"--hud-type-{kebab(match.group(1))}", value))
    return sizes, roles


# ---------------------------------------------------------------- output

def render() -> str:
    ds_statements = iter_statements(DESIGN_SYSTEM.read_text())
    colors = color_tokens(ds_statements)
    scalars = scalar_tokens(ds_statements)
    sizes, roles = typography_tokens(TYPOGRAPHY.read_text())

    lines = [
        "/* GENERATED by tools/extract-tokens.py. Do not edit by hand.",
        " * Sources: Picky/DesignSystem.swift, Picky/HUD/PickyHUDTypography.swift.",
        " * Regenerate: python3 tools/extract-tokens.py   Verify: python3 tools/extract-tokens.py --check",
        " */",
        "",
        ":root {",
        "  color-scheme: light;",
        "  --hud-font-scale: 1;",
        '  --hud-font-family: -apple-system, BlinkMacSystemFont, system-ui, "Apple SD Gothic Neo", sans-serif;',
        '  --hud-font-family-mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace;',
        '  --hud-font-family-rounded: ui-rounded, "SF Pro Rounded", -apple-system, system-ui, sans-serif;',
    ]
    lines += ["", "  /* Colors (light, or both modes when identical) */"]
    lines += [f"  {name}: {css_color(light)};" for name, light, _ in colors]
    lines += ["", "  /* Spacing, radii, elevation, motion, state layers */"]
    lines += [f"  {name}: {value};" for name, value in scalars]
    lines += ["", "  /* Text sizes scale with --hud-font-scale like the app-wide font scale */"]
    lines += [f"  {name}: {value};" for name, value in sizes]
    lines += ["", "  /* Text roles: use as `font: var(--hud-type-body);` */"]
    lines += [f"  {name}: {value};" for name, value in roles]
    lines += ["}", ""]

    dark_lines = [f"  {name}: {css_color(dark)};" for name, light, dark in colors if light != dark]
    lines += ['html[data-theme="dark"] {', "  color-scheme: dark;", *dark_lines, "}", ""]
    lines += [
        "@media (prefers-color-scheme: dark) {",
        '  html:not([data-theme="light"]) {',
        "    color-scheme: dark;",
        *["  " + line for line in dark_lines],
        "  }",
        "}",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail when tokens.css is out of date")
    args = parser.parse_args()

    generated = render()
    for message in warnings:
        print(f"warning: {message}", file=sys.stderr)

    if args.check:
        current = OUTPUT.read_text() if OUTPUT.exists() else ""
        if current != generated:
            print("tokens.css is out of date. Run: python3 tools/extract-tokens.py", file=sys.stderr)
            return 1
        print("tokens.css matches the Swift design system.")
        return 0

    OUTPUT.write_text(generated)
    count = generated.count(": ") - generated.count("/*")
    print(f"wrote {OUTPUT.relative_to(REPO)} ({len(generated.splitlines())} lines, {len(warnings)} warnings)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
