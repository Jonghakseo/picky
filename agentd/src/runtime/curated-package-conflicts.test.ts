import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { WebSocket } from "ws";
import { PackageOperations, type PackageManager } from "./package-operations.js";

const WEB_ACCESS = "npm:@ryan_nookpi/pi-extension-web-access";
const EXCALIDRAW = "npm:@ryan_nookpi/pi-skill-excalidraw";

let root: string;
let agentDir: string;
let cwd: string;

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), "picky-curated-conflicts-"));
  agentDir = join(root, "agent");
  cwd = join(root, "work");
  await mkdir(cwd, { recursive: true });
  await mkdir(agentDir, { recursive: true });
});

afterEach(async () => {
  await rm(root, { recursive: true, force: true });
});

async function writeLocalExtension(name: string, source: string): Promise<string> {
  const dir = join(agentDir, "extensions", name);
  await mkdir(dir, { recursive: true });
  // Real local extension folders share a parent package.json; the scan must not attribute siblings to each other.
  await writeFile(join(agentDir, "extensions", "package.json"), JSON.stringify({ name: "local-extensions", private: true }));
  await writeFile(join(dir, "index.ts"), source);
  return dir;
}

async function writeLocalSkill(name: string): Promise<string> {
  const dir = join(agentDir, "skills", name);
  await mkdir(dir, { recursive: true });
  const file = join(dir, "SKILL.md");
  await writeFile(file, `---\nname: ${name}\ndescription: local copy\n---\n\nbody\n`);
  return file;
}

async function installNpmPackage(source: string, manifest: Record<string, unknown>, files: Record<string, string>): Promise<void> {
  const name = source.replace(/^npm:/, "");
  const dir = join(agentDir, "npm", "node_modules", ...name.split("/"));
  for (const [relative, content] of Object.entries(files)) {
    await mkdir(join(dir, relative, ".."), { recursive: true });
    await writeFile(join(dir, relative), content);
  }
  await writeFile(join(dir, "package.json"), JSON.stringify({ name, version: "0.1.0", ...manifest }));
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ packages: [source] }));
}

function subject() {
  const events: Array<Record<string, unknown>> = [];
  const manager: PackageManager = {
    installAndPersist: vi.fn(async () => {}),
    removeAndPersist: vi.fn(async () => true),
    checkAvailableUpdates: vi.fn(async () => []),
    update: vi.fn(async () => {}),
    setProgressCallback: vi.fn(),
    flush: vi.fn(async () => {}),
  };
  const operations = new PackageOperations({
    createPackageManager: () => manager,
    getAgentDir: () => agentDir,
    getCwd: () => cwd,
    send: (_ws, event) => events.push(event),
  });
  operations.start();
  return { operations, events, manager };
}

describe("curated package duplicate protection", () => {
  it("blocks installing a package whose tool or skill another local source already provides", async () => {
    const extensionDir = await writeLocalExtension("web-access", `pi.registerTool({ name: "web_search", execute() {} });`);
    const skillFile = await writeLocalSkill("excalidraw");
    const { operations, events, manager } = subject();
    await operations.runOperation({} as WebSocket, "install-web", "install", WEB_ACCESS);
    await operations.runOperation({} as WebSocket, "install-excal", "install", EXCALIDRAW);

    expect(manager.installAndPersist).not.toHaveBeenCalled();
    const web = events.find((event) => event.requestId === "install-web");
    expect(web).toMatchObject({ type: "packageOperationCompleted", ok: false, packageChanged: false });
    expect(web?.errorMessage).toContain(extensionDir);
    expect(events.find((event) => event.requestId === "install-excal")?.errorMessage).toContain(skillFile);

    await operations.runConflictInspection({} as WebSocket, "inspect", [WEB_ACCESS, EXCALIDRAW, "npm:@example/unrelated"]);
    expect(events.at(-1)).toEqual({
      type: "packageConflicts",
      commandId: "inspect",
      conflicts: [
        { source: WEB_ACCESS, kind: "tool", name: "web_search", ownerPath: extensionDir },
        { source: EXCALIDRAW, kind: "skill", name: "excalidraw", ownerPath: skillFile },
      ],
    });
  });

  it("ignores unrelated extensions and does not treat the installed package as its own conflict", async () => {
    await writeLocalExtension("notes", `// mentions web_search in prose only\npi.registerTool({ name: "take_note", execute() {} });`);
    await installNpmPackage(WEB_ACCESS, { pi: { extensions: ["./index.ts"] } }, {
      "index.ts": `import "./tool.ts";`,
      "tool.ts": `pi.registerTool({ name: "web_search", execute() {} });`,
    });
    const { operations, events, manager } = subject();
    await operations.runConflictInspection({} as WebSocket, "inspect", [WEB_ACCESS]);
    expect(events.at(-1)).toEqual({ type: "packageConflicts", commandId: "inspect", conflicts: [] });

    await operations.runOperation({} as WebSocket, "reinstall", "install", WEB_ACCESS);
    expect(manager.installAndPersist).toHaveBeenCalledWith(WEB_ACCESS);
  });

  it("reports a later local copy that shadows an installed skill package", async () => {
    await installNpmPackage(EXCALIDRAW, { pi: { skills: ["./skills/excalidraw"] } }, {
      "skills/excalidraw/SKILL.md": "---\nname: excalidraw\ndescription: packaged\n---\n",
    });
    const localSkill = await writeLocalSkill("excalidraw");
    const { operations, events } = subject();
    await operations.runConflictInspection({} as WebSocket, "inspect", [EXCALIDRAW]);
    expect(events.at(-1)).toEqual({
      type: "packageConflicts",
      commandId: "inspect",
      conflicts: [{ source: EXCALIDRAW, kind: "skill", name: "excalidraw", ownerPath: localSkill }],
    });
  });

  it("fails closed when the duplicate check itself fails", async () => {
    const events: Array<Record<string, unknown>> = [];
    const installAndPersist = vi.fn(async () => {});
    const operations = new PackageOperations({
      createPackageManager: () => ({ installAndPersist, removeAndPersist: vi.fn(), checkAvailableUpdates: vi.fn(), update: vi.fn(), setProgressCallback: vi.fn() }),
      getAgentDir: () => agentDir,
      inspectConflicts: async () => { throw new Error("settings unreadable"); },
      send: (_ws, event) => events.push(event),
    });
    operations.start();
    await operations.runOperation({} as WebSocket, "install", "install", WEB_ACCESS);
    expect(installAndPersist).not.toHaveBeenCalled();
    expect(events.at(-1)).toMatchObject({ ok: false, packageChanged: false, errorMessage: expect.stringContaining("settings unreadable") });
  });
});
