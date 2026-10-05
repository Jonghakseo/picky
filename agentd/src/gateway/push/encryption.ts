/**
 * Web Push payload encryption, RFC 8291 (`aes128gcm`), with Node `crypto` only.
 *
 * Picky adds no dependency for this: the push service is an untrusted relay, so
 * the one thing that matters is that the ciphertext is right, and that is
 * pinned by the RFC 8291 Appendix A test vector in `encryption.test.ts`.
 */
import { createCipheriv, createECDH, createHmac, randomBytes } from "node:crypto";

export const DEFAULT_RECORD_SIZE = 4096;
const PUBLIC_KEY_BYTES = 65;

export interface PushEncryptionKeys {
  ecdhSecret: Buffer;
  prkKey: Buffer;
  ikm: Buffer;
  prk: Buffer;
  contentEncryptionKey: Buffer;
  nonce: Buffer;
}

export interface PushEncryptionInput {
  payload: Buffer | string;
  /** Subscription `keys.p256dh`, raw uncompressed point. */
  userAgentPublicKey: Buffer;
  /** Subscription `keys.auth`. */
  authSecret: Buffer;
  /** Test hook: the RFC vector fixes the salt and the server key pair. */
  salt?: Buffer;
  serverPrivateKey?: Buffer;
  recordSize?: number;
}

function hmacSha256(key: Buffer, data: Buffer): Buffer {
  return createHmac("sha256", key).update(data).digest();
}

/** `HKDF-Expand` with one output block, the only shape RFC 8291 uses. */
function expand(prk: Buffer, info: Buffer, length: number): Buffer {
  return hmacSha256(prk, Buffer.concat([info, Buffer.from([0x01])])).subarray(0, length);
}

export function deriveKeys(options: {
  ecdhSecret: Buffer;
  authSecret: Buffer;
  userAgentPublicKey: Buffer;
  serverPublicKey: Buffer;
  salt: Buffer;
}): PushEncryptionKeys {
  const prkKey = hmacSha256(options.authSecret, options.ecdhSecret);
  const keyInfo = Buffer.concat([
    Buffer.from("WebPush: info\0", "utf8"),
    options.userAgentPublicKey,
    options.serverPublicKey,
  ]);
  const ikm = expand(prkKey, keyInfo, 32);
  const prk = hmacSha256(options.salt, ikm);
  return {
    ecdhSecret: options.ecdhSecret,
    prkKey,
    ikm,
    prk,
    contentEncryptionKey: expand(prk, Buffer.from("Content-Encoding: aes128gcm\0", "utf8"), 16),
    nonce: expand(prk, Buffer.from("Content-Encoding: nonce\0", "utf8"), 12),
  };
}

export interface PushEncryptionResult {
  body: Buffer;
  keys: PushEncryptionKeys;
  serverPublicKey: Buffer;
  salt: Buffer;
}

export function encryptPushPayload(input: PushEncryptionInput): PushEncryptionResult {
  const recordSize = input.recordSize ?? DEFAULT_RECORD_SIZE;
  const salt = input.salt ?? randomBytes(16);
  const ecdh = createECDH("prime256v1");
  if (input.serverPrivateKey) ecdh.setPrivateKey(input.serverPrivateKey);
  else ecdh.generateKeys();

  const serverPublicKey = ecdh.getPublicKey();
  const ecdhSecret = ecdh.computeSecret(input.userAgentPublicKey);
  const keys = deriveKeys({
    ecdhSecret,
    authSecret: input.authSecret,
    userAgentPublicKey: input.userAgentPublicKey,
    serverPublicKey,
    salt,
  });

  const plaintext = typeof input.payload === "string" ? Buffer.from(input.payload, "utf8") : input.payload;
  // One record: the padding delimiter closes the last (only) record.
  const padded = Buffer.concat([plaintext, Buffer.from([0x02])]);
  if (padded.byteLength + 16 > recordSize) {
    throw new Error("Push payload does not fit in one record");
  }

  const cipher = createCipheriv("aes-128-gcm", keys.contentEncryptionKey, keys.nonce);
  const ciphertext = Buffer.concat([cipher.update(padded), cipher.final(), cipher.getAuthTag()]);

  const recordSizeField = Buffer.alloc(4);
  recordSizeField.writeUInt32BE(recordSize, 0);
  const header = Buffer.concat([salt, recordSizeField, Buffer.from([PUBLIC_KEY_BYTES]), serverPublicKey]);

  return { body: Buffer.concat([header, ciphertext]), keys, serverPublicKey, salt };
}
