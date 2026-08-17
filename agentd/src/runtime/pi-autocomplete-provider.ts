import type { AgentSessionRuntime } from "@earendil-works/pi-coding-agent";
import { CombinedAutocompleteProvider, type SlashCommand } from "@earendil-works/pi-tui";
import { resolveAutocompleteFdPath } from "./pi-sdk-runtime-helpers.js";

// Each built-in must be backed by a public AgentSession API call in
// PiSdkRuntimeSession.handleBuiltinSlashCommand.
export const PICKY_BUILTIN_SLASH_COMMANDS: ReadonlyArray<{ name: string; description: string }> = [
  { name: "new", description: "Start a fresh Pi session in this Picky card" },
  { name: "name", description: "Set the Pi session display name (usage: /name <session name>)" },
  { name: "compact", description: "Manually compact the session context (optional: /compact <focus instructions>)" },
  { name: "reload", description: "Reload Pi skills, extensions, prompts, and context files" },
];

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
