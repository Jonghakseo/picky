export function normalizeDslWhitespace(text: string): string {
  return text.replace(/[ \t]{2,}/g, " ");
}

