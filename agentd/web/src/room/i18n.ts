/**
 * Single import point for room copy.
 *
 * The room UI reads the same table as the rest of the PWA: catalog keys come
 * from `Picky/Resources/Localizable.xcstrings` so the wording matches the HUD,
 * and phone-only `remote.room.*` keys live in `web/i18n/room-strings.json`.
 * `web/build.mjs` inlines the subset the source references.
 */
export { t, setLocale, currentLocale, formatString, resolveLocale } from "../app/i18n";
export type { Locale, Locale as RoomLocale } from "../app/i18n";

import { currentLocale } from "../app/i18n";

/** Locale as a value, for `toLocaleDateString` and friends. */
export function locale(): "ko" | "en" {
  return currentLocale();
}
