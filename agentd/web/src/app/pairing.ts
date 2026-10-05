/**
 * Pairing code handling. The gateway issues 8 characters from
 * `23456789ABCDEFGHJKMNPQRSTVWXYZ` and shows them as `XXXX-XXXX`
 * (docs/remote-pwa-implementation.md 2.3). Input is case- and dash-insensitive,
 * so the phone normalizes before sending.
 */
export const PAIRING_CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ";
export const PAIRING_CODE_LENGTH = 8;

/** Uppercase, drop separators, keep only characters the gateway can have issued. */
export function normalizePairingCode(input: string): string {
  const upper = input.toUpperCase();
  let code = "";
  for (const character of upper) {
    if (PAIRING_CODE_ALPHABET.includes(character)) code += character;
    if (code.length === PAIRING_CODE_LENGTH) break;
  }
  return code;
}

/** `XXXX-XXXX` while typing; the dash appears only once the fifth character exists. */
export function formatPairingCode(code: string): string {
  const normalized = normalizePairingCode(code);
  if (normalized.length <= 4) return normalized;
  return `${normalized.slice(0, 4)}-${normalized.slice(4)}`;
}

export function isCompletePairingCode(code: string): boolean {
  return normalizePairingCode(code).length === PAIRING_CODE_LENGTH;
}

/**
 * Reads a scanned QR payload. The Mac encodes `<publicUrl>/#pair=<code>`, but a
 * code typed into another device's screen or a bare code must work too.
 */
export function parsePairingPayload(payload: string): string | undefined {
  const text = payload.trim();
  if (text.length === 0) return undefined;
  const fragment = text.includes("#") ? text.slice(text.indexOf("#") + 1) : undefined;
  if (fragment !== undefined) {
    const match = /(?:^|&)pair=([^&]*)/.exec(fragment);
    if (match?.[1]) {
      const code = normalizePairingCode(safeDecode(match[1]));
      return code.length === PAIRING_CODE_LENGTH ? code : undefined;
    }
    return undefined;
  }
  // A bare code: accept it only when the whole payload is one, so a random URL
  // does not turn into a code by dropping its letters.
  if (!/^[A-Za-z0-9-]+$/.test(text)) return undefined;
  const code = normalizePairingCode(text);
  return code.length === PAIRING_CODE_LENGTH && text.replace(/-/g, "").length === PAIRING_CODE_LENGTH ? code : undefined;
}

function safeDecode(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}
