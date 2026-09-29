import { existsSync, lstatSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, extname, join, relative, resolve, sep } from "node:path";
import { DefaultPackageManager, parseFrontmatter, SettingsManager, type ResolvedResource } from "@earendil-works/pi-coding-agent";
import { curatedPackageResources, npmPackageName, type CuratedConflictRemoval, type CuratedPackageConflict } from "../domain/curated-package-resources.js";

export interface CuratedConflictInspectionInput {
  cwd: string;
  agentDir: string;
  sources: readonly string[];
  /** Home used for `~/.agents/skills`; defaults to the process home. */
  homeDir?: string;
}

type ResolvedPiResources = { extensions: ResolvedResource[]; skills: ResolvedResource[] };

export interface CuratedConflictInspectorDependencies {
  /** Resolves what Pi would load without installing missing packages or running extension code. */
  resolveResources?: (cwd: string, agentDir: string) => Promise<ResolvedPiResources>;
}

const SOURCE_EXTENSIONS = new Set([".ts", ".mts", ".cts", ".js", ".mjs", ".cjs"]);
const MAX_SCANNED_FILES = 400;
const MAX_SCANNED_BYTES = 2 * 1024 * 1024;

/**
 * Finds other sources of the tools and skills that curated packages provide.
 * The check is static on purpose: executing every user extension just to read
 * its tool names would run their side effects inside the daemon. Tool owners
 * are therefore detected by a `name: "<tool>"` registration in their source.
 */
export async function inspectCuratedPackageConflicts(
  input: CuratedConflictInspectionInput,
  dependencies: CuratedConflictInspectorDependencies = {},
): Promise<CuratedPackageConflict[]> {
  const targets = input.sources.flatMap((source) => {
    const resources = curatedPackageResources(source);
    const packageName = npmPackageName(source);
    return resources && packageName ? [{ source, packageName, resources }] : [];
  });
  if (targets.length === 0) return [];

  const resolved = await (dependencies.resolveResources ?? resolvePiResources)(input.cwd, input.agentDir);
  const conflicts: CuratedPackageConflict[] = [];
  const seen = new Set<string>();
  const add = (conflict: CuratedPackageConflict) => {
    const key = `${conflict.source}\0${conflict.kind}\0${conflict.name}\0${conflict.ownerPath}`;
    if (seen.has(key)) return;
    seen.add(key);
    conflicts.push(conflict);
  };

  const roots = removableRoots(input);
  const skillOwners = collectSkillOwners(resolved.skills);
  const toolScanCache = new Map<string, string[]>();
  for (const target of targets) {
    const ownedBy = (resource: ResolvedResource) =>
      resource.metadata.origin === "package" && npmPackageName(resource.metadata.source) === target.packageName;

    for (const skill of target.resources.skills) {
      for (const owner of skillOwners.get(skill) ?? []) {
        if (ownedBy(owner.resource)) continue;
        add({ source: target.source, kind: "skill", name: skill, ownerPath: owner.filePath, removal: skillRemoval(owner.resource, owner.filePath, roots) });
      }
    }

    if (target.resources.tools.length === 0) continue;
    for (const extension of resolved.extensions) {
      if (!extension.enabled || ownedBy(extension)) continue;
      const root = extensionScanRoot(extension.path, input.agentDir);
      let texts = toolScanCache.get(root);
      if (!texts) {
        texts = readSourceTexts(root);
        toolScanCache.set(root, texts);
      }
      for (const tool of target.resources.tools) {
        if (texts.some((text) => registersTool(text, tool))) {
          add({ source: target.source, kind: "tool", name: tool, ownerPath: root, removal: extensionRemoval(extension, root, roots) });
        }
      }
    }
  }
  return conflicts;
}

interface RemovableRoots {
  skills: Set<string>;
  extensions: Set<string>;
}

function removableRoots(input: CuratedConflictInspectionInput): RemovableRoots {
  const home = input.homeDir ?? homedir();
  return {
    skills: new Set([join(input.agentDir, "skills"), join(home, ".agents", "skills"), join(input.cwd, ".pi", "skills"), join(input.cwd, ".agents", "skills")].map((path) => resolve(path))),
    extensions: new Set([join(input.agentDir, "extensions"), join(input.cwd, ".pi", "extensions")].map((path) => resolve(path))),
  };
}

function packageRemoval(resource: ResolvedResource): CuratedConflictRemoval | undefined {
  if (resource.metadata.origin !== "package") return undefined;
  // Project packages belong to the repository's settings; leave that decision to the user.
  return resource.metadata.scope === "user" ? { kind: "package", source: resource.metadata.source } : { kind: "manual" };
}

