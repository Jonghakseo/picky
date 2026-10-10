/**
 * What the audit log keeps of a `!` shell message sent from a phone.
 *
 * A phone that runs shell commands on the Mac has to leave a trace, but the full
 * line often carries a token or password typed inline. The log keeps the
 * command's length and a masked opening, which says what kind of command it
 * was without becoming a second place secrets live.
 */

export const SHELL_AUDIT_PREVIEW_CHARS = 80;
const MASK = "***";

/** Applied in order; each keeps the key or flag so the log still shows what was passed. */
const SECRET_PATTERNS: ReadonlyArray<readonly [RegExp, string]> = [
  [/\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+/gi, `$1 ${MASK}`],
  [/((?:^|[\s;&|'"])[A-Za-z0-9_.-]*(?:token|secret|passw(?:or)?d|passwd|pwd|api[_-]?key|apikey|auth|credential)[A-Za-z0-9_.-]*\s*[=:]\s*)(?:"[^"]*"?|'[^']*'?|[^\s;&|]+)/gi, `$1${MASK}`],
  [/(--?[A-Za-z0-9-]*(?:token|secret|passw(?:or)?d|api[_-]?key|auth|credential)[A-Za-z0-9-]*[\s=]+)(?:"[^"]*"?|'[^']*'?|[^\s;&|]+)/gi, `$1${MASK}`],
  [/(-u\s+[^\s:]+:)[^\s]+/g, `$1${MASK}`],
  [/(\b[a-z][a-z0-9+.-]*:\/\/[^\s:/@]+:)[^\s@/]+(@)/gi, `$1${MASK}$2`],
  [/\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}/g, MASK],
  [/\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{16,}/g, MASK],
  [/\bxox[abprs]-[A-Za-z0-9-]{10,}/g, MASK],
  [/\bAKIA[0-9A-Z]{16}\b/g, MASK],
  [/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*/g, MASK],
];

export function maskShellSecrets(command: string): string {
  return SECRET_PATTERNS.reduce((text, [pattern, replacement]) => text.replace(pattern, replacement), command);
}

export interface ShellAuditSummary {
  /** Length of the original command, so a long pasted script is visible as one. */
  shellCommandChars: number;
  /** Masked opening of the command; ends with an ellipsis when cut. */
  shellCommand: string;
}

/** Masks first and cuts second, so a secret straddling the cut cannot survive as a fragment. */
export function summarizeShellCommand(command: string): ShellAuditSummary {
  const masked = maskShellSecrets(command.trim());
  const preview = masked.length > SHELL_AUDIT_PREVIEW_CHARS
    ? `${masked.slice(0, SHELL_AUDIT_PREVIEW_CHARS)}…`
    : masked;
  return { shellCommandChars: command.length, shellCommand: preview };
}
