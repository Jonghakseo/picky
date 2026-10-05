import { describe, expect, it } from "vitest";
import { permissionOutcome, pushAvailability, pushBlockedKey, type PushEnvironment } from "./push-policy";

const installedIphone: PushEnvironment = {
  ios: true,
  standalone: true,
  secureContext: true,
  serviceWorker: true,
  pushManager: true,
  notificationPermission: "default",
  vapidKey: true,
};

describe("pushAvailability", () => {
  it("is available in the Home Screen app over https", () => {
    expect(pushAvailability(installedIphone)).toEqual({ available: true, permission: "default" });
  });

  it("asks iOS users to install first, before anything else", () => {
    expect(pushAvailability({ ...installedIphone, standalone: false, secureContext: false })).toEqual({
      available: false,
      reason: "iosNeedsHomeScreen",
    });
  });

  it("reports plain http as the blocker on other platforms", () => {
    expect(pushAvailability({ ...installedIphone, ios: false, standalone: false, secureContext: false })).toEqual({
      available: false,
      reason: "insecure",
    });
  });

  it("reports a denied permission", () => {
    expect(pushAvailability({ ...installedIphone, notificationPermission: "denied" })).toEqual({ available: false, reason: "denied" });
  });

  it("reports a browser without push support", () => {
    expect(pushAvailability({ ...installedIphone, pushManager: false })).toEqual({ available: false, reason: "unsupported" });
  });

  it("reports a gateway that has no push keys yet", () => {
    expect(pushAvailability({ ...installedIphone, vapidKey: false })).toEqual({ available: false, reason: "serverDisabled" });
  });

  it("sends an iPhone to the device settings and a browser to its site settings after a denial", () => {
    expect(pushBlockedKey("denied", true)).toBe("remote.settings.notifications.unavailable.denied");
    expect(pushBlockedKey("denied", false)).toBe("remote.settings.notifications.unavailable.deniedBrowser");
  });

  it("does not treat a dismissed prompt as a denial", () => {
    expect(permissionOutcome("granted")).toBe("granted");
    expect(permissionOutcome("denied")).toBe("denied");
    expect(permissionOutcome("default")).toBe("dismissed");
  });

  it("names a copy key for every blocked reason", () => {
    for (const reason of ["iosNeedsHomeScreen", "insecure", "denied", "serverDisabled", "unsupported"] as const) {
      expect(pushBlockedKey(reason)).toMatch(/^remote\.settings\.notifications\.unavailable\./);
    }
  });
});
