import { describe, expect, it } from "vitest";
import { PAIRING_ALPHABET, PAIRING_MAX_ATTEMPTS, PAIRING_TTL_MS, PairingSession, formatPairingCode, generatePairingCode } from "./pairing.js";

describe("pairing codes", () => {
  it("uses 8 characters from the unambiguous alphabet, shown as XXXX-XXXX", () => {
    for (let attempt = 0; attempt < 50; attempt += 1) {
      const code = generatePairingCode();
      expect(code).toHaveLength(8);
      expect([...code].every((character) => PAIRING_ALPHABET.includes(character))).toBe(true);
    }
    expect(formatPairingCode("ABCD2345")).toBe("ABCD-2345");
  });

  it("accepts the code with dashes, spaces and lower case", () => {
    const session = new PairingSession(() => 0, () => "ABCD2345");
    session.start();
    expect(session.check("abcd-2345")).toEqual({ ok: true });
  });

  it("is single use: the same code does not pair a second device", () => {
    const session = new PairingSession(() => 0, () => "ABCD2345");
    session.start();
    expect(session.check("ABCD2345").ok).toBe(true);
    expect(session.check("ABCD2345")).toEqual({ ok: false, reason: "noCode" });
  });

  it("expires after five minutes", () => {
    let now = 0;
    const session = new PairingSession(() => now, () => "ABCD2345");
    session.start();
    now = PAIRING_TTL_MS - 1;
    expect(session.check("WRONGXYZ")).toEqual({ ok: false, reason: "wrong" });
    now = PAIRING_TTL_MS;
    expect(session.check("ABCD2345")).toEqual({ ok: false, reason: "expired" });
    expect(session.isActive()).toBe(false);
  });

  it("ends the code after five wrong guesses", () => {
    const session = new PairingSession(() => 0, () => "ABCD2345");
    session.start();
    for (let attempt = 1; attempt < PAIRING_MAX_ATTEMPTS; attempt += 1) {
      expect(session.check("ZZZZ9999")).toEqual({ ok: false, reason: "wrong" });
    }
    expect(session.check("ZZZZ9999")).toEqual({ ok: false, reason: "exhausted" });
    // Even the correct code is dead once the attempts ran out.
    expect(session.check("ABCD2345")).toEqual({ ok: false, reason: "noCode" });
  });

  it("keeps one active code: starting again replaces the previous one", () => {
    const codes = ["AAAA1111", "BBBB2222"];
    const session = new PairingSession(() => 0, () => codes.shift() ?? "CCCC3333");
    session.start();
    session.start();
    expect(session.check("AAAA1111")).toEqual({ ok: false, reason: "wrong" });
    expect(session.check("BBBB2222").ok).toBe(true);
  });

  it("refuses to pair while the Mac has not opened the sheet", () => {
    const session = new PairingSession(() => 0, () => "ABCD2345");
    expect(session.check("ABCD2345")).toEqual({ ok: false, reason: "noCode" });
  });
});
