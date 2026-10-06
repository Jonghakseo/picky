/**
 * Room list times and file sizes. The list says how long ago a room last moved
 * (just now, N minutes, N hours) for the first day, then falls back to
 * yesterday, a weekday, or a date.
 */
import type { Locale } from "./i18n";

export type RoomTimeStyle =
  | { kind: "justNow" }
  | { kind: "minutes"; count: number }
  | { kind: "hours"; count: number }
  | { kind: "yesterday" }
  | { kind: "weekday"; date: Date }
  | { kind: "date"; date: Date };

const MINUTE_MS = 60 * 1000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;

function startOfDay(date: Date): number {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

/** Pure part: picks the shape. Rendering needs `Intl`, which depends on the locale. */
export function roomTimeStyle(value: Date, now: Date): RoomTimeStyle {
  // A clock a little ahead of the Mac's still reads as "just now", not "in 1 minute".
  const elapsed = Math.max(0, now.getTime() - value.getTime());
  if (elapsed < MINUTE_MS) return { kind: "justNow" };
  if (elapsed < HOUR_MS) return { kind: "minutes", count: Math.floor(elapsed / MINUTE_MS) };
  if (elapsed < DAY_MS) return { kind: "hours", count: Math.floor(elapsed / HOUR_MS) };
  const days = Math.round((startOfDay(now) - startOfDay(value)) / DAY_MS);
  if (days <= 1) return { kind: "yesterday" };
  if (days < 7) return { kind: "weekday", date: value };
  return { kind: "date", date: value };
}

export interface RoomTimeLabels {
  justNow: string;
  minutes: (count: number) => string;
  hours: (count: number) => string;
  yesterday: string;
}

export function formatRoomTime(
  iso: string | undefined,
  now: Date,
  locale: Locale,
  labels: RoomTimeLabels,
): string {
  if (!iso) return "";
  const value = new Date(iso);
  if (Number.isNaN(value.getTime())) return "";
  const tag = locale === "ko" ? "ko-KR" : "en-US";
  const style = roomTimeStyle(value, now);
  switch (style.kind) {
    case "justNow":
      return labels.justNow;
    case "minutes":
      return labels.minutes(style.count);
    case "hours":
      return labels.hours(style.count);
    case "yesterday":
      return labels.yesterday;
    case "weekday":
      return new Intl.DateTimeFormat(tag, { weekday: "short" }).format(style.date);
    case "date":
      return new Intl.DateTimeFormat(tag, { month: "numeric", day: "numeric" }).format(style.date);
  }
}

/** Sizes stay short: a preview header has one line for the whole path. */
export function formatBytes(bytes: number, locale: Locale): string {
  const tag = locale === "ko" ? "ko-KR" : "en-US";
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB"];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const digits = value < 10 ? 1 : 0;
  return `${new Intl.NumberFormat(tag, { maximumFractionDigits: digits, minimumFractionDigits: 0 }).format(value)} ${units[unit]}`;
}

/** Last path component, with a trailing slash removed first. */
export function fileName(path: string): string {
  const trimmed = path.replace(/\/+$/, "");
  const index = trimmed.lastIndexOf("/");
  return index >= 0 ? trimmed.slice(index + 1) : trimmed;
}
