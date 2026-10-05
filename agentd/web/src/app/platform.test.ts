import { describe, expect, it } from "vitest";
import { readPlatform, suggestDeviceName } from "./platform";

const iphoneAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1";
const iPadDesktopAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15";

describe("readPlatform", () => {
  it("recognizes an iPhone in Safari", () => {
    const facts = readPlatform({ userAgent: iphoneAgent, maxTouchPoints: 5, standaloneDisplay: false, secureContext: true });
    expect(facts).toMatchObject({ ios: true, standalone: false, deviceName: "iPhone" });
  });

  it("recognizes the Home Screen app from either signal", () => {
    const base = { userAgent: iphoneAgent, maxTouchPoints: 5, secureContext: true };
    expect(readPlatform({ ...base, standaloneDisplay: true }).standalone).toBe(true);
    expect(readPlatform({ ...base, standaloneDisplay: false, navigatorStandalone: true }).standalone).toBe(true);
  });

  it("recognizes an iPad that reports a Mac user agent", () => {
    expect(readPlatform({ userAgent: iPadDesktopAgent, maxTouchPoints: 5, standaloneDisplay: false, secureContext: true })).toMatchObject({
      ios: true,
      deviceName: "iPad",
    });
  });

  it("does not take a real Mac for an iPad", () => {
    expect(readPlatform({ userAgent: iPadDesktopAgent, maxTouchPoints: 0, standaloneDisplay: false, secureContext: true }).ios).toBe(false);
  });
});

describe("suggestDeviceName", () => {
  it("names the device, then the browser", () => {
    expect(suggestDeviceName(iphoneAgent)).toBe("iPhone");
    expect(suggestDeviceName("Mozilla/5.0 (Linux; Android 15) Chrome/131.0")).toBe("Android");
    expect(suggestDeviceName("Mozilla/5.0 (Windows NT 10.0) Chrome/131.0 Safari/537.36")).toBe("Chrome");
    expect(suggestDeviceName("Mozilla/5.0 (X11; Linux) Firefox/133.0")).toBe("Firefox");
    expect(suggestDeviceName("something else")).toBe("Browser");
  });
});
