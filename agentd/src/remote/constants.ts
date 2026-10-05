/**
 * Runtime constants of the remote wire contract, kept free of zod so the PWA
 * can import them without bundling the daemon protocol schemas. Browser code
 * imports values from here and only types (`import type`) from `protocol.ts`.
 */
export const REMOTE_PROTOCOL_VERSION = 1;

/** Room id of the main agent conversation ("Picky" room). Session ids never equal it. */
export const MAIN_ROOM_ID = "main";

/** Limits shared by the gateway (enforcement) and the PWA (early feedback). */
export const REMOTE_LIMITS = {
  textChars: 100_000,
  uploadsPerMessage: 10,
  uploadBytes: 20 * 1024 * 1024,
  dictationBytes: 15 * 1024 * 1024,
  dictationSeconds: 300,
  scheduleMaxDelayMs: 7 * 24 * 60 * 60 * 1000,
  clientMessageBytes: 1024 * 1024,
  previewTextBytes: 1024 * 1024,
} as const;
