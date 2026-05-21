// Picky-only skill store.
//
// Independent of Pi's skill catalog. Each skill lives in its own directory
// under ~/Library/Application Support/Picky/skills/<name>/, containing at
// least a SKILL.md file (YAML frontmatter + Markdown body). Additional files
// referenced by the skill body may sit beside SKILL.md. This matches the
// Anthropic Agent Skills convention so users can hand-author skills the same
// way they would for any other agent.
//
// The realtime main runtime reads each skill's name, description, and SKILL.md
// path once per session and exposes the same metadata via the `picky_skills`
// tool. Directory name = canonical skill id; frontmatter `name` overrides the
// display name.
//
// Seeding: built-in skills ship in `seedSourceDir` using the same
// `<name>/SKILL.md` layout. The store tracks which seeds it has already
// delivered via a `.seeded` manifest \u2014 one directory name per line. A seed
// directory is copied only when it is NOT in the manifest, so directories
// the user has intentionally deleted are not silently re-created and seeds
// added in later releases are picked up automatically.
//
// Backwards compatibility:
//   - The first release stored skills as flat `<name>.md` files. `ensureSeeded`
//     migrates any such file into `<name>/SKILL.md` before doing anything else
//     (without clobbering an existing directory).
//   - Pre-manifest hosts carried an opaque "seeded at ..." marker. Those are
//     migrated by assuming the user already received the very first seed
//     (`create-picky-skill`) and nothing else \u2014 every later seed is then
//     delivered as if it were new.

