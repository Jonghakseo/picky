/**
 * Copy for the PWA. Keys come from `Picky/Resources/Localizable.xcstrings`
 * (the Mac catalog, so HUD wording stays identical) plus the phone-only
 * `remote.*` keys in `web/i18n/remote-strings.json`. `web/build.mjs` inlines
 * the subset the source references as `__STRINGS__`.
 *
 * Format specifiers follow the catalog: `%@` and `%lld` consume the next
 * argument, `%1$@` picks one by position, `%%` is a literal percent.
 */
export type Locale = "ko" | "en";

declare const __STRINGS__: Record<Locale, Record<string, string>>;

export type StringTables = Record<Locale, Record<string, string>>;

const emptyTables: StringTables = { ko: {}, en: {} };

function bundledTables(): StringTables {
  return typeof __STRINGS__ === "undefined" ? emptyTables : __STRINGS__;
}

/** ko for Korean browsers, en for everything else (the catalog has no other locale). */
export function resolveLocale(language: string | undefined | null): Locale {
  return (language ?? "").toLowerCase().startsWith("ko") ? "ko" : "en";
}

export type FormatArg = string | number;

const SPECIFIER = /%%|%(\d+)\$(?:@|lld|ld|d|s)|%(?:@|lld|ld|d|s)/g;

export function formatString(template: string, args: readonly FormatArg[]): string {
  let next = 0;
  return template.replace(SPECIFIER, (match, position?: string) => {
    if (match === "%%") return "%";
    const index = position ? Number(position) - 1 : next++;
    const value = args[index];
    // A specifier with no argument stays as written: a visible gap beats a silent "undefined".
    return value === undefined ? match : String(value);
  });
}

export interface Translator {
  (key: string, ...args: FormatArg[]): string;
  locale: Locale;
}

/** Falls back to English, then to the key itself, so a missing string is visible but never blank. */
export function createTranslator(tables: StringTables, locale: Locale): Translator {
  const translate = ((key: string, ...args: FormatArg[]) => {
    const template = tables[locale]?.[key] ?? tables.en?.[key] ?? key;
    return args.length > 0 ? formatString(template, args) : template;
  }) as Translator;
  translate.locale = locale;
  return translate;
}

let active: Translator | undefined;

export function setLocale(locale: Locale): void {
  active = createTranslator(bundledTables(), locale);
}

export function currentLocale(): Locale {
  return (active ??= createTranslator(bundledTables(), resolveLocale(globalThis.navigator?.language))).locale;
}

/** The app-wide translator. `setLocale` is called once at startup. */
export function t(key: string, ...args: FormatArg[]): string {
  return (active ??= createTranslator(bundledTables(), resolveLocale(globalThis.navigator?.language)))(key, ...args);
}