/** Only auto-discovered entries sit directly under a root; trashing them leaves no dangling settings path. */
function trashRemoval(resource: ResolvedResource, target: string, roots: Set<string>): CuratedConflictRemoval {
  const path = resolve(target);
  return resource.metadata.source === "auto" && roots.has(dirname(path)) ? { kind: "trash", path } : { kind: "manual" };
}

function skillRemoval(resource: ResolvedResource, filePath: string, roots: RemovableRoots): CuratedConflictRemoval {
  return packageRemoval(resource)
    ?? trashRemoval(resource, basename(filePath) === "SKILL.md" ? dirname(filePath) : filePath, roots.skills);
}

function extensionRemoval(resource: ResolvedResource, scanRoot: string, roots: RemovableRoots): CuratedConflictRemoval {
  return packageRemoval(resource) ?? trashRemoval(resource, scanRoot, roots.extensions);
}

async function resolvePiResources(cwd: string, agentDir: string): Promise<ResolvedPiResources> {
  const settingsManager = SettingsManager.create(cwd, agentDir);
  const resolved = await new DefaultPackageManager({ cwd, agentDir, settingsManager }).resolve(async () => "skip");
  return { extensions: resolved.extensions, skills: resolved.skills };
}

function collectSkillOwners(skills: readonly ResolvedResource[]): Map<string, Array<{ resource: ResolvedResource; filePath: string }>> {
  const owners = new Map<string, Array<{ resource: ResolvedResource; filePath: string }>>();
  for (const resource of skills) {
    if (!resource.enabled) continue;
    const filePath = extname(resource.path) === ".md" ? resource.path : join(resource.path, "SKILL.md");
    const name = skillName(filePath);
    if (!name) continue;
    owners.set(name, [...(owners.get(name) ?? []), { resource, filePath }]);
  }
  return owners;
}

function skillName(filePath: string): string | undefined {
  try {
    const { frontmatter } = parseFrontmatter(readFileSync(filePath, "utf8"));
    if (typeof frontmatter.name === "string" && frontmatter.name.trim()) return frontmatter.name.trim();
  } catch {
    return undefined;
  }
  return basename(filePath) === "SKILL.md" ? basename(dirname(filePath)) : basename(filePath, ".md");
}

/**
 * Local extensions under `<agentDir>/extensions/<name>` share a parent
 * package.json, so the scan stops at the extension's own directory there.
 * Package extensions scan their package root, which holds every tool module.
 */
function extensionScanRoot(entryPath: string, agentDir: string): string {
  const extensionsDir = resolve(agentDir, "extensions");
  const entry = resolve(entryPath);
  const fromExtensions = relative(extensionsDir, entry);
  if (fromExtensions && !fromExtensions.startsWith("..") && !fromExtensions.startsWith(sep)) {
    const [first] = fromExtensions.split(sep);
    return first === fromExtensions ? entry : join(extensionsDir, first!);
  }
  let dir = dirname(entry);
  for (let depth = 0; depth < 5; depth++) {
    if (existsSync(join(dir, "package.json"))) return dir;
    const parent = dirname(dir);
    if (parent === dir || basename(parent) === "node_modules") break;
    dir = parent;
  }
  return dirname(entry);
}

function readSourceTexts(root: string): string[] {
  const texts: string[] = [];
  let realRoot: string;
  try {
    realRoot = realpathSync(root);
  } catch {
    return texts;
  }
  const pending = [realRoot];
  let scanned = 0;
  while (pending.length > 0 && scanned < MAX_SCANNED_FILES) {
    const current = pending.pop()!;
    let stats;
    try {
      stats = statSync(current);
    } catch {
      continue;
    }
    if (stats.isFile()) {
      if (!SOURCE_EXTENSIONS.has(extname(current)) || /\.test\.[cm]?[jt]s$/.test(current) || stats.size > MAX_SCANNED_BYTES) continue;
      scanned += 1;
      try {
        texts.push(readFileSync(current, "utf8"));
      } catch {
        // Unreadable files cannot register tools Pi could load either.
      }
      continue;
    }
    if (!stats.isDirectory()) continue;
    let entries: string[];
    try {
      entries = readdirSync(current);
    } catch {
      continue;
    }
    for (const name of entries) {
      if (name === "node_modules" || name.startsWith(".")) continue;
      const child = join(current, name);
      // Following nested symlinks could loop or leave the extension's own tree.
      if (lstatSync(child, { throwIfNoEntry: false })?.isSymbolicLink()) continue;
      pending.push(child);
    }
  }
  return texts;
}

function registersTool(text: string, tool: string): boolean {
  const escaped = tool.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`\\bname\\s*:\\s*["'\`]${escaped}["'\`]`).test(text);
}
