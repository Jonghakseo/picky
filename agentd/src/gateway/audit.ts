/**
 * Append-only audit log (docs/remote-pwa-implementation.md 2.3).
 *
 * One JSON line per security-relevant action. Message text, recordings and
 * transcripts are never written; the one deliberate exception is the full
 * command line of a `!` shell message, because a phone that runs shell commands
 * on the Mac has to leave a trace of what it ran.
 */
import { appendFile, rename, stat, unlink } from "node:fs/promises";
import { dataPath, ensureDirectory, FILE_MODE } from "./storage.js";

export const AUDIT_ROTATE_BYTES = 5 * 1024 * 1024;
export const AUDIT_KEPT_FILES = 3;

export type AuditEvent =
  | { action: "pair.attempt"; ip: string; ok: boolean; reason?: string; deviceName?: string }
  | { action: "pair.success"; ip: string; deviceId: string; deviceName: string }
  | { action: "device.revoke"; deviceId: string; by: "hub" | "device" }
  | { action: "command"; deviceId: string; type: string; sessionId?: string; textChars?: number; shellCommand?: string }
  | { action: "file.read"; deviceId: string; sessionId: string; path: string; ok: boolean; reason?: string }
  | { action: "upload"; deviceId: string; uploadId: string; bytes: number; mime: string }
  | { action: "dictation"; deviceId: string; bytes: number; ok: boolean; reason?: string }
  | { action: "push.subscribe"; deviceId: string; endpointHost: string }
  | { action: "push.unsubscribe"; deviceId: string; endpointHost: string }
  | { action: "lockout"; ip: string; untilMs: number };

export class AuditLog {
  private readonly path: string;
  private writing: Promise<void> = Promise.resolve();

  constructor(private readonly dataDir: string) {
    this.path = dataPath(dataDir, "audit.jsonl");
  }

  record(event: AuditEvent): void {
    const line = `${JSON.stringify({ at: new Date().toISOString(), ...event })}\n`;
    // Serialized through one promise chain so concurrent requests cannot
    // interleave a rotation with an append.
    this.writing = this.writing.then(() => this.append(line)).catch(() => {});
  }

  /** Resolves once every `record` queued so far has hit disk (tests, shutdown). */
  async flush(): Promise<void> {
    await this.writing;
  }

  private async append(line: string): Promise<void> {
    await ensureDirectory(this.dataDir);
    await this.rotateIfNeeded();
    await appendFile(this.path, line, { mode: FILE_MODE });
  }

  private async rotateIfNeeded(): Promise<void> {
    const size = await stat(this.path).then((info) => info.size).catch(() => 0);
    if (size < AUDIT_ROTATE_BYTES) return;
    await unlink(`${this.path}.${AUDIT_KEPT_FILES}`).catch(() => {});
    for (let index = AUDIT_KEPT_FILES - 1; index >= 1; index -= 1) {
      await rename(`${this.path}.${index}`, `${this.path}.${index + 1}`).catch(() => {});
    }
    await rename(this.path, `${this.path}.1`).catch(() => {});
  }
}
