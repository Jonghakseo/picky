import { readdir, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join } from "node:path";

export type PickySkillSummary = {
  name: string;
  description: string;
  path: string;
  match?: string;
};

export type PickySkillDetails = PickySkillSummary & {
  frontmatter: Record<string, string>;
  content: string;
};

type SkillDocument = PickySkillDetails & {
  normalizedName: string;
  searchableText: string;
};

export class PickySkillCatalog {
  constructor(private readonly root = process.env.PICKY_SKILLS_DIR ?? join(homedir(), ".pi", "agent", "skills")) {}

  async search(request: { query?: string; limit?: number } = {}): Promise<{ query: string; root: string; total: number; skills: PickySkillSummary[] }> {
    const query = request.query?.trim() ?? "";
    const limit = clampLimit(request.limit, 8, 20);
    const documents = await this.loadDocuments();
    const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
    const scored = documents
      .map((document) => ({ document, score: scoreSkill(document, terms), match: matchSnippet(document, terms) }))
      .filter(({ score }) => terms.length === 0 || score > 0)
      .sort((a, b) => b.score - a.score || a.document.name.localeCompare(b.document.name));

    return {
      query,
      root: this.root,
      total: scored.length,
      skills: scored.slice(0, limit).map(({ document, match }) => ({
        name: document.name,
        description: document.description,
        path: document.path,
        ...(match ? { match } : {}),
      })),
    };
  }

  async details(request: { name: string }): Promise<PickySkillDetails> {
    const requestedName = request.name.trim().replace(/^skill:/, "");
    if (!requestedName) throw new Error("Skill name is required");
    const normalized = normalizeSkillName(requestedName);
    const documents = await this.loadDocuments();
    const document = documents.find((skill) =>
      skill.normalizedName === normalized || normalizeSkillName(basename(skill.path, ".md")) === normalized
    );
    if (!document) throw new Error(`Skill not found: ${request.name}`);
    return {
      name: document.name,
      description: document.description,
      path: document.path,
      match: document.match,
      frontmatter: document.frontmatter,
      content: document.content,
    };
  }

  private async loadDocuments(): Promise<SkillDocument[]> {
    let entries: Array<{ name: string; isDirectory(): boolean }>;
    try {
      entries = await readdir(this.root, { withFileTypes: true });
    } catch (error) {
      throw new Error(`Unable to read Pi skills directory: ${error instanceof Error ? error.message : String(error)}`);
    }

    const documents = await Promise.all(entries
      .filter((entry) => entry.isDirectory())
      .map(async (entry) => this.loadDocument(entry.name)));

    return documents
      .filter((document): document is SkillDocument => Boolean(document))
      .sort((a, b) => a.name.localeCompare(b.name));
  }

  private async loadDocument(directoryName: string): Promise<SkillDocument | undefined> {
    const path = join(this.root, directoryName, "SKILL.md");
    let content: string;
    try {
      content = await readFile(path, "utf8");
    } catch {
      return undefined;
    }
    const parsed = parseSkillMarkdown(content);
    const name = parsed.frontmatter.name || directoryName;
    const description = parsed.frontmatter.description || firstParagraph(parsed.body);
    return {
      name,
      description,
      path,
      frontmatter: parsed.frontmatter,
      content,
      normalizedName: normalizeSkillName(name),
      searchableText: [name, description, parsed.body].join("\n").toLowerCase(),
    };
  }
}

function parseSkillMarkdown(content: string): { frontmatter: Record<string, string>; body: string } {
  if (!content.startsWith("---")) return { frontmatter: {}, body: content };
  const match = content.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?/);
  if (!match) return { frontmatter: {}, body: content };
  const frontmatter: Record<string, string> = {};
  for (const line of match[1].split(/\r?\n/)) {
    const parsed = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
    if (!parsed) continue;
    frontmatter[parsed[1]] = stripYamlScalar(parsed[2]);
  }
  return { frontmatter, body: content.slice(match[0].length) };
}

function stripYamlScalar(value: string): string {
  const trimmed = value.trim();
  if ((trimmed.startsWith('"') && trimmed.endsWith('"')) || (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function firstParagraph(body: string): string {
  return body.split(/\n\s*\n/).map((part) => part.trim()).find(Boolean)?.replace(/\s+/g, " ") ?? "";
}

function normalizeSkillName(name: string): string {
  return name.trim().toLowerCase();
}

function clampLimit(value: number | undefined, defaultValue: number, max: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return defaultValue;
  return Math.max(1, Math.min(max, Math.floor(value)));
}

function scoreSkill(document: SkillDocument, terms: string[]): number {
  if (terms.length === 0) return 1;
  let score = 0;
  const name = document.name.toLowerCase();
  const description = document.description.toLowerCase();
  for (const term of terms) {
    if (name === term) score += 100;
    if (name.includes(term)) score += 40;
    if (description.includes(term)) score += 20;
    if (document.searchableText.includes(term)) score += 5;
  }
  return score;
}

function matchSnippet(document: SkillDocument, terms: string[]): string | undefined {
  if (terms.length === 0) return undefined;
  for (const term of terms) {
    const descriptionIndex = document.description.toLowerCase().indexOf(term);
    if (descriptionIndex >= 0) return document.description;
    const contentIndex = document.content.toLowerCase().indexOf(term);
    if (contentIndex >= 0) return compactSnippet(document.content, contentIndex);
  }
  return undefined;
}

function compactSnippet(content: string, index: number): string {
  const start = Math.max(0, index - 80);
  const end = Math.min(content.length, index + 160);
  const prefix = start > 0 ? "…" : "";
  const suffix = end < content.length ? "…" : "";
  return `${prefix}${content.slice(start, end).replace(/\s+/g, " ").trim()}${suffix}`;
}
