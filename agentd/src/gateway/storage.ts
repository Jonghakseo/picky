/**
 * On-disk helpers for `<PICKY_APP_SUPPORT_DIR>/Remote`.
 *
 * Everything here holds credentials or user files reachable from the phone, so
 * directories are 0700, files are 0600, and JSON writes go through a temp file
 * plus rename: a crash mid-write must never leave a half-parsed device list
 * that would silently unpair every phone.
 */
import { randomBytes } from "node:crypto";
import { mkdirSync } from "node:fs";
import { chmod, mkdir, readdir, readFile, rename, rm, stat, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";

export const DIRECTORY_MODE = 0o700;
export const FILE_MODE = 0o600;

export function ensureDirectorySync(path: string): void {
  mkdirSync(path, { recursive: true, mode: DIRECTORY_MODE });
}

export async function ensureDirectory(path: string): Promise<void> {
  await mkdir(path, { recursive: true, mode: DIRECTORY_MODE });
  // `mkdir` only applies the mode when it creates the directory, so an existing
  // directory from an older build keeps whatever umask produced it.
  await chmod(path, DIRECTORY_MODE).catch(() => {});
}

export async function readJsonFile<T>(path: string): Promise<T | undefined> {
  try {
    return JSON.parse(await readFile(path, "utf8")) as T;
  } catch {
    return undefined;
  }
}

export async function writeJsonFileAtomic(path: string, value: unknown): Promise<void> {
  await writeFileAtomic(path, `${JSON.stringify(value, null, 2)}\n`);
}

export async function writeFileAtomic(path: string, data: string | Uint8Array): Promise<void> {
  const temporaryPath = `${path}.${randomBytes(6).toString("hex")}.tmp`;
  try {
    await writeFile(temporaryPath, data, { mode: FILE_MODE });
    await rename(temporaryPath, path);
  } catch (error) {
    await unlink(temporaryPath).catch(() => {});
    throw error;
  }
}

export async function removeFile(path: string): Promise<void> {
  await rm(path, { force: true });
}

/** Deletes direct children of `directory` last modified more than `maxAgeMs` ago. Returns how many went. */
export async function pruneOlderThan(directory: string, maxAgeMs: number, now = Date.now()): Promise<number> {
  const entries = await readdir(directory).catch(() => []);
  let removed = 0;
  for (const entry of entries) {
    const path = join(directory, entry);
    const info = await stat(path).catch(() => undefined);
    if (!info || now - info.mtimeMs < maxAgeMs) continue;
    await rm(path, { recursive: true, force: true }).catch(() => {});
    removed += 1;
  }
  return removed;
}

/** URL-safe id used for devices, uploads and request correlation. */
export function randomId(bytes = 12): string {
  return randomBytes(bytes).toString("base64url");
}

export function dataPath(dataDir: string, ...segments: string[]): string {
  return join(dataDir, ...segments);
}
