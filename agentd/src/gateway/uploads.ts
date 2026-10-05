/**
 * Composer attachments uploaded from the phone (`POST /api/uploads`).
 *
 * Each upload gets its own directory named by an opaque id, so the original
 * file name survives into the message the agent reads without ever reaching
 * path resolution: the id is the only thing a client sends back, and it is
 * matched against the id pattern before it touches the filesystem.
 */
import { readdir, readFile, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import type { RemoteUploadResponse } from "../remote/protocol.js";
import { dataPath, ensureDirectory, randomId, writeFileAtomic } from "./storage.js";
import { sniffImageMime } from "./file-service.js";

export const UPLOAD_ID_PATTERN = /^[A-Za-z0-9_-]{8,64}$/;
export const UPLOAD_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;

export function sanitizeUploadName(name: string | undefined, mime: string): string {
  const fallback = `image.${mime.split("/")[1]?.replace(/[^a-z0-9]/gi, "") || "bin"}`;
  const base = (name ?? "").split(/[\\/]/).pop()?.trim() ?? "";
  const safe = base.replace(/[^A-Za-z0-9._\- ]/g, "_").replace(/^\.+/, "").slice(0, 80);
  return safe || fallback;
}

export class UploadStore {
  private readonly root: string;

  constructor(dataDir: string) {
    this.root = dataPath(dataDir, "uploads");
  }

  async save(bytes: Buffer, name: string | undefined, declaredMime: string): Promise<RemoteUploadResponse> {
    const mime = sniffImageMime(bytes);
    if (!mime) throw new UploadRejected("Only images can be attached from the phone.");
    if (!declaredMime.startsWith("image/")) throw new UploadRejected("Only images can be attached from the phone.");

    const uploadId = randomId(12);
    const fileName = sanitizeUploadName(name, mime);
    const directory = join(this.root, uploadId);
    await ensureDirectory(directory);
    await writeFileAtomic(join(directory, fileName), bytes);
    return { uploadId, name: fileName, size: bytes.byteLength, mime };
  }

  /** Absolute path of a stored upload, or undefined when the id is unknown. */
  async pathFor(uploadId: string): Promise<string | undefined> {
    if (!UPLOAD_ID_PATTERN.test(uploadId)) return undefined;
    const directory = join(this.root, uploadId);
    const entries = await readdir(directory).catch(() => undefined);
    const fileName = entries?.find((entry) => !entry.startsWith("."));
    return fileName ? join(directory, fileName) : undefined;
  }

  async read(uploadId: string): Promise<{ path: string; bytes: Buffer } | undefined> {
    const path = await this.pathFor(uploadId);
    if (!path) return undefined;
    const bytes = await readFile(path).catch(() => undefined);
    return bytes ? { path, bytes } : undefined;
  }

  /** Resolves every id or throws, so a message never loses an attachment silently. */
  async resolveAll(uploadIds: readonly string[]): Promise<string[]> {
    const paths: string[] = [];
    for (const uploadId of uploadIds) {
      const path = await this.pathFor(uploadId);
      if (!path) throw new UploadRejected(`Attachment ${uploadId} is no longer available.`);
      paths.push(path);
    }
    return paths;
  }

  async pruneExpired(now = Date.now()): Promise<number> {
    const entries = await readdir(this.root).catch(() => []);
    let removed = 0;
    for (const entry of entries) {
      const directory = join(this.root, entry);
      const info = await stat(directory).catch(() => undefined);
      if (!info || now - info.mtimeMs < UPLOAD_RETENTION_MS) continue;
      await rm(directory, { recursive: true, force: true });
      removed += 1;
    }
    return removed;
  }
}

export class UploadRejected extends Error {}
