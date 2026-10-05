/**
 * What the phone composer offers after "/": the same rows, in the same order,
 * as the HUD (PickySlashCommandAutocompletePolicy), and a draft that is ready
 * for arguments once a row is tapped.
 */
import { describe, expect, it } from "vitest";

import { parseSlashCommands, slashCompletion, slashKeyAction, slashSuggestions, type SlashCommand } from "./slash";

const commands: SlashCommand[] = [
  { name: "skill:review", source: "skill" },
  { name: "compact", source: "builtin" },
  { name: "review", source: "prompt" },
  { name: "reload", source: "builtin" },
];

const names = (text: string, caret?: number): string[] => slashSuggestions(text, caret, commands).map((command) => command.name);

describe("slash suggestions", () => {
  it("lists every command for a bare slash, in the daemon's order", () => {
    expect(names("/")).toEqual(["skill:review", "compact", "review", "reload"]);
  });

  it("ranks an exact name, then prefixes, then substrings, then fuzzy matches", () => {
    expect(names("/review")).toEqual(["review", "skill:review"]);
    expect(names("/re")).toEqual(["review", "reload", "skill:review"]);
    expect(names("/cpt")).toEqual(["compact"]);
  });

  it("offers nothing once the command has its argument, or when the slash is not first", () => {
    expect(names("/review this")).toEqual([]);
    expect(names("see /review")).toEqual([]);
  });

  it("completes only the word before the caret", () => {
    expect(names("/co more", 3)).toEqual(["compact"]);
  });
});

describe("accepting a suggestion", () => {
  it("leaves the caret after one space, ready for arguments", () => {
    expect(slashCompletion("/rev", 4, commands[2]!)).toEqual({ text: "/review ", caret: 8 });
  });

  it("keeps text after the caret without doubling its space", () => {
    expect(slashCompletion("/co the rest", 3, commands[1]!)).toEqual({ text: "/compact the rest", caret: 9 });
  });
});

describe("the gateway's command list", () => {
  it("keeps well-formed entries and drops the rest", () => {
    expect(parseSlashCommands({ commands: [{ name: "a", source: "skill", description: "d" }, { name: "" }, null, { name: "b", source: "weird" }] }))
      .toEqual([{ name: "a", source: "skill", description: "d" }, { name: "b", source: "extension" }]);
    expect(parseSlashCommands(null)).toEqual([]);
  });
});

describe("keys in the open list", () => {
  const press = (key: string, overrides: Partial<Parameters<typeof slashKeyAction>[0]> = {}) =>
    slashKeyAction({ key, shiftKey: false, altKey: false, metaKey: false, ctrlKey: false, composing: false, keyboard: true, ...overrides });

  it("moves with the arrows, takes the row with Return or Tab, and closes with Esc", () => {
    expect(press("ArrowDown")).toBe("next");
    expect(press("ArrowUp")).toBe("previous");
    expect(press("Enter")).toBe("accept");
    expect(press("Tab")).toBe("accept");
    expect(press("Escape")).toBe("dismiss");
  });

  it("leaves Shift-Return, Option-Return and an IME commit to the composer", () => {
    expect(press("Enter", { shiftKey: true })).toBe("none");
    expect(press("Enter", { altKey: true })).toBe("none");
    expect(press("Enter", { composing: true })).toBe("none");
  });

  it("keeps a phone keyboard's Return as a new line until a hardware key is seen", () => {
    expect(press("Enter", { keyboard: false })).toBe("none");
    expect(press("ArrowDown", { keyboard: false })).toBe("next");
  });
});
