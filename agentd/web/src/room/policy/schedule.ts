/**
 * "보낼 시점" menu behind the split send button.
 * Port of `PickySendTimingPolicy` and the title/detail wording in
 * `PickyScheduledMessagesPresentation` (Picky/HUD/Conversation/).
 *
 * The phone differs in one way: the Mac shows a ⌥↵ hint on the follow-up row,
 * which a phone has no key for, so the shortcut column is dropped.
 */
import { REMOTE_LIMITS } from "../../../../src/remote/constants";
import { t } from "../i18n";

export type SendTiming =
  | { kind: "afterCurrentReply" }
  | { kind: "delay"; seconds: number }
  | { kind: "at"; at: number }
  | { kind: "custom" };

export interface SendTimingOption {
  id: string;
  timing: SendTiming;
  title: string;
  /** Absolute send time for timed rows; `undefined` for the follow-up row. */
  detail?: string;
  enabled: boolean;
  /** Why a visible row is disabled, when the row itself does not say so. */
  disabledReason?: string;
}

/** Relative presets; "tomorrow at 9:00" and the custom row follow them. */
export const PRESET_DELAY_SECONDS = [5 * 60, 60 * 60];
export const TOMORROW_PRESET_HOUR = 9;

/**
 * Delay for `session.schedule`, measured when the row is picked so a menu left
 * open does not shift an absolute time. `null` for rows that do not schedule.
 * An absolute time that has just passed still sends, after one second.
 */
export function delayMilliseconds(timing: SendTiming, now: number): number | null {
  switch (timing.kind) {
    case "afterCurrentReply":
    case "custom":
      return null;
    case "delay":
      return timing.seconds * 1000;
    case "at":
      return Math.max(1000, Math.round(timing.at - now));
  }
}

/** Tomorrow at 9:00 local time, even shortly after midnight. */
export function tomorrowPreset(now: number): number {
  const date = new Date(now);
  date.setHours(0, 0, 0, 0);
  date.setDate(date.getDate() + 1);
  date.setHours(TOMORROW_PRESET_HOUR, 0, 0, 0);
  return date.getTime();
}

/** The gateway rejects anything past the limit, so the UI must not offer it. */
export function isWithinScheduleLimit(delayMs: number): boolean {
  return delayMs > 0 && delayMs <= REMOTE_LIMITS.scheduleMaxDelayMs;
}

export function relativeTitle(now: number, dueAt: number): string {
  const seconds = (dueAt - now) / 1000;
  if (seconds < 60) return t("hud.scheduled.relative.soon");
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return t("hud.scheduled.relative.minutes", minutes);
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return t("hud.scheduled.relative.hours", hours);
  return t("hud.scheduled.relative.days", Math.floor(hours / 24));
}

export function isSameDay(a: number, b: number): boolean {
  const left = new Date(a);
  const right = new Date(b);
  return (
    left.getFullYear() === right.getFullYear() &&
    left.getMonth() === right.getMonth() &&
    left.getDate() === right.getDate()
  );
}

export function timeText(at: number, locale: string): string {
  return new Date(at).toLocaleTimeString(locale, { hour: "numeric", minute: "2-digit" });
}

/** Time only on the same day, month/day/weekday plus time otherwise. */
export function absoluteDetail(dueAt: number, now: number, locale: string): string {
  const time = timeText(dueAt, locale);
  if (isSameDay(dueAt, now)) return time;
  const day = new Date(dueAt).toLocaleDateString(locale, { month: "short", day: "numeric", weekday: "short" });
  return `${day} ${time}`;
}

/**
 * `canSendAfterCurrentReply` is false for a cancelled or failed Pickle. Timed
 * rows carry text only, so attachments disable them with a reason, the same
 * rule the Mac applies to armed screen context.
 */
export function sendTimingOptions(input: {
  now: number;
  locale: string;
  canSendAfterCurrentReply: boolean;
  hasAttachments: boolean;
}): SendTimingOption[] {
  const { now, locale, canSendAfterCurrentReply, hasAttachments } = input;
  const timedEnabled = !hasAttachments;
  const timedDisabledReason = hasAttachments ? t("hud.composer.sendTiming.textOnly") : undefined;
  const options: SendTimingOption[] = [
    {
      id: "after-current-reply",
      timing: { kind: "afterCurrentReply" },
      title: t("hud.scheduled.group.afterCurrentReply"),
      enabled: canSendAfterCurrentReply,
    },
  ];
  for (const seconds of PRESET_DELAY_SECONDS) {
    const dueAt = now + seconds * 1000;
    options.push({
      id: `delay-${seconds}`,
      timing: { kind: "delay", seconds },
      title: relativeTitle(now, dueAt),
      detail: absoluteDetail(dueAt, now, locale),
      enabled: timedEnabled,
      disabledReason: timedDisabledReason,
    });
  }
  const tomorrow = tomorrowPreset(now);
  options.push({
    id: `at-${tomorrow}`,
    timing: { kind: "at", at: tomorrow },
    title: t("hud.composer.sendTiming.tomorrowAt", timeText(tomorrow, locale)),
    detail: new Date(tomorrow).toLocaleDateString(locale, { month: "long", day: "numeric", weekday: "short" }),
    enabled: timedEnabled,
    disabledReason: timedDisabledReason,
  });
  options.push({
    id: "custom",
    timing: { kind: "custom" },
    title: t("hud.composer.sendTiming.custom"),
    enabled: timedEnabled,
    disabledReason: timedDisabledReason,
  });
  return options;
}
