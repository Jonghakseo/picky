import { describe, expect, it } from "vitest";
import { canDeliverEventToProfile, DEFAULT_CLIENT_PROFILE, resolveClientProfile } from "./client-profile.js";

/** The capability set Picky.app registers today (PickyAgentClientRouter.registerAppCapabilities). */
const PICKY_APP_CAPABILITIES = ["pickleHandoff", "pickleBridge", "externalEntry", "pushToTalkControl", "settingsControl", "sessionProjectionV2"];

describe("client profile resolution", () => {
  it("treats a client that never registered as core", () => {
    expect(DEFAULT_CLIENT_PROFILE).toBe("core");
  });

  it("infers desktop from the capability set Picky.app registers today", () => {
    expect(resolveClientProfile({ capabilities: PICKY_APP_CAPABILITIES })).toBe("desktop");
  });

  it("infers desktop from a single app bridge capability", () => {
    expect(resolveClientProfile({ capabilities: ["settingsControl"] })).toBe("desktop");
  });

  it("keeps a projection-only subscriber on core because it bridges nothing for the app", () => {
    expect(resolveClientProfile({ capabilities: ["sessionProjectionV2"] })).toBe("core");
  });

  it("lets a declared profile override the capability inference in both directions", () => {
    expect(resolveClientProfile({ declaredProfile: "core", capabilities: PICKY_APP_CAPABILITIES })).toBe("core");
    expect(resolveClientProfile({ declaredProfile: "desktop", capabilities: [] })).toBe("desktop");
  });
});

describe("desktop-only event gating", () => {
  const desktopOnly = [
    "pointerOverlayRequested",
    "annotationOverlayRequested",
    "mainNarrationChunk",
    "mainVisualNarrationSegmentPrepared",
    "mainVisualNarrationSegmentSentence",
    "mainVisualNarrationSegmentCommitted",
    "terminalSessionSyncOutcome",
  ];

  it("withholds events that need a macOS surface from core clients", () => {
    for (const type of desktopOnly) {
      expect(canDeliverEventToProfile(type, "core")).toBe(false);
      expect(canDeliverEventToProfile(type, "desktop")).toBe(true);
    }
  });

  it("keeps quickReply on core because the CLI waits for it", () => {
    expect(canDeliverEventToProfile("quickReply", "core")).toBe(true);
  });

  it("keeps neutral session status events on core", () => {
    expect(canDeliverEventToProfile("sessionReplyWritingUpdated", "core")).toBe(true);
    expect(canDeliverEventToProfile("sessionToolCallPreparingUpdated", "core")).toBe(true);
    expect(canDeliverEventToProfile("pickleSessionUpdated", "core")).toBe(true);
  });

  it("delivers an unclassified event to every profile so a new event keeps today's behavior", () => {
    expect(canDeliverEventToProfile("someFutureEventNobodyClassifiedYet", "core")).toBe(true);
  });
});
