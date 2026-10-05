/**
 * Static serving of the built PWA with an SPA fallback
 * (docs/remote-pwa-implementation.md 2.2).
 *
 * `/room/<id>`, `/pair` and `/settings` are client routes, so any unknown
 * non-API path returns `index.html`. Hashed assets are immutable; the shell,
 * the service worker and the manifest must revalidate or an update would never
 * reach a phone that already installed the app.
 */
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize, resolve, sep } from "node:path";
import type { ServerResponse } from "node:http";
import { appShellCsp, sendBytes, sendMissingWebBundle, writeHead } from "./responses.js";

const CONTENT_TYPES: Readonly<Record<string, string>> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
  ".txt": "text/plain; charset=utf-8",
  ".map": "application/json; charset=utf-8",
};

export function contentTypeFor(path: string): string {
  return CONTENT_TYPES[extname(path).toLowerCase()] ?? "application/octet-stream";
}

/** Hashed asset names change on every build, so they can be cached forever. */
export function cacheControlFor(relativePath: string): string {
  if (relativePath.startsWith("assets/") && /-[0-9a-f]{8,}\./.test(relativePath)) {
    return "public, max-age=31536000, immutable";
  }
  return "no-cache";
}

/** Keeps `..` and absolute paths inside the web root. */
export function resolveWithinRoot(root: string, requestPath: string): string | undefined {
  const decoded = safeDecode(requestPath);
  if (decoded === undefined || decoded.includes("\0")) return undefined;
  const relative = normalize(decoded).replace(/^(\.\.(\/|\\|$))+/, "").replace(/^[/\\]+/, "");
  const resolved = resolve(join(root, relative));
  const rootWithSeparator = resolve(root) + sep;
  return resolved === resolve(root) || resolved.startsWith(rootWithSeparator) ? resolved : undefined;
}

function safeDecode(value: string): string | undefined {
  try {
    return decodeURIComponent(value);
  } catch {
    return undefined;
  }
}

export class StaticSite {
  constructor(private readonly webRoot: string) {}

  async serve(response: ServerResponse, requestPath: string, host: string, method: string): Promise<void> {
    const indexPath = join(this.webRoot, "index.html");
    const hasBundle = await stat(indexPath).then((info) => info.isFile()).catch(() => false);
    if (!hasBundle) {
      sendMissingWebBundle(response);
      return;
    }

    const direct = requestPath === "/" ? undefined : resolveWithinRoot(this.webRoot, requestPath);
    const fileStat = direct ? await stat(direct).catch(() => undefined) : undefined;
    const filePath = fileStat?.isFile() ? direct! : indexPath;
    const relative = filePath === indexPath ? "index.html" : filePath.slice(resolve(this.webRoot).length + 1);
    const isShell = relative === "index.html";

    const headers: Record<string, string> = {
      "Cache-Control": cacheControlFor(relative),
      ...(isShell ? { "Content-Security-Policy": appShellCsp(host) } : {}),
      // The service worker must be allowed to control the whole origin.
      ...(relative === "sw.js" ? { "Service-Worker-Allowed": "/" } : {}),
    };

    const body = await readFile(filePath);
    if (method === "HEAD") {
      writeHead(response, 200, { "Content-Type": contentTypeFor(filePath), "Content-Length": body.byteLength, ...headers });
      response.end();
      return;
    }
    sendBytes(response, 200, body, contentTypeFor(filePath), headers);
  }
}
