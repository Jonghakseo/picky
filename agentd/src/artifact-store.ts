import { createHash } from "node:crypto";
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
      fileName: timestampedReportFileName(session.updatedAt),
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

export function timestampedReportFileName(timestamp: string): string {
  const parsed = new Date(timestamp);
  const iso = Number.isNaN(parsed.getTime()) ? new Date().toISOString() : parsed.toISOString();
  return `report-${iso.replace(/[:.]/g, "-")}.md`;
}

export function renderSessionReport(session: PickyAgentSession): string {
  const lines: string[] = [`# ${session.title}`, "", `Status: \`${session.status}\``, ""];
  if (session.cwd) lines.push(`CWD: \`${session.cwd}\``, "");
  const finalAnswer = session.finalAnswer || session.lastSummary;
  if (finalAnswer) lines.push("## Final answer", finalAnswer, "");
  const toolCounts = summarizeToolCalls(session.tools);
  if (toolCounts.length > 0) {
    lines.push("## Tool summary");
    for (const tool of toolCounts) lines.push(`- \`${tool.name}\`: ${tool.count}`);
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

function summarizeToolCalls(tools: PickyAgentSession["tools"]): Array<{ name: string; count: number }> {
  const counts = new Map<string, number>();
  for (const tool of tools) counts.set(tool.name, (counts.get(tool.name) ?? 0) + 1);
  return [...counts.entries()].map(([name, count]) => ({ name, count }));
}

export function extractGithubPullRequestUrls(text: string): string[] {
  return extractSessionLinks(text).filter((link) => link.kind === "github" && /\/pull\/[0-9]+(?:$|[?#])/.test(link.url)).map((link) => link.url);
}

export function githubPullRequestTitle(url: string): string {
  const number = githubIssueOrPullRequestNumber(url);
  return number ? `#${number}` : "GitHub";
}

export type SessionLinkKind = "github" | "slack" | "notion" | "jira" | "sentry" | "linear" | "figma" | "googleDocs" | "googleSheets" | "googleSlides" | "googleDrive";

export interface ExtractedSessionLink {
  kind: SessionLinkKind;
  title: string;
  url: string;
}

export function extractSessionLinks(text: string): ExtractedSessionLink[] {
  const regex = /https:\/\/[^\s<>)\]]+/g;
  const links: ExtractedSessionLink[] = [];
  const seen = new Set<string>();
  for (const match of text.matchAll(regex)) {
    const url = normalizeLinkUrl(match[0]);
    if (!url || seen.has(url)) continue;
    const kind = sessionLinkKind(url);
    if (!kind) continue;
    seen.add(url);
    links.push({ kind, title: sessionLinkTitle(kind, url), url });
  }
  return links;
}

export function extractSessionLinkArtifacts(text: string, updatedAt = new Date().toISOString()): PickyArtifact[] {
  return extractSessionLinks(text).map((link) => ({
    id: `link-${link.kind}-${hashUrl(link.url)}`,
    kind: link.kind,
    title: link.title,
    url: link.url,
    updatedAt,
  }));
}

function sessionLinkKind(url: string): SessionLinkKind | undefined {
  const parsed = safeUrl(url);
  const host = parsed?.hostname.toLowerCase();
  if (!parsed || !host) return undefined;
  if (host === "github.com" && /\/[^/]+\/[^/]+\/(?:pull|issues)\/[0-9]+$/.test(parsed.pathname)) return "github";
  if (host.endsWith(".slack.com") && /\/archives\/[A-Z0-9]+\/p[0-9]+$/.test(parsed.pathname)) return "slack";
  if (["notion.so", "www.notion.so", "app.notion.com"].includes(host)) return "notion";
  if (host.endsWith(".atlassian.net") && jiraIssueKey(url)) return "jira";
  if (host.endsWith(".sentry.io") && /\/issues\/[0-9]+\/?$/.test(parsed.pathname)) return "sentry";
  if (host === "linear.app" && linearIssueKey(url)) return "linear";
  if ((host === "figma.com" || host.endsWith(".figma.com")) && /^\/(file|design|proto|board)\/[A-Za-z0-9_-]+(?:\/|$)/.test(parsed.pathname)) return "figma";
  if (host === "docs.google.com") {
    if (/^\/document\/d\/[^/]+/.test(parsed.pathname)) return "googleDocs";
    if (/^\/spreadsheets\/d\/[^/]+/.test(parsed.pathname)) return "googleSheets";
    if (/^\/presentation\/d\/[^/]+/.test(parsed.pathname)) return "googleSlides";
  }
  if (host === "drive.google.com" && (/^\/file\/d\/[^/]+/.test(parsed.pathname) || /^\/drive\//.test(parsed.pathname))) return "googleDrive";
  return undefined;
}

function sessionLinkTitle(kind: SessionLinkKind, url: string): string {
  if (kind === "github") return githubPullRequestTitle(url);
  if (kind === "jira") return jiraIssueKey(url) ?? "Jira";
  if (kind === "linear") return linearIssueKey(url) ?? "Linear";
  if (kind === "slack") return "Slack";
  if (kind === "notion") return "Notion";
  if (kind === "sentry") return "Sentry";
  if (kind === "figma") return "Figma";
  if (kind === "googleDocs") return "Docs";
  if (kind === "googleSheets") return "Sheets";
  if (kind === "googleSlides") return "Slides";
  return "Drive";
}

function githubIssueOrPullRequestNumber(url: string): string | undefined {
  return url.match(/\/(?:pull|issues)\/([0-9]+)(?:$|[?#])/)?.[1];
}

function jiraIssueKey(url: string): string | undefined {
  return url.match(/\/browse\/([A-Z][A-Z0-9]+-[0-9]+)(?:$|[?#])/)?.[1];
}

function linearIssueKey(url: string): string | undefined {
  return url.match(/\/issue\/([A-Z][A-Z0-9]+-[0-9]+)(?:\/|$|[?#])/)?.[1];
}

function normalizeLinkUrl(rawUrl: string): string | undefined {
  const trimmed = rawUrl.replace(/[.,;:!?]+$/g, "");
  const parsed = safeUrl(trimmed);
  if (!parsed) return undefined;
  parsed.search = "";
  parsed.hash = "";
  return parsed.toString();
}

function safeUrl(value: string): URL | undefined {
  try {
    return new URL(value);
  } catch {
    return undefined;
  }
}

function hashUrl(url: string): string {
  return createHash("sha1").update(url).digest("hex").slice(0, 12);
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
