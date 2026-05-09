import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { PickySkillCatalog } from "./skill-catalog.js";

describe("PickySkillCatalog", () => {
  it("searches local SKILL.md frontmatter and content", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-skills-"));
    await writeSkill(root, "systematic-debugging", `---
name: systematic-debugging
description: 버그와 테스트 실패의 근본원인을 찾는다
---
# systematic-debugging

Use this for crash logs and unexpected behavior.
`);
    await writeSkill(root, "ship", `---
name: ship
description: 변경사항 검증과 push
---
# ship
`);

    const catalog = new PickySkillCatalog(root);
    const result = await catalog.search({ query: "crash", limit: 5 });

    expect(result.root).toBe(root);
    expect(result.total).toBe(1);
    expect(result.skills[0]).toMatchObject({
      name: "systematic-debugging",
      description: "버그와 테스트 실패의 근본원인을 찾는다",
    });
    expect(result.skills[0].path).toContain("systematic-debugging/SKILL.md");
    expect(result.skills[0].match).toContain("crash logs");
  });

  it("returns full skill details by name or skill-prefixed name", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-skills-"));
    await writeSkill(root, "context7-cli", `---
name: context7-cli
description: Look up library docs
---
# context7-cli

Use ctx7 from bash.
`);

    const catalog = new PickySkillCatalog(root);
    const details = await catalog.details({ name: "skill:context7-cli" });

    expect(details.name).toBe("context7-cli");
    expect(details.frontmatter.description).toBe("Look up library docs");
    expect(details.content).toContain("Use ctx7 from bash.");
  });
});

async function writeSkill(root: string, name: string, content: string): Promise<void> {
  const directory = join(root, name);
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, "SKILL.md"), content, "utf8");
}
