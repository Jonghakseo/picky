export function cleanFinalAnswer(text: string | undefined): string | undefined {
  const normalized = text?.replace(/\r\n/g, "\n").trim();
  return normalized ? normalized : undefined;
}

export function summaryFromFinalAnswer(text: string): string {
  const firstParagraph = text.split(/\n\s*\n/).find((part) => part.trim().length > 0)?.trim() ?? text.trim();
  const singleLine = firstParagraph.replace(/\s+/g, " ");
  return singleLine.length > 220 ? `${singleLine.slice(0, 217)}...` : singleLine;
}
