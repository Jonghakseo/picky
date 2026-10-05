import { mkdtemp, mkdir, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { PickyAgentSession } from "../protocol.js";
import { describeFile, resolveReferencedFile, resolveSessionPath } from "./file-service.js";
import { rm } from "node:fs/promises";

let root: string;
let home: string;

beforeAll(async () => {
  root = await mkdtemp(join(tmpdir(), "picky-files-"));
  home = join(root, "home");
  await mkdir(join(root, "cwd", "docs"), { recursive: true });
  await mkdir(home, { recursive: true });
  await writeFile(join(root, "cwd", "docs", "plan.md"), "# plan\nbody");
  await writeFile(join(root, "cwd", "secret.txt"), "not referenced");
  await writeFile(join(root, "outside.txt"), "outside the cwd");
  await writeFile(join(home, "note.md"), "home note");
  await symlink(join(root, "outside.txt"), join(root, "cwd", "escape.txt"));
});

afterAll(async () => {
  await rm(root, { recursive: true, force: true });
});

function session(text: string): PickyAgentSession {
  return {
    id: "s1",
    title: "demo",
    status: "running",
    cwd: join(root, "cwd"),
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00Z",
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
    messages: [{ id: "m1", kind: "agent_text", createdAt: "2026-01-01T00:00:00Z", text }],
  } as PickyAgentSession;
}

describe("path resolution mirrors the HUD link handler", () => {
  it("expands ~, joins relative paths onto cwd and standardizes", () => {
    expect(resolveSessionPath("~/note.md", "/work", home)).toBe(join(home, "note.md"));
    expect(resolveSessionPath("docs/../docs/plan.md", "/work", home)).toBe("/work/docs/plan.md");
    expect(resolveSessionPath("/abs/path", undefined, home)).toBe("/abs/path");
    expect(resolveSessionPath("relative.md", undefined, home)).toBeUndefined();
  });
});

describe("only referenced files are readable", () => {
  it("allows a file the conversation linked", async () => {
    const result = await resolveReferencedFile("docs/plan.md", { session: session("see [plan](docs/plan.md)"), home });
    expect(result).toEqual({ ok: true, path: join(root, "cwd", "docs", "plan.md") });
  });

  it("rejects a sibling file the conversation never mentioned", async () => {
    const result = await resolveReferencedFile("secret.txt", { session: session("see [plan](docs/plan.md)"), home });
    expect(result).toEqual({ ok: false, reason: "notReferenced" });
  });

  it("rejects `..` traversal out of the working directory", async () => {
    const result = await resolveReferencedFile("../outside.txt", { session: session("see [plan](docs/plan.md)"), home });
    expect(result).toEqual({ ok: false, reason: "notReferenced" });
  });

  it("rejects a symlink inside cwd that escapes to an unreferenced file", async () => {
    const result = await resolveReferencedFile("escape.txt", { session: session("see [plan](docs/plan.md)"), home });
    expect(result).toEqual({ ok: false, reason: "notReferenced" });
  });

  it("resolves a referenced symlink to its target, so both names open the same file", async () => {
    const result = await resolveReferencedFile("escape.txt", { session: session("see [escape](escape.txt)"), home });
    expect(result).toEqual({ ok: true, path: join(root, "outside.txt") });
  });

  it("reports a missing file instead of leaking whether it is referenced", async () => {
    const result = await resolveReferencedFile("docs/gone.md", { session: session("see [gone](docs/gone.md)"), home });
    expect(result).toEqual({ ok: false, reason: "missing" });
  });
});

describe("file description", () => {
  it("classifies markdown and returns its text", async () => {
    const description = await describeFile(join(root, "cwd", "docs", "plan.md"));
    expect(description.kind).toBe("markdown");
    expect(description.name).toBe("plan.md");
    expect(description.text).toContain("# plan");
    expect(description.truncated).toBe(false);
  });

  it("classifies a PNG by its magic bytes, not its name", async () => {
    const png = join(root, "cwd", "not-an-image.txt");
    await writeFile(png, Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00]));
    expect((await describeFile(png)).kind).toBe("image");
  });
});
