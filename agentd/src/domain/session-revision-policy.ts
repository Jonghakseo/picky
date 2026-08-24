export function nextRevision(current: number, changed: boolean): number {
  if (!Number.isSafeInteger(current) || current < 0) {
    throw new Error(`Invalid session revision: ${current}`);
  }
  if (!changed) return current;
  if (current === Number.MAX_SAFE_INTEGER) {
    throw new Error("Session revision reached the maximum safe revision");
  }
  return current + 1;
}
