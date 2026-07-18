export function normalizeDslWhitespace(text: string): string {
  return text.replace(/[ \t]{2,}/g, " ");
}

export function userInputFromLogLine(line: string, prefixes: readonly string[]): string | undefined {
  for (const prefix of prefixes) {
    if (line.startsWith(prefix)) return line.slice(prefix.length);
  }
  return undefined;
}
