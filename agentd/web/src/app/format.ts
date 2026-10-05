/**
 * Room list times and file sizes. The HUD shows a clock time for today and a
 * date beyond that; the phone adds "yesterday" because a messenger list is read
 * at a glance.
 */
import type { Locale } from "./i18n";

export type RoomTimeStyle =
  | { kind: "time"; date: Date }
  | { kind: "yesterday" }
  | { kind: "weekday"; date: Date }
  | { kind: "date"; date: Date };

const DAY_MS = 24 * 60 * 60 * 1000;

function startOfDay(date: Date): number {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

/** Pure part: picks the shape. Rendering needs `Intl`, which depends on the locale. */
export function roomTimeStyle(value: Date, now: Date): RoomTimeStyle {
  const days = Math.round((startOfDay(now) - startOfDay(value)) / DAY_MS);
  if (days <= 0) return { kind: "time", date: value };
  if (days === 1) return { kind: "yesterday" };
  if (days < 7) return { kind: "weekday", date: value };
  return { kind: "date", date: value };
}

export function formatRoomTime(
  iso: string | undefined,
  now: Date,
  locale: Locale,
  yesterdayLabel: string,
): string {
  if (!iso) return "";
  const value = new Date(iso);
  if (Number.isNaN(value.getTime())) return "";
  const tag = locale === "ko" ? "ko-KR" : "en-US";
  const style = roomTimeStyle(value, now);
  switch (style.kind) {
    case "time":
      return new Intl.DateTimeFormat(tag, { hour: "2-digit", minute: "2-digit", hour12: locale !== "ko" }).format(style.date);
    case "yesterday":
      return yesterdayLabel;
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
