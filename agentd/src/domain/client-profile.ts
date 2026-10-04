/**
 * Client profiles describe what a connected socket can actually render, so the
 * daemon stops shipping macOS-only work to clients that have no screen.
 *
 * - `core`: platform-neutral session control. The `picky` CLI and any future
 *   headless client live here. Every core event is also delivered to desktop.
 * - `desktop`: a macOS Picky.app process that owns overlay windows, the cursor
 *   narration/TTS surface, and the embedded terminal.
 *
 * Only `broadcast` is gated. Unicast replies to a requesting socket stay
 * ungated so a CLI never loses the answer to its own command.
 */
import type { EventEnvelope } from "../protocol.js";

/** Every event type the daemon can put on the wire. */
type PickyEventType = EventEnvelope["type"];

export const PICKY_CLIENT_PROFILES = ["core", "desktop"] as const;
export type PickyClientProfile = (typeof PICKY_CLIENT_PROFILES)[number];

/**
 * Capabilities that only a desktop app process can serve: each one makes the
 * daemon call back into the app for a window, a hotkey, or app-owned settings.
 * Used to infer the profile of a client that predates the `profile` field.
 */
export const DESKTOP_BRIDGE_CAPABILITIES: readonly string[] = [
  "pickleHandoff",
  "pickleBridge",
  "externalEntry",
  "pushToTalkControl",
  "settingsControl",
];

/**
 * Broadcast events a core client cannot do anything with. Keep this list as the
 * single classification point: a new event defaults to `core` (delivered to
 * everyone, which is the pre-gate behavior) until it is listed here.
 *
 * The `satisfies` clause ties every entry to the protocol's event union, so a
 * renamed or deleted event fails `tsc` here instead of silently un-gating
 * itself at runtime. The import is type-only, so this stays a pure domain
 * module with no dependency on the wire schema at runtime.
 *
 * Deliberately absent:
 * - `quickReply`: the CLI waits for it (`cli.ts` `matchMainReplyForContext`),
 *   so gating it would hang `picky submit --wait`.
 * - `sessionReplyWritingUpdated` / `sessionToolCallPreparingUpdated` /
 *   `sessionAutoRetryUpdated`: neutral per-session status that any client could render.
 */
export const DESKTOP_ONLY_EVENT_TYPES: ReadonlySet<string> = new Set<string>([
  // Overlay windows drawn by the app over the user's screen.
  "pointerOverlayRequested",
  "annotationOverlayRequested",
  // Spoken + cursor-rendered narration of the main agent's reply.
  "mainNarrationChunk",
  "mainVisualNarrationSegmentPrepared",
  "mainVisualNarrationSegmentSentence",
  "mainVisualNarrationSegmentCommitted",
  // Result of syncing the app's embedded SwiftTerm terminal with a Pi session.
  "terminalSessionSyncOutcome",
] satisfies readonly PickyEventType[]);

/**
 * Resolves the profile of a socket that just registered.
 *
 * A declared profile always wins. The capability fallback exists only for app
 * builds that predate the `profile` field; delete it once every shipped Picky
 * sends `profile` explicitly (the daemon refuses older protocol versions at
 * connect time, so that is a release-gated cleanup, not an open-ended one).
 */
export function resolveClientProfile(registration: {
  declaredProfile?: PickyClientProfile;
  capabilities?: readonly string[];
}): PickyClientProfile {
  if (registration.declaredProfile) return registration.declaredProfile;
  const capabilities = registration.capabilities ?? [];
  return capabilities.some((capability) => DESKTOP_BRIDGE_CAPABILITIES.includes(capability)) ? "desktop" : "core";
}

/** A socket that never registered is a core client (the CLI never registers). */
export const DEFAULT_CLIENT_PROFILE: PickyClientProfile = "core";

/** Whether a broadcast event may reach a client with this profile. */
export function canDeliverEventToProfile(eventType: string, profile: PickyClientProfile): boolean {
  return profile === "desktop" || !DESKTOP_ONLY_EVENT_TYPES.has(eventType);
}
