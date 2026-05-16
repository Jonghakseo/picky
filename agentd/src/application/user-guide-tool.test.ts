import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { createReadPickyUserGuideTool, PICKY_USER_GUIDE_SECTIONS, readPickyUserGuide } from "./user-guide-tool.js";

const GUIDE = `# Picky User Manual

Intro.

## 1. First launch and prerequisites

Setup details.

### Permission notes

Speech details.

## 2. Menu bar companion panel

Panel details.

## 3. Global shortcuts

Shortcut details.
`;

describe("readPickyUserGuide", () => {
  it("reads a top-level section by exact title", async () => {
    const guidePath = await writeTempGuide(GUIDE);

    const result = await readPickyUserGuide(
      { section: "1. First launch and prerequisites", query: "permissions" },
      { env: { PICKY_USER_GUIDE_PATH: guidePath } as NodeJS.ProcessEnv },
    );

    expect(result.section).toBe("1. First launch and prerequisites");
    expect(result.query).toBe("permissions");
    expect(result.content).toContain("## 1. First launch and prerequisites");
    expect(result.content).toContain("### Permission notes");
    expect(result.content).not.toContain("## 2. Menu bar companion panel");
    expect(result.excerpted).toBe(true);
  });

  it("reads a top-level section by number", async () => {
    const guidePath = await writeTempGuide(GUIDE);

    const result = await readPickyUserGuide(
      { section: "2" },
      { env: { PICKY_USER_GUIDE_PATH: guidePath } as NodeJS.ProcessEnv },
    );

    expect(result.section).toBe("2. Menu bar companion panel");
    expect(result.content).toContain("Panel details");
    expect(result.content).not.toContain("Shortcut details");
  });

  it("lists available sections in the tool description", () => {
    const tool = createReadPickyUserGuideTool();

    expect(tool.description).toContain(PICKY_USER_GUIDE_SECTIONS[0]);
    expect(tool.description).toContain(PICKY_USER_GUIDE_SECTIONS.at(-1));
  });
});

async function writeTempGuide(content: string): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "picky-guide-"));
  const path = join(dir, "user-manual.md");
  await writeFile(path, content, "utf8");
  return path;
}
