/**
 * Window-width layout. Below 768px the PWA is the phone app: the room list and
 * a room take turns filling the screen. From 768px a browser window (or an iPad)
 * shows the list next to the open room, like a desktop messenger.
 */
import { useEffect, useState } from "preact/hooks";

export const WIDE_LAYOUT_QUERY = "(min-width: 768px)";

export function useWideLayout(): boolean {
  const [wide, setWide] = useState(() => globalThis.matchMedia?.(WIDE_LAYOUT_QUERY).matches ?? false);
  useEffect(() => {
    const list = globalThis.matchMedia?.(WIDE_LAYOUT_QUERY);
    if (!list) return;
    const update = (): void => setWide(list.matches);
    update();
    list.addEventListener("change", update);
    return () => list.removeEventListener("change", update);
  }, []);
  return wide;
}

/**
 * The room ⌥↑ / ⌥↓ moves to: the neighbour of the open room in the list as it
 * is drawn (filter, pinned order, an expanded archive). With no room open it
 * starts from the top or the bottom.
 */
export function neighbourRoom(order: readonly string[], current: string | undefined, step: 1 | -1): string | undefined {
  if (order.length === 0) return undefined;
  const at = current === undefined ? -1 : order.indexOf(current);
  if (at < 0) return step === 1 ? order[0] : order[order.length - 1];
  const next = at + step;
  return next < 0 || next >= order.length ? undefined : order[next];
}
