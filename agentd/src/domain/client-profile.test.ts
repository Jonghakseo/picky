import { describe, expect, it } from "vitest";
import { EventEnvelopeVariantSchema } from "../protocol.js";
import { canDeliverEventToProfile, DEFAULT_CLIENT_PROFILE, DESKTOP_ONLY_EVENT_TYPES, resolveClientProfile } from "./client-profile.js";

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
  it("withholds every classified event from core clients and delivers it to desktop", () => {
    expect(DESKTOP_ONLY_EVENT_TYPES.size).toBeGreaterThan(0);
    for (const type of DESKTOP_ONLY_EVENT_TYPES) {
      expect(canDeliverEventToProfile(type, "core"), type).toBe(false);
      expect(canDeliverEventToProfile(type, "desktop"), type).toBe(true);
    }
  });

  // The classification is only worth anything if it names events that exist.
  // `tsc` pins this too, but a widened type would silently lose that check.
  it("classifies only event types the protocol can actually emit", () => {
    const protocolEventTypes = new Set<string>(EventEnvelopeVariantSchema.options.map((option) => option.shape.type.value));
    for (const type of DESKTOP_ONLY_EVENT_TYPES) {
      expect(protocolEventTypes.has(type), `${type} is not a protocol event type`).toBe(true);
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
