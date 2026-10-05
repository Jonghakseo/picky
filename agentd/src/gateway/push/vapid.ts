/**
 * VAPID keys and tokens, RFC 8292 (docs/remote-pwa-implementation.md 2.8).
 *
 * The key pair is created on first start and kept in `<dataDir>/vapid.json`;
 * regenerating it would silently invalidate every subscription a phone already
 * made, so it is written once and read back forever.
 */
import { createPrivateKey, createSign, generateKeyPairSync, type JsonWebKey } from "node:crypto";
import { dataPath, ensureDirectory, readJsonFile, writeJsonFileAtomic } from "../storage.js";

/** Twelve hours: comfortably inside the 24 h ceiling RFC 8292 sets. */
export const VAPID_TOKEN_TTL_SECONDS = 12 * 60 * 60;

export interface VapidKeyPair {
  publicKey: string;
  privateJwk: JsonWebKey;
}

export function generateVapidKeys(): VapidKeyPair {
  const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const publicJwk = publicKey.export({ format: "jwk" }) as JsonWebKey;
  return {
    publicKey: rawPublicKey(publicJwk).toString("base64url"),
    privateJwk: privateKey.export({ format: "jwk" }) as JsonWebKey,
  };
}

export function rawPublicKey(jwk: JsonWebKey): Buffer {
  return Buffer.concat([
    Buffer.from([0x04]),
    Buffer.from(jwk.x ?? "", "base64url"),
    Buffer.from(jwk.y ?? "", "base64url"),
  ]);
}

export async function loadOrCreateVapidKeys(dataDir: string): Promise<VapidKeyPair> {
  await ensureDirectory(dataDir);
  const path = dataPath(dataDir, "vapid.json");
  const existing = await readJsonFile<VapidKeyPair>(path);
  if (existing?.publicKey && existing.privateJwk) return existing;
  const created = generateVapidKeys();
  await writeJsonFileAtomic(path, created);
  return created;
}

export interface VapidClaims {
  aud: string;
  exp: number;
  sub: string;
}

export function vapidClaims(endpoint: string, subject: string, nowSeconds = Math.floor(Date.now() / 1000)): VapidClaims {
  return { aud: new URL(endpoint).origin, exp: nowSeconds + VAPID_TOKEN_TTL_SECONDS, sub: subject };
}

export function signVapidToken(claims: VapidClaims, privateJwk: JsonWebKey): string {
  const header = base64url({ typ: "JWT", alg: "ES256" });
  const body = base64url(claims);
  const signingInput = `${header}.${body}`;
  const key = createPrivateKey({ key: privateJwk as Record<string, unknown>, format: "jwk" });
  // JWS needs the raw r||s pair, not the DER sequence `createSign` defaults to.
  const signature = createSign("SHA256").update(signingInput).sign({ key, dsaEncoding: "ieee-p1363" });
  return `${signingInput}.${signature.toString("base64url")}`;
}

/** `Authorization` value for an `aes128gcm` push request. */
export function vapidAuthorizationHeader(token: string, publicKey: string): string {
  return `vapid t=${token}, k=${publicKey}`;
}

export function decodeJwtClaims(token: string): VapidClaims {
  return JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8")) as VapidClaims;
}

function base64url(value: unknown): string {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}
