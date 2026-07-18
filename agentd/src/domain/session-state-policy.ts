import type { PickyAgentSession } from "../protocol.js";

export function sameTodoState(
  left: PickyAgentSession["todoState"],
  right: PickyAgentSession["todoState"],
): boolean {
  if (left === right) return true;
  if (!left || !right) return false;
  return left.updatedAt === right.updatedAt && JSON.stringify(left.tasks) === JSON.stringify(right.tasks);
}

export function shouldReattachBlockedSessionOnStartup(
  session: PickyAgentSession,
  hasPiSessionFile: boolean,
): boolean {
  return session.status === "blocked" && session.archived !== true && hasPiSessionFile;
}

export function countSystemMessages(session: PickyAgentSession, text: string): number {
  return (session.messages ?? []).filter((message) => message.kind === "system" && message.text === text).length;
}
