/**
 * Response helpers: the headers every gateway response carries, plus the CSP
 * for the app shell (docs/remote-pwa-implementation.md 2.3).
 */
import type { OutgoingHttpHeaders, ServerResponse } from "node:http";
import type { RemoteError, RemoteErrorCode } from "../../remote/protocol.js";

export const BASE_SECURITY_HEADERS: Readonly<Record<string, string>> = Object.freeze({
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Cross-Origin-Opener-Policy": "same-origin",
  "Permissions-Policy": "camera=(self), microphone=(self), geolocation=()",
});

/** `connect-src` has to name the host explicitly: `'self'` does not cover wss. */
export function appShellCsp(host: string): string {
  const safeHost = host.replace(/[^A-Za-z0-9.:_-]/g, "");
  const socket = safeHost ? ` wss://${safeHost} ws://${safeHost}` : "";
  return [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self' blob: data:",
    "media-src 'self' blob:",
    `connect-src 'self'${socket}`,
    "worker-src 'self'",
    "manifest-src 'self'",
    "frame-src 'self'",
    "frame-ancestors 'self'",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'self'",
  ].join("; ");
}

/** Preview documents are rendered in a sandboxed iframe and get their own policy. */
export const PREVIEW_DOCUMENT_CSP = "sandbox; default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:";

/**
 * PDFs render in the browser's own viewer, which a CSP `sandbox` directive
 * disables (Chrome refuses to show a PDF in a sandboxed frame), and
 * `object-src 'none'` has blocked viewers too. This keeps to directives that do
 * not touch the viewer: no scripts or navigation hooks from the document, and
 * only this origin may frame it. Not verified on iOS Safari.
 */
export const PREVIEW_PDF_CSP = "script-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'";

const ERROR_STATUS: Record<RemoteErrorCode, number> = {
  invalid: 400,
  unauthorized: 401,
  notFound: 404,
  macOffline: 503,
  rejected: 409,
  timeout: 504,
  rateLimited: 429,
  unsupported: 415,
  tooLarge: 413,
  internal: 500,
};

export function statusForErrorCode(code: RemoteErrorCode): number {
  return ERROR_STATUS[code];
}

export function writeHead(response: ServerResponse, status: number, headers: OutgoingHttpHeaders = {}): void {
  response.writeHead(status, { ...BASE_SECURITY_HEADERS, ...headers });
}

export function sendJson(response: ServerResponse, status: number, body: unknown, headers: OutgoingHttpHeaders = {}): void {
  const payload = Buffer.from(JSON.stringify(body), "utf8");
  writeHead(response, status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": payload.byteLength,
    "Cache-Control": "no-store",
    ...headers,
  });
  response.end(payload);
}

export function sendError(response: ServerResponse, error: RemoteError, headers: OutgoingHttpHeaders = {}): void {
  sendJson(response, statusForErrorCode(error.code), { error }, headers);
}

export function sendBytes(
  response: ServerResponse,
  status: number,
  body: Buffer,
  contentType: string,
  headers: OutgoingHttpHeaders = {},
): void {
  writeHead(response, status, {
    "Content-Type": contentType,
    "Content-Length": body.byteLength,
    "Cache-Control": "no-store",
    ...headers,
  });
  response.end(body);
}

/**
 * Shown when `PICKY_GATEWAY_WEB_ROOT` has no build. Plain text with no markup
 * so it needs no CSP exception, and 503 so a phone's service worker keeps the
 * cached shell instead of overwriting it with this page.
 */
export function sendMissingWebBundle(response: ServerResponse): void {
  const body = Buffer.from(
    "Picky remote is running, but the web bundle is not built.\n\nRun: pnpm --dir agentd run build:web\n",
    "utf8",
  );
  writeHead(response, 503, {
    "Content-Type": "text/plain; charset=utf-8",
    "Content-Length": body.byteLength,
    "Cache-Control": "no-store",
  });
  response.end(body);
}

export function remoteError(code: RemoteErrorCode, message: string): RemoteError {
  return { code, message };
}
