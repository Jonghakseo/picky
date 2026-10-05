/**
 * History API navigation. One signal holds the current location so screens
 * re-render on `popstate` (the phone's back swipe) exactly as they do on a tap.
 */
import { signal } from "@preact/signals";
import { parseLocation, routeHref, sameRoute, type ParsedLocation, type Route } from "./router";

function readLocation(): ParsedLocation {
  return parseLocation(globalThis.location?.pathname ?? "/", globalThis.location?.search ?? "", globalThis.location?.hash ?? "");
}

export const currentLocation = signal<ParsedLocation>(readLocation());

export function startNavigation(): () => void {
  const onPop = () => {
    currentLocation.value = readLocation();
  };
  globalThis.addEventListener("popstate", onPop);
  return () => globalThis.removeEventListener("popstate", onPop);
}

export function navigate(route: Route, options: { replace?: boolean } = {}): void {
  const held = currentLocation.value;
  if (!options.replace && sameRoute(held.route, route)) return;
  const href = routeHref(route);
  // Query parameters the app does not own (`demo`, `theme`) survive navigation
  // so a demo session stays a demo session.
  const keep = preservedQuery();
  const url = keep ? `${href}${href.includes("?") ? "&" : "?"}${keep}` : href;
  if (options.replace) history.replaceState(null, "", url);
  else history.pushState(null, "", url);
  currentLocation.value = { route };
}

export function goBack(fallback: Route = { name: "rooms" }): void {
  if (history.length > 1) {
    history.back();
    return;
  }
  navigate(fallback, { replace: true });
}

const PRESERVED_PARAMS = ["demo", "theme", "scale"];

function preservedQuery(): string {
  const source = new URLSearchParams(globalThis.location?.search ?? "");
  const kept = new URLSearchParams();
  for (const name of PRESERVED_PARAMS) {
    const value = source.get(name);
    if (value !== null) kept.set(name, value);
  }
  const text = kept.toString();
  return text;
}
