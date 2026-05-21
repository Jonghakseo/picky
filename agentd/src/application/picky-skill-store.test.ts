import { mkdir, mkdtemp, readFile, readdir, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { PickySkillStore } from "./picky-skill-store.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, "../../..");

async function writeSkillDir(parent: string, name: string, body: string): Promise<void> {
  const dir = join(parent, name);
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, "SKILL.md"), body, "utf8");
}

describe("PickySkillStore", () => {
  it("lists user-authored skills laid out as <name>/SKILL.md", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-skill-store-list-"));
    await writeSkillDir(dir, "summarize-pr", `---\nname: summarize-pr\ndescription: Summarize a PR link\n---\n\nBody.\n`);
    await writeSkillDir(dir, "create-picky-skill", `---\nname: create-picky-skill\ndescription: Author a new Picky skill\n---\n\nBody.\n`);
    await writeFile(join(dir, "README.md"), "ignored", "utf8");
    const store = new PickySkillStore({ skillsDir: dir, seedSourceDir: null });
    const skills = await store.list();
    expect(skills.map((s) => s.name)).toEqual(["create-picky-skill", "summarize-pr"]);
    expect(skills[0].description).toBe("Author a new Picky skill");
    expect(skills[0].path).toBe(join(dir, "create-picky-skill", "SKILL.md"));
  });

  it("falls back to the directory name when frontmatter is missing", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-skill-store-fallback-"));
    await writeSkillDir(dir, "no-frontmatter", `# Title\n\nBody only.\n`);
    const store = new PickySkillStore({ skillsDir: dir, seedSourceDir: null });
    const skills = await store.list();
    expect(skills).toEqual([
      { name: "no-frontmatter", description: "", path: join(dir, "no-frontmatter", "SKILL.md") },
    ]);
  });

  it("ignores directories without a SKILL.md and orphan flat files after migration", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-skill-store-ignores-"));
    await mkdir(join(dir, "incomplete"), { recursive: true });
    await writeFile(join(dir, "incomplete", "notes.md"), "no SKILL.md here", "utf8");
    await writeSkillDir(dir, "valid", `---\nname: valid\ndescription: ok\n---\n`);
    const store = new PickySkillStore({ skillsDir: dir, seedSourceDir: null });
    expect((await store.list()).map((s) => s.name)).toEqual(["valid"]);
  });

  it("returns search results ranked by name/description/directory match", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-skill-store-search-"));
    await writeSkillDir(dir, "summarize-pr", `---\nname: summarize-pr\ndescription: Summarize a GitHub PR link\n---\n\nUse picky_start_pickle for long diffs.\n`);
    await writeSkillDir(dir, "korean-replies", `---\nname: prefer-korean-replies\ndescription: Reply in Korean for casual chitchat\n---\n\nKeep replies short.\n`);
    const store = new PickySkillStore({ skillsDir: dir, seedSourceDir: null });
    const result = await store.search({ query: "pr" });
    expect(result.skills[0].name).toBe("summarize-pr");
    expect(result.skills[0].match).toContain("PR");
    expect(result.total).toBeGreaterThanOrEqual(1);
  });

  it("resolves details by frontmatter name or by directory name", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-skill-store-details-"));
    const body = `---\nname: my-skill\ndescription: Demo skill\n---\n\n# Heading\n\nLine 1\n`;
    await writeSkillDir(dir, "my-skill-dir", body);
    const store = new PickySkillStore({ skillsDir: dir, seedSourceDir: null });
    const byName = await store.details({ name: "my-skill" });
    const byDir = await store.details({ name: "my-skill-dir" });
    expect(byName.content).toBe(body);
    expect(byDir.path).toBe(byName.path);
  });

  it("throws when the requested skill does not exist", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-skill-store-missing-"));
    const store = new PickySkillStore({ skillsDir: dir, seedSourceDir: null });
    await expect(store.details({ name: "does-not-exist" })).rejects.toThrow(/not found/i);
  });

  it("returns an empty list when the directory does not exist", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-skill-store-missing-dir-"));
    const store = new PickySkillStore({ skillsDir: join(root, "skills"), seedSourceDir: null });
    expect(await store.list()).toEqual([]);
  });

  it("documents the seeded create-picky-skill output as <name>/SKILL.md", async () => {
    const body = await readFile(join(REPO_ROOT, "agentd/seeds/picky-skills/create-picky-skill/SKILL.md"), "utf8");
    expect(body).toContain("skills/<name>/SKILL.md");
    expect(body).toContain("Do not use the legacy flat `skills/<name>.md` path");
    expect(body).not.toContain("skills/<name>.md\", content");
  });

  it("copies every seed directory on first run and records them in the manifest", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-skill-store-seed-"));
    const seedDir = join(root, "seeds");
    const targetDir = join(root, "skills");
    await writeSkillDir(seedDir, "create-picky-skill", "create body\n");
    await writeSkillDir(seedDir, "manage-pickles", "manage body\n");
    const store = new PickySkillStore({ skillsDir: targetDir, seedSourceDir: seedDir });
    await store.ensureSeeded();
    expect(await readFile(join(targetDir, "create-picky-skill", "SKILL.md"), "utf8")).toBe("create body\n");
    expect(await readFile(join(targetDir, "manage-pickles", "SKILL.md"), "utf8")).toBe("manage body\n");
    const manifest = await readFile(join(targetDir, ".seeded"), "utf8");
    expect(manifest).toContain("create-picky-skill");
    expect(manifest).toContain("manage-pickles");
  });

  it("copies referenced files alongside SKILL.md", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-skill-store-seed-extras-"));
    const seedDir = join(root, "seeds");
    const targetDir = join(root, "skills");
    await mkdir(join(seedDir, "with-extras"), { recursive: true });
    await writeFile(join(seedDir, "with-extras", "SKILL.md"), "body\n", "utf8");
    await writeFile(join(seedDir, "with-extras", "example.json"), `{"k":"v"}\n`, "utf8");
    const store = new PickySkillStore({ skillsDir: targetDir, seedSourceDir: seedDir });
    await store.ensureSeeded();
    expect(await readFile(join(targetDir, "with-extras", "example.json"), "utf8")).toBe(`{"k":"v"}\n`);
  });

  it("does not overwrite an existing user directory and records it in the manifest", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-skill-store-noseedreplace-"));
    const seedDir = join(root, "seeds");
    const targetDir = join(root, "skills");
    await writeSkillDir(seedDir, "create-picky-skill", "seed body\n");
    await writeSkillDir(targetDir, "create-picky-skill", "user body\n");
    const store = new PickySkillStore({ skillsDir: targetDir, seedSourceDir: seedDir });
    await store.ensureSeeded();
    expect(await readFile(join(targetDir, "create-picky-skill", "SKILL.md"), "utf8")).toBe("user body\n");
    expect(await readFile(join(targetDir, ".seeded"), "utf8")).toContain("create-picky-skill");
  });

  it("does not re-create seeds the user has intentionally deleted", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-skill-store-deleted-"));
    const seedDir = join(root, "seeds");
    const targetDir = join(root, "skills");
    await mkdir(targetDir, { recursive: true });
    await writeFile(join(targetDir, ".seeded"), "# header\ncreate-picky-skill\n", "utf8");
    await writeSkillDir(seedDir, "create-picky-skill", "seed body\n");
    const store = new PickySkillStore({ skillsDir: targetDir, seedSourceDir: seedDir });
    await store.ensureSeeded();
    await expect(stat(join(targetDir, "create-picky-skill"))).rejects.toThrow();
  });

  it("delivers newly added seeds on subsequent boots", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-skill-store-add-"));
    const seedDir = join(root, "seeds");
    const targetDir = join(root, "skills");
    await writeSkillDir(seedDir, "create-picky-skill", "create body\n");
    const store = new PickySkillStore({ skillsDir: targetDir, seedSourceDir: seedDir });
    await store.ensureSeeded();
    await writeSkillDir(seedDir, "manage-pickles", "manage body\n");
    await store.ensureSeeded();
    expect(await readFile(join(targetDir, "manage-pickles", "SKILL.md"), "utf8")).toBe("manage body\n");
    expect(await readFile(join(targetDir, ".seeded"), "utf8")).toContain("manage-pickles");
  });

  it("migrates the legacy opaque marker by treating create-picky-skill as already delivered", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-skill-store-legacy-marker-"));
    const seedDir = join(root, "seeds");
    const targetDir = join(root, "skills");
    await mkdir(targetDir, { recursive: true });
    await writeFile(join(targetDir, ".seeded"), "seeded at 2026-05-19T00:00:00.000Z\n", "utf8");
    await writeSkillDir(seedDir, "create-picky-skill", "create body\n");
    await writeSkillDir(seedDir, "manage-pickles", "manage body\n");
    const store = new PickySkillStore({ skillsDir: targetDir, seedSourceDir: seedDir });
    await store.ensureSeeded();
    await expect(stat(join(targetDir, "create-picky-skill"))).rejects.toThrow();
    expect(await readFile(join(targetDir, "manage-pickles", "SKILL.md"), "utf8")).toBe("manage body\n");
    const manifest = await readFile(join(targetDir, ".seeded"), "utf8");
    expect(manifest).toContain("create-picky-skill");
    expect(manifest).toContain("manage-pickles");
  });

  it("migrates leftover flat <name>.md files into <name>/SKILL.md", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-skill-store-flat-migrate-"));
    const targetDir = join(root, "skills");
    await mkdir(targetDir, { recursive: true });
    await writeFile(join(targetDir, "user-authored.md"), "user body\n", "utf8");
    const store = new PickySkillStore({ skillsDir: targetDir, seedSourceDir: null });
    await store.ensureSeeded();
    expect(await readFile(join(targetDir, "user-authored", "SKILL.md"), "utf8")).toBe("user body\n");
    // The original flat file is gone.
    const after = await readdir(targetDir);
    expect(after).not.toContain("user-authored.md");
  });

  it("does not migrate a flat file when a directory of the same name already holds a SKILL.md", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-skill-store-flat-conflict-"));
    const targetDir = join(root, "skills");
    await writeSkillDir(targetDir, "duplicate", "directory body\n");
    await writeFile(join(targetDir, "duplicate.md"), "flat body\n", "utf8");
    const store = new PickySkillStore({ skillsDir: targetDir, seedSourceDir: null });
    await store.ensureSeeded();
    // Directory contents are untouched.
    expect(await readFile(join(targetDir, "duplicate", "SKILL.md"), "utf8")).toBe("directory body\n");
    // Flat leftover stays in place for the user to clean up manually.
    expect(await readFile(join(targetDir, "duplicate.md"), "utf8")).toBe("flat body\n");
  });
});
