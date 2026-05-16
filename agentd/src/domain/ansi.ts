const ANSI_ESCAPE_PATTERN = /\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])/g;

export function stripAnsiEscapeSequences(value: string): string {
  return value.replace(ANSI_ESCAPE_PATTERN, "");
}
