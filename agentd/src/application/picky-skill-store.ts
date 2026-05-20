// Picky-only skill store.
//
// Independent of Pi's skill catalog: each skill is a flat SKILL.md-style file
// under ~/Library/Application Support/Picky/skills/ that the user can author
// directly. The realtime main runtime reads names + descriptions once per
// session and exposes the full body via the `picky_skill` tool (action=get).
//
// One file per skill. Frontmatter `name` is the canonical id; when missing,
// the filename (without .md) is used. Filenames should be kebab-case.
//
// Seeding: built-in templates ship in `seedSourceDir`. The store tracks which
// seeds it has already delivered via a `.seeded` manifest — one filename per
// line. A seed file is copied only when it is NOT in the manifest, so files
// the user has intentionally deleted are not silently re-created and new
// seeds added in later releases are picked up automatically.
//
// Hosts that shipped with the pre-manifest marker (an opaque "seeded at ..."
// string) are migrated by assuming the user has already received the very
// first seed (`create-picky-skill.md`) and nothing else — every later seed
// is then delivered as if it were new.

import { copyFile, mkdir, readFile, readdir, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

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

type SkillDoc = PickySkillDetails & {
  normalizedName: string;
  searchable: string;
  mtimeMs: number;
};

export interface PickySkillStoreOptions {
  /** Override the skills directory. Defaults to
   *  `~/Library/Application Support/Picky/skills`. */
  skillsDir?: string;
  /** Override the seed source directory. Defaults to the bundled
   *  `seeds/picky-skills` shipped with agentd. Set to `null` to disable
   *  seeding entirely (used by tests). */
  seedSourceDir?: string | null;
}

const SEEDED_MARKER = ".seeded";
const SEEDED_HEADER = "# Picky skill seeds already delivered. Each line is a filename in the seeds source dir. Do not edit unless you know what you are doing.\n";
// Seeds that existed when the manifest format was first introduced. Used to
// migrate hosts whose `.seeded` file still holds the opaque first-release
// marker. Keep this list in sync only when adding NEW seeds — never remove
// entries; doing so would re-deliver the seed to existing users.
const LEGACY_SEEDED_FILES = ["create-picky-skill.md"];

export class PickySkillStore {
  private cache = new Map<string, SkillDoc>();
  private dirMtimeMs = -1;
  private readonly skillsDir: string;
  private readonly seedSourceDir: string | null;

  constructor(options: PickySkillStoreOptions = {}) {
    this.skillsDir = options.skillsDir ?? defaultPickySkillsDir();
    this.seedSourceDir = options.seedSourceDir === undefined ? defaultSeedSourceDir() : options.seedSourceDir;
  }

  /** Resolved skills directory. Stable for the lifetime of the store. */
  get directory(): string {
    return this.skillsDir;
  }

  /** Create the skills dir if needed and copy seed templates the first time.
   *  Idempotent: a `.seeded` marker prevents repeated copies. Failures are
   *  swallowed (best-effort) because losing a seed is not worth blocking the
   *  realtime session boot. */
  async ensureSeeded(): Promise<void> {
    try {
      await mkdir(this.skillsDir, { recursive: true });
    } catch {
      return;
    }
    const sourceDir = this.seedSourceDir;
    if (!sourceDir) return;

    const manifestPath = join(this.skillsDir, SEEDED_MARKER);
    const delivered = await this.readSeededManifest(manifestPath);

    let entries: string[];
    try {
      entries = await readdir(sourceDir);
    } catch {
      entries = [];
    }
    let manifestChanged = false;
    for (const entry of entries.sort()) {
      if (!entry.endsWith(".md")) continue;
      if (delivered.has(entry)) continue;
      const dst = join(this.skillsDir, entry);
      try {
        await stat(dst);
        // The user already has a file under that name (perhaps hand-authored).
        // Record it as delivered so we never overwrite it, but do not copy.
        delivered.add(entry);
        manifestChanged = true;
        continue;
      } catch {
        // missing — copy in
      }
      try {
        await copyFile(join(sourceDir, entry), dst);
        delivered.add(entry);
        manifestChanged = true;
      } catch {
        // ignore individual file failures; we will retry on next boot.
      }
    }
    if (!manifestChanged && delivered.size > 0) {
      // Even with no new copies, persist a manifest if we migrated from the
      // legacy opaque marker so the next boot is a fast no-op.
      try {
        await stat(manifestPath);
      } catch {
        manifestChanged = true;
      }
    }
    if (manifestChanged) {
      try {
        await writeFile(manifestPath, SEEDED_HEADER + Array.from(delivered).sort().join("\n") + "\n", "utf8");
      } catch {
        // marker write failure is non-fatal; worst case we attempt to re-seed next boot.
      }
    }
  }

  /** Read the per-skill manifest written by previous `ensureSeeded` runs.
   *  Returns a set of filenames (e.g. "manage-pickles.md") that the store
   *  has already delivered to the user's skills directory. Pre-manifest hosts
   *  carried an opaque "seeded at <timestamp>" string — those are migrated
   *  to the set of first-release seeds so later additions can still flow. */
  private async readSeededManifest(path: string): Promise<Set<string>> {
    const delivered = new Set<string>();
    let raw: string;
    try {
      raw = await readFile(path, "utf8");
    } catch {
      return delivered;
    }
    let recognized = false;
    for (const line of raw.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      if (!trimmed.endsWith(".md")) continue;
      delivered.add(trimmed);
      recognized = true;
    }
    if (!recognized) {
      // Legacy opaque marker ("seeded at <iso>"). Assume the user already
      // received the first-release seeds and nothing else; later additions
      // will be delivered as fresh entries.
      for (const legacy of LEGACY_SEEDED_FILES) delivered.add(legacy);
    }
    return delivered;
  }

  /** Cheap session-start snapshot: { name, description } for every skill in
   *  the folder. Used to inject the catalog into the realtime instructions
   *  once at connect time. */
  async list(): Promise<PickySkillSummary[]> {
    const docs = await this.loadDocuments();
    return docs.map(({ name, description, path }) => ({ name, description, path }));
  }

  async search(request: { query?: string; limit?: number } = {}): Promise<{ query: string; root: string; total: number; skills: PickySkillSummary[] }> {
    const docs = await this.loadDocuments();
    const query = request.query?.trim() ?? "";
    const limit = clampLimit(request.limit, 8, 20);
    const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
    const scored = docs
      .map((doc) => ({ doc, score: scoreSkill(doc, terms), match: matchSnippet(doc, terms) }))
      .filter(({ score }) => terms.length === 0 || score > 0)
      .sort((a, b) => b.score - a.score || a.doc.name.localeCompare(b.doc.name));
    return {
      query,
      root: this.skillsDir,
      total: scored.length,
      skills: scored.slice(0, limit).map(({ doc, match }) => ({
        name: doc.name,
        description: doc.description,
        path: doc.path,
        ...(match ? { match } : {}),
      })),
    };
  }

  async details(request: { name: string }): Promise<PickySkillDetails> {
    const requested = request.name.trim().replace(/^skill:/, "");
    if (!requested) throw new Error("Skill name is required");
    const normalized = requested.toLowerCase();
    const docs = await this.loadDocuments();
    const doc = docs.find(
      (d) => d.normalizedName === normalized || basename(d.path, ".md").toLowerCase() === normalized,
    );
    if (!doc) throw new Error(`Skill not found: ${request.name}`);
    return {
      name: doc.name,
      description: doc.description,
      path: doc.path,
      frontmatter: doc.frontmatter,
      content: doc.content,
    };
  }

  private async loadDocuments(): Promise<SkillDoc[]> {
    let dirStat;
    try {
      dirStat = await stat(this.skillsDir);
    } catch {
      this.cache.clear();
      this.dirMtimeMs = -1;
      return [];
    }
    if (!dirStat.isDirectory()) {
      this.cache.clear();
      this.dirMtimeMs = -1;
      return [];
    }
    if (dirStat.mtimeMs === this.dirMtimeMs && this.cache.size > 0) {
      return Array.from(this.cache.values()).sort((a, b) => a.name.localeCompare(b.name));
    }

    let entries: string[];
    try {
      entries = await readdir(this.skillsDir);
    } catch {
      return [];
    }
    const next = new Map<string, SkillDoc>();
    for (const entry of entries) {
      if (!entry.endsWith(".md")) continue;
      if (entry === "README.md") continue;
      const path = join(this.skillsDir, entry);
      let fileStat;
      try {
        fileStat = await stat(path);
      } catch {
        continue;
      }
      if (!fileStat.isFile()) continue;

      const cached = this.cache.get(path);
      if (cached && cached.mtimeMs === fileStat.mtimeMs) {
        next.set(path, cached);
        continue;
      }

      let content: string;
      try {
        content = await readFile(path, "utf8");
      } catch {
        continue;
      }
      const parsed = parseSkillMarkdown(content);
      const name = (parsed.frontmatter.name || basename(entry, ".md")).trim();
      const description = (parsed.frontmatter.description || "").trim();
      if (!name) continue;
      next.set(path, {
        name,
        description,
        path,
        frontmatter: parsed.frontmatter,
        content,
        normalizedName: name.toLowerCase(),
        searchable: [name, description, parsed.body].join("\n").toLowerCase(),
        mtimeMs: fileStat.mtimeMs,
      });
    }
    this.cache = next;
    this.dirMtimeMs = dirStat.mtimeMs;
    return Array.from(next.values()).sort((a, b) => a.name.localeCompare(b.name));
  }
}

export function defaultPickySkillsDir(): string {
  return join(homedir(), "Library", "Application Support", "Picky", "skills");
}

/** Locate the bundled seed directory across the four runtimes Picky ships
 *  with: `node dist/index.js` from inside `Picky.app/Contents/Resources/agentd`,
 *  `tsx src/index.ts` from a dev checkout, vitest from `src/`, and the
 *  pnpm-deployed runtime under `build/agentd-runtime`. The directory layout
 *  is `<agentd-root>/seeds/picky-skills/*.md` in every case. */
function defaultSeedSourceDir(): string | null {
  const moduleDir = dirname(fileURLToPath(import.meta.url));
  // Compiled runtime: dist/application/picky-skill-store.js -> agentd root is two levels up.
  // Source runtime:   src/application/picky-skill-store.ts  -> agentd root is two levels up.
  return join(moduleDir, "..", "..", "seeds", "picky-skills");
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

function clampLimit(value: number | undefined, defaultValue: number, max: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return defaultValue;
  return Math.max(1, Math.min(max, Math.floor(value)));
}

function scoreSkill(doc: SkillDoc, terms: string[]): number {
  if (terms.length === 0) return 1;
  let score = 0;
  const name = doc.name.toLowerCase();
  const description = doc.description.toLowerCase();
  for (const term of terms) {
    if (name === term) score += 100;
    if (name.includes(term)) score += 40;
    if (description.includes(term)) score += 20;
    if (doc.searchable.includes(term)) score += 5;
  }
  return score;
}

function matchSnippet(doc: SkillDoc, terms: string[]): string | undefined {
  if (terms.length === 0) return undefined;
  for (const term of terms) {
    const di = doc.description.toLowerCase().indexOf(term);
    if (di >= 0) return doc.description;
    const ci = doc.content.toLowerCase().indexOf(term);
    if (ci >= 0) {
      const start = Math.max(0, ci - 80);
      const end = Math.min(doc.content.length, ci + 160);
      const prefix = start > 0 ? "…" : "";
      const suffix = end < doc.content.length ? "…" : "";
      return `${prefix}${doc.content.slice(start, end).replace(/\s+/g, " ").trim()}${suffix}`;
    }
  }
  return undefined;
}
