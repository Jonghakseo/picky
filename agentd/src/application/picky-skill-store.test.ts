import { mkdir, mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { PickySkillStore } from "./picky-skill-store.js";

describe("PickySkillStore", () => {
  it("lists user-authored Picky skills from the configured directory", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-skill-store-list-"));
    await writeFile(
      join(dir, "summarize-pr.md"),
      `---\nname: summarize-pr\ndescription: Summarize a PR link\n---\n\nDo summarization.\n`,
      "utf8",
    );
    await writeFile(
      join(dir, "create-picky-skill.md"),
      `---\nname: create-picky-skill\ndescription: Author a new Picky skill\n---\n\nFollow template.\n`,
      "utf8",
    );
    await writeFile(join(dir, "README.md"), "ignored", "utf8");
    const store = new PickySkillStore({ skillsDir: dir, seedSourceDir: null });
    const skills = await store.list();
    expect(skills.map((s) => s.name)).toEqual(["create-picky-skill", "summarize-pr"]);
    expect(skills[0].description).toBe("Author a new Picky skill");
  });

  it("falls back to the filename when frontmatter is missing", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-skill-store-fallback-"));
    await writeFile(join(dir, "no-frontmatter.md"), `# Title\n\nBody only.\n`, "utf8");
    const store = new PickySkillStore({ skillsDir: dir, seedSourceDir: null });
    const skills = await store.list();
    expect(skills).toEqual([{ name: "no-frontmatter", description: "", path: join(dir, "no-frontmatter.md") }]);
  });

  it("returns search results ranked by name/description match with snippets", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-skill-store-search-"));
    await writeFile(
      join(dir, "summarize-pr.md"),
      `---\nname: summarize-pr\ndescription: Summarize a GitHub PR link\n---\n\nUse picky_start_pickle for long diffs.\n`,
      "utf8",
    );
    await writeFile(
      join(dir, "korean-replies.md"),
      `---\nname: prefer-korean-replies\ndescription: Reply in Korean for casual Picky chitchat\n---\n\nKeep replies short.\n`,
      "utf8",
    );
    const store = new PickySkillStore({ skillsDir: dir, seedSourceDir: null });
    const result = await store.search({ query: "pr" });
    expect(result.skills[0].name).toBe("summarize-pr");
    expect(result.skills[0].match).toContain("PR");
    expect(result.total).toBeGreaterThanOrEqual(1);
  });

  it("returns full content via details(name)", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-skill-store-details-"));
    const body = `---\nname: my-skill\ndescription: Demo skill\n---\n\n# Heading\n\nLine 1\nLine 2\n`;
    await writeFile(join(dir, "my-skill.md"), body, "utf8");
    const store = new PickySkillStore({ skillsDir: dir, seedSourceDir: null });
    const details = await store.details({ name: "my-skill" });
    expect(details.name).toBe("my-skill");
    expect(details.content).toBe(body);
    expect(details.frontmatter).toEqual({ name: "my-skill", description: "Demo skill" });
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

  it("copies seed templates on first run and writes a .seeded marker", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-skill-store-seed-"));
    const seedDir = join(root, "seeds");
    const targetDir = join(root, "skills");
    await mkdir(seedDir, { recursive: true });
    await writeFile(
      join(seedDir, "create-picky-skill.md"),
      `---\nname: create-picky-skill\ndescription: Seed skill\n---\n\nBody.\n`,
      "utf8",
    );
    const store = new PickySkillStore({ skillsDir: targetDir, seedSourceDir: seedDir });
    await store.ensureSeeded();
    const seeded = await readFile(join(targetDir, "create-picky-skill.md"), "utf8");
    expect(seeded).toContain("Seed skill");
    const marker = await stat(join(targetDir, ".seeded"));
    expect(marker.isFile()).toBe(true);
  });

  it("does not overwrite existing user files on subsequent boots", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-skill-store-noseedreplace-"));
    const seedDir = join(root, "seeds");
    const targetDir = join(root, "skills");
    await mkdir(seedDir, { recursive: true });
    await mkdir(targetDir, { recursive: true });
    await writeFile(join(seedDir, "create-picky-skill.md"), "seed body\n", "utf8");
    await writeFile(join(targetDir, "create-picky-skill.md"), "user body\n", "utf8");
    const store = new PickySkillStore({ skillsDir: targetDir, seedSourceDir: seedDir });
    await store.ensureSeeded();
    expect(await readFile(join(targetDir, "create-picky-skill.md"), "utf8")).toBe("user body\n");
  });

  it("does not re-seed once the .seeded marker is present", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-skill-store-marker-"));
    const seedDir = join(root, "seeds");
    const targetDir = join(root, "skills");
    await mkdir(seedDir, { recursive: true });
    await mkdir(targetDir, { recursive: true });
    await writeFile(join(targetDir, ".seeded"), "", "utf8");
    await writeFile(join(seedDir, "create-picky-skill.md"), "seed body\n", "utf8");
    const store = new PickySkillStore({ skillsDir: targetDir, seedSourceDir: seedDir });
    await store.ensureSeeded();
    await expect(stat(join(targetDir, "create-picky-skill.md"))).rejects.toThrow();
  });
});
