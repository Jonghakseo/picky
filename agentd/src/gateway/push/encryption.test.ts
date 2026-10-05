/**
 * RFC 8291 Appendix A. The push service is an untrusted relay, so the only
 * thing that proves this code works is that it reproduces the specification's
 * ciphertext byte for byte: a phone decrypts with the browser's own
 * implementation, never with ours.
 */
import { createECDH } from "node:crypto";
import { describe, expect, it } from "vitest";
import { deriveKeys, encryptPushPayload } from "./encryption.js";

// A.1/A.2 of RFC 8291.
const VECTOR = {
  plaintext: "When I grow up, I want to be a watermelon",
  userAgentPublicKey: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
  userAgentPrivateKey: "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94",
  authSecret: "BTBZMqHH6r4Tts7J_aSIgg",
  serverPublicKey: "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
  serverPrivateKey: "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw",
  salt: "DGv6ra1nlYgDCS1FRnbzlw",
  ikm: "S4lYMb_L0FxCeq0WhDx813KgSYqU26kOyzWUdsXYyrg",
  contentEncryptionKey: "oIhVW04MRdy2XN9CiKLxTg",
  nonce: "4h_95klXJ5E_qnoN",
  body:
    "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8w"
    + "EqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
} as const;

function bytes(base64url: string): Buffer {
  return Buffer.from(base64url, "base64url");
}

function encryptVector() {
  return encryptPushPayload({
    payload: VECTOR.plaintext,
    userAgentPublicKey: bytes(VECTOR.userAgentPublicKey),
    authSecret: bytes(VECTOR.authSecret),
    salt: bytes(VECTOR.salt),
    serverPrivateKey: bytes(VECTOR.serverPrivateKey),
  });
}

describe("aes128gcm push encryption matches RFC 8291", () => {
  it("produces the specification's ciphertext", () => {
    expect(encryptVector().body.toString("base64url")).toBe(VECTOR.body);
  });

  it("derives the specification's IKM, content encryption key and nonce", () => {
    const { keys, serverPublicKey } = encryptVector();
    expect(serverPublicKey.toString("base64url")).toBe(VECTOR.serverPublicKey);
    expect(keys.ikm.toString("base64url")).toBe(VECTOR.ikm);
    expect(keys.contentEncryptionKey.toString("base64url")).toBe(VECTOR.contentEncryptionKey);
    expect(keys.nonce.toString("base64url")).toBe(VECTOR.nonce);
  });

  it("agrees with the key derivation done from the phone's side", () => {
    // The user agent starts from its own private key and the server's public
    // key; both sides must land on the same content encryption key or the
    // browser silently drops the notification.
    const userAgent = createECDH("prime256v1");
    userAgent.setPrivateKey(bytes(VECTOR.userAgentPrivateKey));
    const fromPhone = deriveKeys({
      ecdhSecret: userAgent.computeSecret(bytes(VECTOR.serverPublicKey)),
      authSecret: bytes(VECTOR.authSecret),
      userAgentPublicKey: bytes(VECTOR.userAgentPublicKey),
      serverPublicKey: bytes(VECTOR.serverPublicKey),
      salt: bytes(VECTOR.salt),
    });
    expect(fromPhone.contentEncryptionKey.toString("base64url")).toBe(VECTOR.contentEncryptionKey);
    expect(fromPhone.nonce.toString("base64url")).toBe(VECTOR.nonce);
  });

  it("writes the aes128gcm header: salt, record size, key length, server key", () => {
    const { body } = encryptVector();
    expect(body.subarray(0, 16).toString("base64url")).toBe(VECTOR.salt);
    expect(body.readUInt32BE(16)).toBe(4096);
    expect(body[20]).toBe(65);
    expect(body.subarray(21, 86).toString("base64url")).toBe(VECTOR.serverPublicKey);
  });

  it("picks a fresh salt and server key for every message", () => {
    const first = encryptPushPayload({
      payload: "hello",
      userAgentPublicKey: bytes(VECTOR.userAgentPublicKey),
      authSecret: bytes(VECTOR.authSecret),
    });
    const second = encryptPushPayload({
      payload: "hello",
      userAgentPublicKey: bytes(VECTOR.userAgentPublicKey),
      authSecret: bytes(VECTOR.authSecret),
    });
    expect(first.salt.equals(second.salt)).toBe(false);
    expect(first.serverPublicKey.equals(second.serverPublicKey)).toBe(false);
    expect(first.body.equals(second.body)).toBe(false);
  });

  it("refuses a payload that does not fit in one record", () => {
    expect(() => encryptPushPayload({
      payload: "x".repeat(4096),
      userAgentPublicKey: bytes(VECTOR.userAgentPublicKey),
      authSecret: bytes(VECTOR.authSecret),
    })).toThrow(/one record/);
  });
});
