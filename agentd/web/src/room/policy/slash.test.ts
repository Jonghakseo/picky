/**
 * What the phone composer offers after "/": the same rows, in the same order,
 * as the HUD (PickySlashCommandAutocompletePolicy), and a draft that is ready
 * for arguments once a row is tapped.
 */
import { describe, expect, it } from "vitest";

import { parseSlashCommands, slashCompletion, slashSuggestions, type SlashCommand } from "./slash";

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