import { access, copyFile, cp, mkdir, readFile, readdir, rename, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

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
  directoryName: string;
  normalizedName: string;
  normalizedDirectoryName: string;
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
const SEEDED_HEADER = "# Picky skill seeds already delivered. Each line is a directory name in the seeds source. Do not edit unless you know what you are doing.\n";
const SKILL_FILE_NAME = "SKILL.md";
// Skills that existed when the manifest format was first introduced. Used to
// migrate hosts whose `.seeded` file still holds the opaque first-release
// marker. Names are stored without extension. Keep this list append-only \u2014
// removing entries would re-deliver the seed to existing users.
const LEGACY_SEEDED_NAMES = ["create-picky-skill"];

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

  /** Create the skills dir if needed, migrate any leftover flat-layout files,
   *  then copy seed skill directories the user has not received yet. The
   *  `.seeded` manifest prevents re-delivery of seeds the user intentionally
   *  removed. Failures are swallowed (best-effort) because losing a seed is
   *  not worth blocking the realtime session boot. */
  async ensureSeeded(): Promise<void> {
    try {
      await mkdir(this.skillsDir, { recursive: true });
    } catch {
      return;
    }
    await this.migrateFlatLayout();

    const sourceDir = this.seedSourceDir;
    if (!sourceDir) return;

    const manifestPath = join(this.skillsDir, SEEDED_MARKER);
    const delivered = await this.readSeededManifest(manifestPath);

    let entries: Array<{ name: string; isDirectory(): boolean }>;
    try {
      entries = await readdir(sourceDir, { withFileTypes: true });
    } catch {
      entries = [];
    }

    let manifestChanged = false;
    for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      if (!entry.isDirectory()) continue;
      const skillName = entry.name;
      if (delivered.has(skillName)) continue;

      const srcSkillMd = join(sourceDir, skillName, SKILL_FILE_NAME);
      try {
        await access(srcSkillMd);
      } catch {
        continue; // not a valid skill dir, ignore
      }

      const dst = join(this.skillsDir, skillName);
      try {
        await stat(dst);
        // User already has a directory under that name (hand-authored or
        // legacy). Record it as delivered so we never overwrite it, but do
        // not copy.
        delivered.add(skillName);
        manifestChanged = true;
        continue;
      } catch {
        // missing \u2014 copy the whole seed directory in
      }
      try {
        await cp(join(sourceDir, skillName), dst, { recursive: true, force: false, errorOnExist: false });
        delivered.add(skillName);
        manifestChanged = true;
      } catch {
        // ignore individual copy failures; we will retry on the next boot.
      }
    }

    if (!manifestChanged && delivered.size > 0) {
      // Even with no new copies, persist a manifest if we migrated from the
      // legacy opaque marker so the next boot is a fast no-op.
      try {
        const raw = await readFile(manifestPath, "utf8");
        if (!isManifestFormat(raw)) manifestChanged = true;
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

  /** Cheap session-start snapshot: { name, description, path } for every
   *  skill in the folder. Used to inject the catalog into the realtime
   *  instructions once at connect time and to refresh via `picky_skills`. */
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
    const doc = docs.find((d) => d.normalizedName === normalized || d.normalizedDirectoryName === normalized);
    if (!doc) throw new Error(`Skill not found: ${request.name}`);
    return {
      name: doc.name,
      description: doc.description,
      path: doc.path,
      frontmatter: doc.frontmatter,
      content: doc.content,
    };
  }

  /** Move any leftover `<name>.md` from the original flat layout into
   *  `<name>/SKILL.md`. Best-effort and idempotent: never overwrites an
   *  existing directory or file. Runs every `ensureSeeded()` so a downgrade
   *  + upgrade cycle still converges. */
  private async migrateFlatLayout(): Promise<void> {
    let entries: Array<{ name: string; isFile(): boolean }>;
    try {
      entries = await readdir(this.skillsDir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (!entry.isFile()) continue;
      if (!entry.name.endsWith(".md")) continue;
      if (entry.name === "README.md") continue;
      if (entry.name.startsWith(".")) continue;
      const skillName = entry.name.slice(0, -3);
      if (!skillName) continue;
      const src = join(this.skillsDir, entry.name);
      const dstDir = join(this.skillsDir, skillName);
      const dstFile = join(dstDir, SKILL_FILE_NAME);
      try {
        await stat(dstFile);
        continue; // already migrated, leave the leftover for the user to clean up
      } catch {
        // dst missing \u2014 OK to migrate
      }
      try {
        // Refuse to migrate if a directory with the same name already exists
        // (could be a manual user setup). Better to leave both alone than to
        // shove a SKILL.md into a directory the user did not expect.
        const existing = await stat(dstDir);
        if (existing.isDirectory()) continue;
      } catch {
        // dstDir does not exist; proceed
      }
      try {
        await mkdir(dstDir, { recursive: true });
        await rename(src, dstFile);
      } catch {
        // rename can fail across filesystems; fall back to copy + unlink.
        try {
          await copyFile(src, dstFile);
        } catch {
          // give up silently on this file
        }
      }
    }
  }

  /** Read the per-skill manifest written by previous `ensureSeeded` runs.
   *  Returns a set of directory names (e.g. "manage-pickles") that the store
   *  has already delivered. Pre-manifest hosts carried an opaque
   *  "seeded at <timestamp>" string \u2014 those are migrated to the set of
   *  first-release seeds so later additions can still flow. The .md suffix
   *  in older manifest entries is stripped for backward compatibility. */
  private async readSeededManifest(path: string): Promise<Set<string>> {
    const delivered = new Set<string>();
    let raw: string;
    try {
      raw = await readFile(path, "utf8");
    } catch {
      return delivered;
    }
    if (!isManifestFormat(raw)) {
      // Legacy opaque marker ("seeded at <iso>"). Assume the user already
      // received the first-release seeds and nothing else; later additions
      // will be delivered as fresh entries.
      for (const legacy of LEGACY_SEEDED_NAMES) delivered.add(legacy);
      return delivered;
    }
    for (const line of raw.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const name = trimmed.endsWith(".md") ? trimmed.slice(0, -3) : trimmed;
      if (name) delivered.add(name);
    }
    return delivered;
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
      if (entry.startsWith(".")) continue;
      if (entry === "README.md") continue;
      const entryPath = join(this.skillsDir, entry);
      let entryStat;
      try {
        entryStat = await stat(entryPath);
      } catch {
        continue;
      }
      if (!entryStat.isDirectory()) continue;

      const skillFile = join(entryPath, SKILL_FILE_NAME);
      let fileStat;
      try {
        fileStat = await stat(skillFile);
      } catch {
        continue;
      }
      if (!fileStat.isFile()) continue;

      const cached = this.cache.get(skillFile);
      if (cached && cached.mtimeMs === fileStat.mtimeMs) {
        next.set(skillFile, cached);
        continue;
      }

      let content: string;
      try {
        content = await readFile(skillFile, "utf8");
      } catch {
        continue;
      }
      const parsed = parseSkillMarkdown(content);
      const directoryName = entry;
      const name = (parsed.frontmatter.name || directoryName).trim();
      const description = (parsed.frontmatter.description || "").trim();
      if (!name) continue;
      next.set(skillFile, {
        name,
        description,
        path: skillFile,
        directoryName,
        frontmatter: parsed.frontmatter,
        content,
        normalizedName: name.toLowerCase(),
        normalizedDirectoryName: directoryName.toLowerCase(),
        searchable: [name, directoryName, description, parsed.body].join("\n").toLowerCase(),
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

/** Locate the bundled seed directory across the runtimes Picky ships with:
 *  `node dist/index.js` from inside `Picky.app/Contents/Resources/agentd`,
 *  `tsx src/index.ts` from a dev checkout, vitest from `src/`, and the
 *  pnpm-deployed runtime under `build/agentd-runtime`. The directory layout
 *  is `<agentd-root>/seeds/picky-skills/<name>/SKILL.md` in every case. */
function defaultSeedSourceDir(): string | null {
  const moduleDir = dirname(fileURLToPath(import.meta.url));
  // Compiled runtime: dist/application/picky-skill-store.js -> agentd root is two levels up.
  // Source runtime:   src/application/picky-skill-store.ts  -> agentd root is two levels up.
  return join(moduleDir, "..", "..", "seeds", "picky-skills");
}

/** True iff the contents look like the per-skill manifest format (one
 *  filename / directory name per line, ignoring comments and blanks).
 *  Used to detect the legacy opaque marker on migration. */
function isManifestFormat(raw: string): boolean {
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    if (trimmed.startsWith("#")) continue;
    // A manifest entry is a simple identifier; the legacy marker is a
    // sentence with spaces ("seeded at 2026-...").
    if (/\s/.test(trimmed)) return false;
    return true;
  }
  return false;
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
    if (name === term || doc.normalizedDirectoryName === term) score += 100;
    if (name.includes(term) || doc.normalizedDirectoryName.includes(term)) score += 40;
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
      const prefix = start > 0 ? "\u2026" : "";
      const suffix = end < doc.content.length ? "\u2026" : "";
      return `${prefix}${doc.content.slice(start, end).replace(/\s+/g, " ").trim()}${suffix}`;
    }
  }
  return undefined;
}

