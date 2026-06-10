import type { RuntimeSlashCommand } from "../runtime/types.js";

export function isNameSlashCommand(text: string): boolean {
  return /^\s*\/name(\s|$)/.test(text);
}

export function isCompactSlashCommand(text: string): boolean {
  return /^\s*\/compact(\s|$)/.test(text);
}

export function isReloadSlashCommand(text: string): boolean {
  return /^\s*\/reload(\s|$)/.test(text);
}

export function isNoTurnStateRestoringSlashCommand(text: string): boolean {
  return isNameSlashCommand(text) || isCompactSlashCommand(text) || isReloadSlashCommand(text);
}

// Matches `/name`, `/name args` where name is an identifier-like token without `/` or `:`.
// Intentionally rejects `/skill:context7-cli` (skill commands stay visible as user text) and
// `/Users/foo` (path-like inputs).
export function isNonSkillSlashCommand(text: string): boolean {
  return /^\s*\/[a-zA-Z][\w-]*(\s|$)/.test(text);
}

export function normalizeSlashCommands(commands: RuntimeSlashCommand[]): RuntimeSlashCommand[] {
  const normalized: RuntimeSlashCommand[] = [];
  const seen = new Set<string>();
  for (const command of commands) {
    const name = command.name.trim();
    if (!name) continue;
    const source = command.source;
    if (source !== "extension" && source !== "prompt" && source !== "skill" && source !== "builtin") continue;
    const key = `${source}:${name}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const description = command.description?.trim();
    normalized.push({ name, source, ...(description ? { description } : {}) });
  }
  return normalized;
}
