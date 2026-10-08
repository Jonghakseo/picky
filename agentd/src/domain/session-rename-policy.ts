import type { PickyAgentSession } from "../protocol.js";

/**
 * Picky owns the Pickle display name. Pi's auto-name only fills in a title that
 * nobody chose, so an explicit rename records `titleOrigin: "user"` next to the
 * title and later `session_info` events leave it alone. Pi's own session file is
 * never rewritten, which is why the two names can legitimately differ.
 */

export const PICKLE_NAME_RULE_MESSAGE =
  "Name must contain 1 to 200 Unicode characters without line breaks or control characters.";

const MAX_TITLE_CODEPOINTS = 200;

/** Trims the request and rejects empty, oversized, or control-character names. */
export function normalizePickleRenameTitle(rawTitle: string): string {
  const title = rawTitle.trim();
  // Count codepoints, not UTF-16 units, so emoji and CJK names are measured the
  // way a person reads them. Control characters are checked on the raw input so
  // a trailing newline cannot be laundered by the trim.
  if (!title || [...title].length > MAX_TITLE_CODEPOINTS || /[\p{Cc}\p{Zl}\p{Zp}]/u.test(rawTitle)) {
    throw new Error(PICKLE_NAME_RULE_MESSAGE);
  }
  return title;
}

/** True once a person named this session; Pi auto-names must not overwrite it. */
export function isUserAssignedTitle(session: Pick<PickyAgentSession, "titleOrigin">): boolean {
  return session.titleOrigin === "user";
}

/** The two fields an explicit rename always writes together. */
export function userRenameTitlePatch(title: string): { title: string; titleOrigin: "user" } {
  return { title, titleOrigin: "user" };
}

/** No-op detection for a rename: same text AND already user-owned. */
export function isRenameNoOp(session: Pick<PickyAgentSession, "title" | "titleOrigin">, title: string): boolean {
  return isUserAssignedTitle(session) && session.title === title;
}
