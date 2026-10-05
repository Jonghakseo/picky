import { describe, expect, it } from "vitest";
import { formatPairingCode, isCompletePairingCode, normalizePairingCode, parsePairingPayload } from "./pairing";

describe("normalizePairingCode", () => {
  it("accepts the code as it is shown on the Mac", () => {
    expect(normalizePairingCode("K4M9-TR2X")).toBe("K4M9TR2X");
  });

  it("accepts lowercase typing and stray spaces", () => {
    expect(normalizePairingCode(" k4m9 tr2x ")).toBe("K4M9TR2X");
  });

  it("drops characters the gateway never issues", () => {
    expect(normalizePairingCode("K4M9-TR2X01ILOU")).toBe("K4M9TR2X");
  });

  it("stops at eight characters", () => {
    expect(normalizePairingCode("K4M9TR2XK4M9TR2X")).toBe("K4M9TR2X");
  });
});

describe("formatPairingCode", () => {
  it("adds the dash only once the second half starts", () => {
    expect(formatPairingCode("K4M9")).toBe("K4M9");
    expect(formatPairingCode("K4M9T")).toBe("K4M9-T");
    expect(formatPairingCode("K4M9TR2X")).toBe("K4M9-TR2X");
  });
});

describe("isCompletePairingCode", () => {
  it("is true only for eight valid characters", () => {
    expect(isCompletePairingCode("K4M9-TR2X")).toBe(true);
    expect(isCompletePairingCode("K4M9-TR2")).toBe(false);
  });
});

describe("parsePairingPayload", () => {
  it("reads the URL the Mac encodes in its QR", () => {
    expect(parsePairingPayload("https://mac.tail1234.ts.net/#pair=K4M9-TR2X")).toBe("K4M9TR2X");
  });

  it("reads a percent-encoded fragment", () => {
    expect(parsePairingPayload("https://mac.example.com/#pair=K4M9%2DTR2X")).toBe("K4M9TR2X");
  });

  it("reads a bare code", () => {
    expect(parsePairingPayload("K4M9-TR2X")).toBe("K4M9TR2X");
    expect(parsePairingPayload("k4m9tr2x")).toBe("K4M9TR2X");
  });

  it("ignores a QR that is not a pairing code", () => {
    expect(parsePairingPayload("https://example.com/promo")).toBeUndefined();
    expect(parsePairingPayload("WIFI:S:home;T:WPA;P:secret;;")).toBeUndefined();
    expect(parsePairingPayload("https://mac.example.com/#other=1")).toBeUndefined();
    expect(parsePairingPayload("")).toBeUndefined();
  });

  it("does not turn a long word into a code by dropping letters", () => {
    expect(parsePairingPayload("UNSUBSCRIBE-NOW-PLEASE")).toBeUndefined();
  });
});
