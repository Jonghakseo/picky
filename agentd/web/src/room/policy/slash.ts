/**
 * Slash command autocomplete for the composer.
 *
 * Source: Picky/HUD/PickySlashCommandAutocompletePolicy.swift. The query is the
 * text between a leading "/" and the caret, and it ends at the first space, so
 * "/review this" no longer suggests anything. Ranking matches the HUD: exact
 * name, then prefix, then substring, then a fuzzy subsequence, with the
 * original list order breaking ties.
 */

export type SlashCommandSource = "extension" | "prompt" | "skill" | "builtin";

export interface SlashCommand {
  name: string;
  description?: string;
  source: SlashCommandSource;
}

export const MAX_SLASH_SUGGESTIONS = 20;

/** `PickySlashCommandSource.displayName`; the HUD does not translate these either. */
export const SLASH_SOURCE_LABEL: Record<SlashCommandSource, string> = {
  extension: "Extension",
  prompt: "Prompt",
  skill: "Skill",
  builtin: "Built-in",
};

/** The text being completed, or `null` when the caret is not inside a leading slash word. */
export function slashQuery(text: string, caret: number = text.length): string | null {
  if (!text.startsWith("/") || caret < 1 || caret > text.length) return null;
  const query = text.slice(1, caret);
  return /\s/.test(query) ? null : query;
}

export function slashSuggestions(
  text: string,
  caret: number | undefined,
  commands: readonly SlashCommand[],
  limit = MAX_SLASH_SUGGESTIONS,
): SlashCommand[] {
  const query = slashQuery(text, caret);
  if (query === null) return [];
  return commands
    .map((command, index) => ({ command, index, score: score(command.name, query) }))
    .filter((entry): entry is { command: SlashCommand; index: number; score: number } => entry.score !== null)
    .sort((left, right) => left.score - right.score || left.index - right.index)
    .slice(0, limit)
    .map((entry) => entry.command);
}

/**
 * The draft after accepting a command: "/name " with the caret ready for
 * arguments. Text after the caret stays; an existing space is reused rather
 * than doubled.
 */
export function slashCompletion(text: string, caret: number | undefined, command: SlashCommand): { text: string; caret: number } {
  const remainder = caret === undefined ? "" : text.slice(caret);
  const name = `/${command.name}`;
  if (/^\s/.test(remainder)) return { text: name + remainder, caret: name.length + 1 };
  return { text: `${name} ${remainder}`, caret: name.length + 1 };
}

/** Parses the gateway's `session.slashCommands` answer, dropping anything malformed. */
export function parseSlashCommands(data: unknown): SlashCommand[] {
  const list = (data as { commands?: unknown } | null)?.commands;
  if (!Array.isArray(list)) return [];
  return list.flatMap((entry): SlashCommand[] => {
    const candidate = entry as Partial<SlashCommand> | null;
    if (!candidate || typeof candidate.name !== "string" || candidate.name.length === 0) return [];
    const source = candidate.source && candidate.source in SLASH_SOURCE_LABEL ? candidate.source : "extension";
    return [{
      name: candidate.name,
      source,
      ...(typeof candidate.description === "string" && candidate.description.length > 0 ? { description: candidate.description } : {}),
    }];
  });
}

function score(commandName: string, query: string): number | null {
  if (query.length === 0) return 0;
  const name = commandName.toLowerCase();
  const needle = query.toLowerCase();
  if (name === needle) return 0;
  if (name.startsWith(needle)) return 10 + Math.max(0, name.length - needle.length);
  const at = name.indexOf(needle);
  if (at >= 0) return 100 + at + Math.max(0, name.length - needle.length);
  return fuzzySubsequenceScore(name, needle);
}

function fuzzySubsequenceScore(name: string, needle: string): number | null {
  const haystack = Array.from(name);
  let start = 0;
  let gaps = 0;
  for (const character of needle) {
    const match = haystack.indexOf(character, start);
    if (match < 0) return null;
    gaps += match - start;
    start = match + 1;
  }
  return 200 + gaps + Math.max(0, haystack.length - Array.from(needle).length);
}
