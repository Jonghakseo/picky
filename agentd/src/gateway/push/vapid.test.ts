/**
 * VAPID (RFC 8292). A push service rejects the request outright when the JWT is
 * malformed, the audience is wrong or the expiry is more than 24 h out, so the
 * token is checked the way a push service checks it: verify the ES256
 * signature with the advertised public key.
 */
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createPublicKey, createVerify } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  decodeJwtClaims,
  generateVapidKeys,
  loadOrCreateVapidKeys,
  rawPublicKey,
  signVapidToken,
  vapidAuthorizationHeader,
  vapidClaims,
  VAPID_TOKEN_TTL_SECONDS,
} from "./vapid.js";

const ENDPOINT = "https://web.push.apple.com/abcdef/token?x=1";
const SUBJECT = "https://mac.tail1234.ts.net";

let root: string;
const keys = generateVapidKeys();

beforeAll(async () => {
  root = await mkdtemp(join(tmpdir(), "picky-vapid-"));
});

afterAll(async () => {
  await rm(root, { recursive: true, force: true });
});

function decodeHeader(token: string): Record<string, unknown> {
  return JSON.parse(Buffer.from(token.split(".")[0], "base64url").toString("utf8")) as Record<string, unknown>;
}

describe("VAPID keys", () => {
  it("advertises an uncompressed P-256 point", () => {
    const raw = Buffer.from(keys.publicKey, "base64url");
    expect(raw.byteLength).toBe(65);
    expect(raw[0]).toBe(0x04);
    expect(rawPublicKey(keys.privateJwk).toString("base64url")).toBe(keys.publicKey);
  });

  it("keeps the same key pair forever, because regenerating it kills every subscription", async () => {
    const first = await loadOrCreateVapidKeys(root);
    const second = await loadOrCreateVapidKeys(root);
    expect(second.publicKey).toBe(first.publicKey);
    expect(second.privateJwk.d).toBe(first.privateJwk.d);
  });
});

describe("VAPID token", () => {
  const nowSeconds = 1_800_000_000;
  const claims = vapidClaims(ENDPOINT, SUBJECT, nowSeconds);
  const token = signVapidToken(claims, keys.privateJwk);

  it("addresses the push service origin and the Mac's public URL", () => {
    expect(claims.aud).toBe("https://web.push.apple.com");
    expect(claims.sub).toBe(SUBJECT);
  });

  it("expires inside the 24 h ceiling RFC 8292 sets", () => {
    expect(claims.exp - nowSeconds).toBe(VAPID_TOKEN_TTL_SECONDS);
    expect(claims.exp - nowSeconds).toBeLessThanOrEqual(24 * 60 * 60);
    expect(claims.exp).toBeGreaterThan(nowSeconds);
  });

  it("declares ES256 and carries the claims back", () => {
    expect(decodeHeader(token)).toEqual({ typ: "JWT", alg: "ES256" });
    expect(decodeJwtClaims(token)).toEqual(claims);
    expect(token.split(".")).toHaveLength(3);
  });

  it("signs with the raw r||s pair the advertised public key verifies", () => {
    const [header, body, signature] = token.split(".");
    const publicKey = createPublicKey({
      key: { kty: "EC", crv: "P-256", x: keys.privateJwk.x, y: keys.privateJwk.y },
      format: "jwk",
    });
    const verified = createVerify("SHA256")
      .update(`${header}.${body}`)
      .verify({ key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url"));
    expect(Buffer.from(signature, "base64url").byteLength).toBe(64);
    expect(verified).toBe(true);
  });

  it("does not verify against a different key pair", () => {
    const [header, body, signature] = token.split(".");
    const other = generateVapidKeys();
    const verified = createVerify("SHA256")
      .update(`${header}.${body}`)
      .verify(
        { key: createPublicKey({ key: { kty: "EC", crv: "P-256", x: other.privateJwk.x, y: other.privateJwk.y }, format: "jwk" }), dsaEncoding: "ieee-p1363" },
        Buffer.from(signature, "base64url"),
      );
    expect(verified).toBe(false);
  });

  it("builds the Authorization header with the token and the key", () => {
    expect(vapidAuthorizationHeader(token, keys.publicKey)).toBe(`vapid t=${token}, k=${keys.publicKey}`);
  });
});
