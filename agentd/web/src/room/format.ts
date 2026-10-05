/**
 * Date and time wording for the transcript. The HUD uses the system locale and
 * calendar; on the phone that is the browser locale the shell passes down.
 */
import { t } from "./i18n";

export function parseTimestamp(value: string | undefined): number | null {
  if (!value) return null;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? null : parsed;
}

export function startOfDay(at: number): number {
  const date = new Date(at);
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}

/** Send time beside a bubble, for example "오전 9:41". */
export function timeOfDay(at: number, locale: string): string {
  return new Date(at).toLocaleTimeString(locale, { hour: "numeric", minute: "2-digit" });
}

/** Divider title: 오늘, 어제, else the date with its weekday. */
export function dateDividerTitle(at: number, now: number, locale: string): string {
  const day = startOfDay(at);
  const today = startOfDay(now);
  if (day === today) return t("hud.conversation.dateDivider.today");
  const oneDay = 24 * 60 * 60 * 1000;
  if (day === today - oneDay) return t("hud.conversation.dateDivider.yesterday");
  const sameYear = new Date(at).getFullYear() === new Date(now).getFullYear();
  return new Date(at).toLocaleDateString(locale, {
    year: sameYear ? undefined : "numeric",
    month: "long",
    day: "numeric",
    weekday: "short",
  });
}

/** True when two timestamps fall on different calendar days. */
export function crossesDay(previous: number | null, current: number): boolean {
  if (previous === null) return true;
  return startOfDay(previous) !== startOfDay(current);
}

export function fileName(path: string): string {
  const parts = path.split("/").filter((part) => part.length > 0);
  return parts[parts.length - 1] ?? path;
}
