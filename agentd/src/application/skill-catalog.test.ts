import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { PickySkillCatalog } from "./skill-catalog.js";

describe("PickySkillCatalog", () => {
  it("searches global and cwd-scoped Pi skills with Pi discovery rules", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-skills-"));
    const agentDir = join(root, "agent");
    const repo = join(root, "repo");
    const cwd = join(repo, "packages", "app");
    await mkdir(join(repo, ".git"), { recursive: true });
    await mkdir(cwd, { recursive: true });

    await writeSkill(join(agentDir, "skills"), "global-debugging", `---
name: global-debugging
description: Global debugging skill
---
# global-debugging

Use this for global crash logs.
`);
    await writeSkill(join(cwd, ".pi", "skills"), "cwd-debugging", `---
name: cwd-debugging
description: CWD debugging skill
---
# cwd-debugging

Use this for cwd crash logs.
`);
    await writeSkill(join(repo, ".agents", "skills"), "ancestor-debugging", `---
name: ancestor-debugging
description: Ancestor debugging skill
---
# ancestor-debugging

Use this for ancestor crash logs.
`);

    const catalog = new PickySkillCatalog({ agentDir });
    const result = await catalog.search({ cwd, query: "crash", limit: 10 });

    expect(result.root).toBe(cwd);
    expect(result.skills.map((skill) => skill.name)).toEqual(expect.arrayContaining([
      "global-debugging",
      "cwd-debugging",
      "ancestor-debugging",
    ]));
  });

  it("returns full skill details by name or skill-prefixed name for the request cwd", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-skills-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "repo");
    await mkdir(cwd, { recursive: true });
    await writeSkill(join(cwd, ".pi", "skills"), "context7-cli", `---
name: context7-cli
description: Look up library docs
---
# context7-cli

Use ctx7 from bash.
`);

    const catalog = new PickySkillCatalog({ agentDir });
    const details = await catalog.details({ cwd, name: "skill:context7-cli" });

    expect(details.name).toBe("context7-cli");
    expect(details.frontmatter.description).toBe("Look up library docs");
    expect(details.content).toContain("Use ctx7 from bash.");
  });
});

async function writeSkill(skillsRoot: string, name: string, content: string): Promise<void> {
  const directory = join(skillsRoot, name);
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, "SKILL.md"), content, "utf8");
}
