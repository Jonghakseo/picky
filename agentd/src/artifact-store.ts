import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
import type { PickyArtifact } from "./protocol.js";

export interface ArtifactWriteInput {
  id: string;
  kind: string;
  title: string;
  fileName: string;
  content: string | Buffer;
}

export class ArtifactStore {
  readonly root: string;

  constructor(appSupportRoot = defaultAppSupportRoot()) {
    this.root = resolve(appSupportRoot, "artifacts");
  }

  async write(sessionId: string, input: ArtifactWriteInput): Promise<PickyArtifact> {
    const dir = this.sessionDir(sessionId);
    const safeFile = safeRelativeName(input.fileName);
    await mkdir(dir, { recursive: true });
    const path = resolve(dir, safeFile);
    ensureUnder(dir, path);
    await writeFile(path, input.content);
    return { id: input.id, kind: input.kind, title: input.title, path, updatedAt: new Date().toISOString() };
  }

  async read(sessionId: string, artifactIdOrFileName: string): Promise<Buffer> {
    const path = resolve(this.sessionDir(sessionId), safeRelativeName(artifactIdOrFileName));
    ensureUnder(this.sessionDir(sessionId), path);
    return readFile(path);
  }

  async list(sessionId: string): Promise<string[]> {
    try {
      return await readdir(this.sessionDir(sessionId));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
      throw error;
    }
  }

  pathFor(sessionId: string, artifactFileName: string): string {
    const path = resolve(this.sessionDir(sessionId), safeRelativeName(artifactFileName));
    ensureUnder(this.sessionDir(sessionId), path);
    return path;
  }

  private sessionDir(sessionId: string): string {
    return resolve(this.root, safeSegment(sessionId));
  }
}

export function defaultAppSupportRoot(): string {
  return join(homedir(), "Library", "Application Support", "Picky");
}

export function safeRelativeName(name: string): string {
  if (!name || name.includes("\0") || name.includes("/") || name.includes("\\") || name !== basename(name) || name === "." || name === "..") {
    throw new Error(`Unsafe artifact path: ${name}`);
  }
  return name;
}

function safeSegment(value: string): string {
  if (!value || value.includes("..") || value.includes("/") || value.includes("\\")) throw new Error(`Unsafe path segment: ${value}`);
  return value.replace(/[^a-zA-Z0-9._-]/g, "_");
}

function ensureUnder(root: string, candidate: string): void {
  const resolvedRoot = resolve(root);
  const resolvedCandidate = resolve(candidate);
  if (resolvedCandidate !== resolvedRoot && !resolvedCandidate.startsWith(`${resolvedRoot}/`)) {
    throw new Error(`Path escapes artifact root: ${candidate}`);
  }
}
