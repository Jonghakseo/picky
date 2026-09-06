export const STEER_PREFIX = "steer: ";
export const FOLLOWUP_PREFIX = "follow-up: ";
export const HANDOFF_PREFIX = "Picky handoff: ";
export const EXTENSION_ANSWER_PREFIX = "extension ui answer: ";

export interface PrefixedUserInput {
  source: "steer" | "followUp" | "handoff" | "extensionAnswer";
  text: string;
}

const USER_INPUT_PREFIXES: ReadonlyArray<[PrefixedUserInput["source"], string]> = [
  ["steer", STEER_PREFIX],
  ["followUp", FOLLOWUP_PREFIX],
  ["handoff", HANDOFF_PREFIX],
  ["extensionAnswer", EXTENSION_ANSWER_PREFIX],
];

/** Recognizes the daemon's own user-input journal lines and returns their typed source. */
export function prefixedUserInputFromLogLine(line: string): PrefixedUserInput | undefined {
  for (const [source, prefix] of USER_INPUT_PREFIXES) {
    if (line.startsWith(prefix)) return { source, text: line.slice(prefix.length) };
  }
  return undefined;
}
