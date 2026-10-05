/**
 * Notification copy (ko/en), chosen from the device locale in `hello`.
 *
 * Reviewed against `.agents/skills/picky-ux-writing/SKILL.md`: 해요체, no
 * exclamation marks, and the body says what happened rather than instructing
 * the user. The title is the room title so a glance at the lock screen already
 * says which Pickle it was.
 */
import type { RemotePushPayload } from "../../remote/protocol.js";

export type PushKind = RemotePushPayload["kind"];
export type PushLocale = "ko" | "en";

const COPY: Record<PushLocale, Record<PushKind, string>> = {
  ko: {
    question: "답을 기다리고 있어요",
    completed: "작업을 마쳤어요",
    failed: "작업이 멈췄어요",
    reply: "답장이 도착했어요",
  },
  en: {
    question: "Waiting for your answer",
    completed: "Finished the task",
    failed: "Stopped before finishing",
    reply: "Replied to you",
  },
};

export function pushLocaleOf(locale: string | undefined): PushLocale {
  return locale?.toLowerCase().startsWith("ko") ? "ko" : "en";
}

export function pushBody(kind: PushKind, locale: PushLocale): string {
  return COPY[locale][kind];
}

export function buildPushPayload(options: {
  roomId: string;
  roomTitle: string;
  kind: PushKind;
  locale: PushLocale;
  badge: number;
}): RemotePushPayload {
  return {
    title: options.roomTitle,
    body: pushBody(options.kind, options.locale),
    roomId: options.roomId,
    kind: options.kind,
    badge: options.badge,
  };
}
