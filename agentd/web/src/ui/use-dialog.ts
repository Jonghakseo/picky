/**
 * Keyboard and screen-reader behaviour shared by every sheet, menu and panel:
 * focus moves into it when it opens, Tab stays inside, Esc closes it, and
 * focus goes back to the control that opened it. Without this a keyboard user
 * could tab "behind" an open sheet and had no way to close it but the pointer.
 */
import { useEffect, useRef } from "preact/hooks";

const FOCUSABLE = [
  "a[href]",
  "button:not([disabled])",
  "input:not([disabled]):not([type=hidden])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "[tabindex]:not([tabindex='-1'])",
].join(",");

export function focusableIn(root: ParentNode): HTMLElement[] {
  // tabIndex -1 (an unselected tab, a list row reached by arrows) is not a Tab stop.
  return [...root.querySelectorAll<HTMLElement>(FOCUSABLE)].filter(
    (element) => element.tabIndex >= 0 && !element.closest("[aria-hidden='true'], [inert]"),
  );
}

export interface DialogOptions {
  /** Called on Esc. */
  onDismiss: () => void;
  /** Where focus starts; the first focusable element when omitted. */
  initialFocus?: string;
}

/** Attach the returned ref to the dialog container (the element with role="dialog"). */
export function useDialog<T extends HTMLElement>({ onDismiss, initialFocus }: DialogOptions) {
  const ref = useRef<T | null>(null);
  const dismiss = useRef(onDismiss);
  dismiss.current = onDismiss;

  useEffect(() => {
    const root = ref.current;
    if (!root) return;
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const start = (initialFocus ? root.querySelector<HTMLElement>(initialFocus) : null) ?? focusableIn(root)[0] ?? root;
    if (start === root && !root.hasAttribute("tabindex")) root.setAttribute("tabindex", "-1");
    start.focus({ preventScroll: true });

    const onKey = (event: KeyboardEvent): void => {
      // Keys count while focus is inside, and also when the focused control
      // just unmounted (a page change inside the dialog) and focus fell to body.
      const active = document.activeElement;
      if (active && active !== document.body && !root.contains(active)) return;
      if (event.key === "Escape" && !event.isComposing) {
        event.preventDefault();
        event.stopPropagation();
        dismiss.current();
        return;
      }
      if (event.key !== "Tab") return;
      const items = focusableIn(root);
      if (items.length === 0) {
        event.preventDefault();
        return;
      }
      const first = items[0]!;
      const last = items[items.length - 1]!;
      if (event.shiftKey && (active === first || !root.contains(active))) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && (active === last || !root.contains(active))) {
        event.preventDefault();
        first.focus();
      }
    };
    document.addEventListener("keydown", onKey, true);
    return () => {
      document.removeEventListener("keydown", onKey, true);
      // Back to whatever opened it, if that is still on the page.
      if (opener?.isConnected) opener.focus({ preventScroll: true });
    };
    // The dialog's identity is its mount; option changes do not re-run focus.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return ref;
}

/**
 * Arrow keys, Home and End move between the tabs of a `role="tablist"` and
 * select the one they land on, as the WAI-ARIA tabs pattern describes. Only
 * the selected tab is in the Tab order (`tabIndex` set by the caller).
 */
export function onTablistKeyDown(event: KeyboardEvent): void {
  const list = event.currentTarget as HTMLElement;
  const tabs = [...list.querySelectorAll<HTMLElement>("[role='tab']:not([disabled])")];
  const at = tabs.indexOf(document.activeElement as HTMLElement);
  if (at < 0 || tabs.length < 2) return;
  let next: number;
  switch (event.key) {
    case "ArrowRight":
    case "ArrowDown":
      next = (at + 1) % tabs.length;
      break;
    case "ArrowLeft":
    case "ArrowUp":
      next = (at - 1 + tabs.length) % tabs.length;
      break;
    case "Home":
      next = 0;
      break;
    case "End":
      next = tabs.length - 1;
      break;
    default:
      return;
  }
  event.preventDefault();
  tabs[next]!.focus();
  tabs[next]!.click();
}
