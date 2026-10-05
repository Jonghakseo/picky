/**
 * Routes: `/` room list, `/room/<id>` conversation, `/settings`, `/pair`, and
 * `/preview?room=<id>&path=<path>` for the read-only file preview.
 * `#pair=<code>` on any route opens pairing with the code filled, which is what
 * the Mac QR encodes (`<publicUrl>/#pair=<code>`).
 */
import { MAIN_ROOM_ID } from "../../../src/remote/constants";

export type Route =
  | { name: "rooms" }
  | { name: "room"; roomId: string }
  | { name: "settings" }
  | { name: "pair" }
  | { name: "preview"; roomId: string; path: string };

export interface ParsedLocation {
  route: Route;
  /** Pairing code carried in the fragment, if any. Normalization happens in `pairing.ts`. */
  pairCode?: string;
}

export function parseLocation(pathname: string, search = "", hash = ""): ParsedLocation {
  const params = new URLSearchParams(search.startsWith("?") ? search.slice(1) : search);
  const fragment = hash.startsWith("#") ? hash.slice(1) : hash;
  const pairMatch = /(?:^|&)pair=([^&]*)/.exec(fragment);
  const pairCode = pairMatch?.[1] ? decodeURIComponent(pairMatch[1]) : undefined;
  return { route: parseRoute(pathname, params), ...(pairCode ? { pairCode } : {}) };
}

function parseRoute(pathname: string, params: URLSearchParams): Route {
  const segments = pathname.split("/").filter((segment) => segment.length > 0).map(decodeSegment);
  const [first, second] = segments;
  if (first === "room" && second) return { name: "room", roomId: second };
  if (first === "settings") return { name: "settings" };
  if (first === "pair") return { name: "pair" };
  if (first === "preview") {
    const path = params.get("path") ?? "";
    const roomId = params.get("room") ?? MAIN_ROOM_ID;
    if (path) return { name: "preview", roomId, path };
  }
  return { name: "rooms" };
}

function decodeSegment(segment: string): string {
  try {
    return decodeURIComponent(segment);
  } catch {
    return segment;
  }
}

export function routeHref(route: Route): string {
  switch (route.name) {
    case "rooms":
      return "/";
    case "room":
      return `/room/${encodeURIComponent(route.roomId)}`;
    case "settings":
      return "/settings";
    case "pair":
      return "/pair";
    case "preview":
      return `/preview?room=${encodeURIComponent(route.roomId)}&path=${encodeURIComponent(route.path)}`;
  }
}

/** True when the two routes address the same screen (used to avoid duplicate history entries). */
export function sameRoute(a: Route, b: Route): boolean {
  return routeHref(a) === routeHref(b);
}
