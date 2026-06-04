export function isTransientAgentBusyError(message: string | undefined): boolean {
  const normalized = message?.trim().toLowerCase() ?? "";
  return normalized.includes("agent is already processing");
}
