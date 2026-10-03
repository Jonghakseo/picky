import type { AgentSession, AgentSessionRuntime } from "@earendil-works/pi-coding-agent";
import { CombinedAutocompleteProvider, type SlashCommand } from "@earendil-works/pi-tui";
import { resolveAutocompleteFdPath } from "./pi-sdk-runtime-helpers.js";
import type { RuntimeSlashCommand } from "./types.js";

// Each built-in must be backed by a public AgentSession API call in
// PiSdkRuntimeSession.handleBuiltinSlashCommand.
export const PICKY_BUILTIN_SLASH_COMMANDS: ReadonlyArray<{ name: string; description: string }> = [
  { name: "new", description: "Start a fresh Pi session in this Picky card" },
  { name: "name", description: "Set the Pi session display name (usage: /name <session name>)" },
  { name: "compact", description: "Manually compact the session context (optional: /compact <focus instructions>)" },
  { name: "reload", description: "Reload Pi skills, extensions, prompts, and context files" },
];

/**
 * Every slash command the app can offer for this session.
 *
 * Trade-off: we expose every extension command instead of trying to filter out ones that
 * depend on Pi TUI surfaces Picky does not implement.
 *
 * Why we don't filter:
 *   - Pi SDK assigns the agentDir itself (e.g. ~/.pi/agent) as the baseDir for every
 *     auto-discovered local extension under ~/.pi/agent/extensions/*. A directory-level
 *     `ui.custom` scan therefore flags ALL local extensions if any single sibling uses it,
 *     producing false positives for clean extensions like /github:pr-merge.
 *   - ExtensionUiBridge implements the common surfaces (notify/confirm/select/input/
 *     editor/askUserQuestion/setStatus/setTitle) and composes addAutocompleteProvider
 *     over Pi's built-in slash/path provider. Terminal-component surfaces such as
 *     setWidget/setHeader/setFooter/setEditorComponent remain no-ops.
 *   - The only hard failure is `ui.custom`, which throws PickyOverlayUnsupportedError.
 *     extension-crash-guard.ts swallows that (and any extension TypeError such as a missing
 *     `theme.fg`) so the daemon stays alive; the user just sees the command no-op or error.
 *
 * Cost we accept: a few overlay-heavy commands (e.g. /widgets, /sub:peek, /subagents) show
 * up in autocomplete but produce only an error or empty effect when invoked.
 */
export function listSessionSlashCommands(session: AgentSession): RuntimeSlashCommand[] {
  return [
    ...PICKY_BUILTIN_SLASH_COMMANDS.map((command) => ({ ...command, source: "builtin" as const })),
    ...session.extensionRunner.getRegisteredCommands().map((command) => ({
      name: command.invocationName,
      description: command.description,
      source: "extension" as const,
    })),
    ...session.promptTemplates.map((template) => ({
      name: template.name,
      description: template.description,
      source: "prompt" as const,
    })),
    ...session.resourceLoader.getSkills().skills.map((skill) => ({
      name: `skill:${skill.name}`,
      description: skill.description,
      source: "skill" as const,
    })),
  ];
}

export function createBaseAutocompleteProvider(
  runtime: AgentSessionRuntime,
  hasSessionFile: boolean,
): CombinedAutocompleteProvider {
  const commands: SlashCommand[] = [
    ...PICKY_BUILTIN_SLASH_COMMANDS,
    ...(hasSessionFile ? [{ name: "tree", description: "Rewind to an earlier message" }] : []),
    ...runtime.session.extensionRunner.getRegisteredCommands().map((command) => ({
      name: command.invocationName,
      description: command.description,
      getArgumentCompletions: command.getArgumentCompletions,
    })),
    ...runtime.session.promptTemplates.map((template) => ({
      name: template.name,
      description: template.description,
    })),
    ...runtime.session.resourceLoader.getSkills().skills.map((skill) => ({
      name: `skill:${skill.name}`,
      description: skill.description,
    })),
  ];
  return new CombinedAutocompleteProvider(
    commands,
    runtime.session.sessionManager.getCwd(),
    resolveAutocompleteFdPath(),
  );
}
