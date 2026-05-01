import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
import type { PickyAgentSession, PickyArtifact } from "./protocol.js";

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

  async writeSessionReport(session: PickyAgentSession): Promise<PickyArtifact> {
    return this.write(session.id, {
      id: "report",
      kind: "report",
      title: "Session report",
      fileName: "report.md",
      content: renderSessionReport(session),
    });
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

export function renderSessionReport(session: PickyAgentSession): string {
  const lines: string[] = [`# ${session.title}`, "", `Status: \`${session.status}\``, ""];
  if (session.cwd) lines.push(`CWD: \`${session.cwd}\``, "");
  const finalAnswer = session.finalAnswer || session.lastSummary;
  if (finalAnswer) lines.push("## Final answer", finalAnswer, "");
  if (session.tools.length > 0) {
    lines.push("## Tool summary");
    for (const tool of session.tools) lines.push(`- \`${tool.name}\` ${tool.status}${tool.preview ? ` — ${tool.preview}` : ""}`);
    lines.push("");
  }
  if (session.changedFiles.length > 0) {
    lines.push("## Changed files");
    for (const file of session.changedFiles) lines.push(`- ${file.status} \`${file.path}\`${file.summary ? ` — ${file.summary}` : ""}`);
    lines.push("");
  }
  const prUrls = extractGithubPullRequestUrls([session.finalAnswer, session.lastSummary, ...session.logs, ...session.tools.map((tool) => tool.preview)].filter(Boolean).join("\n"));
  if (prUrls.length > 0) lines.push("## Pull requests", ...prUrls.map((url) => `- ${url}`), "");
  return `${lines.join("\n").trimEnd()}\n`;
}

export function extractGithubPullRequestUrls(text: string): string[] {
  const regex = /https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[0-9]+/g;
  return [...new Set(text.match(regex) ?? [])];
}

export function extractChangedFilesFromExplicitText(text: string): PickyAgentSession["changedFiles"] {
  const files: PickyAgentSession["changedFiles"] = [];
  const regex = /(?:^|\n)(?:follow-up:\s*)?Changed file:\s*([AMDR?]+)\s+([^\s]+)(?:\s+-\s+([^\n]+))?/gim;
  for (const match of text.matchAll(regex)) files.push({ status: match[1]!, path: match[2]!, summary: match[3] });
  return files;
}

function ensureUnder(root: string, candidate: string): void {
  const resolvedRoot = resolve(root);
  const resolvedCandidate = resolve(candidate);
  if (resolvedCandidate !== resolvedRoot && !resolvedCandidate.startsWith(`${resolvedRoot}/`)) {
    throw new Error(`Path escapes artifact root: ${candidate}`);
  }
}
