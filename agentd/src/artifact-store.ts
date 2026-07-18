import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import type { PickyAgentSession, PickyArtifact } from "./protocol.js";

export function defaultAppSupportRoot(): string {
  return join(homedir(), "Library", "Application Support", "Picky");
}

export function safeRelativeName(name: string): string {
  if (!name || name.includes("\0") || name.includes("/") || name.includes("\\") || name !== basename(name) || name === "." || name === "..") {
    throw new Error(`Unsafe artifact path: ${name}`);
  }
  return name;
}

export function extractGithubPullRequestUrls(text: string): string[] {
  return extractSessionLinks(text).filter((link) => link.kind === "github" && /\/pull\/[0-9]+\/?(?:$|[?#])/.test(link.url)).map((link) => link.url);
}

export function githubPullRequestTitle(url: string): string {
  const number = githubIssueOrPullRequestNumber(url);
  return number ? `#${number}` : "GitHub";
}

type SessionLinkKind = "github" | "slack" | "notion" | "jira" | "sentry" | "linear" | "figma" | "googleDocs" | "googleSheets" | "googleSlides" | "googleDrive" | "link";

interface ExtractedSessionLink {
  kind: SessionLinkKind;
  title: string;
  url: string;
}

type ClassifiedSessionLinkKind = Exclude<SessionLinkKind, "link">;

interface SessionLinkClassifier {
  kind: ClassifiedSessionLinkKind;
  matches: (url: string, parsed: URL, host: string) => boolean;
}

const SESSION_LINK_CLASSIFIERS: readonly SessionLinkClassifier[] = [
  { kind: "github", matches: (_url, parsed, host) => host === "github.com" && /\/[^/]+\/[^/]+\/(?:pull|issues)\/[0-9]+\/?$/.test(parsed.pathname) },
  { kind: "slack", matches: (_url, parsed, host) => host.endsWith(".slack.com") && /\/archives\/[A-Z0-9]+\/p[0-9]+$/.test(parsed.pathname) },
  { kind: "notion", matches: (_url, _parsed, host) => ["notion.so", "www.notion.so", "app.notion.com"].includes(host) },
  { kind: "jira", matches: (url, _parsed, host) => host.endsWith(".atlassian.net") && Boolean(jiraIssueKey(url)) },
  { kind: "sentry", matches: (_url, parsed, host) => host.endsWith(".sentry.io") && /\/issues\/[0-9]+\/?$/.test(parsed.pathname) },
  { kind: "linear", matches: (url, _parsed, host) => host === "linear.app" && Boolean(linearIssueKey(url)) },
  { kind: "figma", matches: (_url, parsed, host) => (host === "figma.com" || host.endsWith(".figma.com")) && /^\/(file|design|proto|board)\/[A-Za-z0-9_-]+(?:\/|$)/.test(parsed.pathname) },
  { kind: "googleDocs", matches: (_url, parsed, host) => host === "docs.google.com" && /^\/document\/d\/[^/]+/.test(parsed.pathname) },
  { kind: "googleSheets", matches: (_url, parsed, host) => host === "docs.google.com" && /^\/spreadsheets\/d\/[^/]+/.test(parsed.pathname) },
  { kind: "googleSlides", matches: (_url, parsed, host) => host === "docs.google.com" && /^\/presentation\/d\/[^/]+/.test(parsed.pathname) },
  { kind: "googleDrive", matches: (_url, parsed, host) => host === "drive.google.com" && (/^\/file\/d\/[^/]+/.test(parsed.pathname) || /^\/drive\//.test(parsed.pathname)) },
];

export function extractSessionLinks(text: string): ExtractedSessionLink[] {
  const links: ExtractedSessionLink[] = [];
  const seen = new Set<string>();
  for (const rawUrl of extractRawLinkCandidates(text)) {
    const candidate = normalizeLinkUrl(rawUrl);
    if (!candidate) continue;
    const kind = sessionLinkKind(candidate);
    if (!kind) continue;
    const url = canonicalSessionLinkUrl(candidate, kind);
    if (seen.has(url)) continue;
    seen.add(url);
    links.push({ kind, title: sessionLinkTitle(kind, url), url });
  }
  return links;
}

function extractRawLinkCandidates(text: string): string[] {
  const candidates: string[] = [];
  const regex = /https?:(?:\/\/|\\\/\\\/)/gi;
  for (const match of text.matchAll(regex)) {
    let rawUrl = "";
    for (let index = match.index; index < text.length; index += 1) {
      const char = text[index]!;
      const next = text[index + 1];
      if (char === "\\" && next === "/") {
        rawUrl += "/";
        index += 1;
        continue;
      }
      if (char === "\\" && next === "n") break;
      if (isLinkDelimiter(char)) break;
      rawUrl += char;
    }
    candidates.push(rawUrl);
  }
  return candidates;
}

function isLinkDelimiter(char: string): boolean {
  return /[\s<>"{}|\\^[\]]/.test(char);
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
  return SESSION_LINK_CLASSIFIERS.find((classifier) => classifier.matches(url, parsed, host))?.kind ?? "link";
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
  if (kind === "googleDrive") return "Drive";
  return safeUrl(url)?.hostname || "Link";
}

function githubIssueOrPullRequestNumber(url: string): string | undefined {
  return url.match(/\/(?:pull|issues)\/([0-9]+)\/?(?:$|[?#])/)?.[1];
}

function jiraIssueKey(url: string): string | undefined {
  return url.match(/\/browse\/([A-Z][A-Z0-9]+-[0-9]+)(?:$|[?#])/)?.[1];
}

function linearIssueKey(url: string): string | undefined {
  return url.match(/\/issue\/([A-Z][A-Z0-9]+-[0-9]+)(?:\/|$|[?#])/)?.[1];
}

function normalizeLinkUrl(rawUrl: string): string | undefined {
  let trimmed = rawUrl.replace(/(?:&quot;|&#34;|&apos;|&#39;)+$/g, "").replace(/[.,;:!?]+$/g, "");
  while (trimmed.endsWith(")") && countCharacter(trimmed, ")") > countCharacter(trimmed, "(")) trimmed = trimmed.slice(0, -1);
  const parsed = safeUrl(trimmed);
  if (!parsed || (parsed.protocol !== "http:" && parsed.protocol !== "https:")) return undefined;
  return parsed.toString();
}

function canonicalSessionLinkUrl(url: string, kind: SessionLinkKind): string {
  if (kind === "link") return url;
  const parsed = new URL(url);
  parsed.search = "";
  parsed.hash = "";
  return parsed.toString();
}

function countCharacter(value: string, character: string): number {
  return [...value].filter((valueCharacter) => valueCharacter === character).length;
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


