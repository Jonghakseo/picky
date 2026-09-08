import { createHash } from "node:crypto";
import type * as FileSystem from "node:fs/promises";
import { mkdir, mkdtemp, readFile, readdir, rm, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { PickyAgentSessionSchema } from "../protocol.js";
import { HubStatisticsService, parsePiUsageJsonl } from "./hub-statistics-service.js";

vi.mock("node:fs/promises", async (importOriginal) => {
  const fs = await importOriginal<typeof FileSystem>();
  return { ...fs, readFile: vi.fn(fs.readFile), unlink: vi.fn(fs.unlink) };
});

function session(id: string, revision: number, overrides: Record<string, unknown> = {}) {
  return PickyAgentSessionSchema.parse({
    id,
    revision,
    title: `Task ${id}`,
    status: "completed",
    cwd: "/work/picky",
    createdAt: "2026-09-01T00:00:00.000Z",
    updatedAt: "2026-09-02T00:00:00.000Z",
    ...overrides,
  });
}

function assistantEntry(id: string, overrides: Record<string, unknown> = {}) {
  return {
    type: "message",
    id,
    timestamp: "2026-09-02T12:00:00.000Z",
    message: {
      role: "assistant",
      provider: "anthropic",
      model: "claude",
      usage: { input: 10, output: 20, reasoning: 3, cacheRead: 4, cacheWrite: 5 },
      ...overrides,
    },
  };
}

describe("HubStatisticsService", () => {
  it("scans flat and child session metadata, prefers the highest revision, and reads Pi assistant usage entries", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-hub-statistics-"));
    const sessions = join(root, "sessions");
    const piFile = join(root, "pickle.jsonl");
    const mainPiFile = join(root, "main.jsonl");
    await mkdir(join(sessions, "pickle-1"), { recursive: true });
    await writeFile(join(sessions, "pickle-1.json"), JSON.stringify(session("pickle-1", 1, { title: "Older", piSessionFilePath: piFile })));
    await writeFile(join(sessions, "pickle-1", "pickle-1.json"), JSON.stringify(session("pickle-1", 2, { title: "Newest", piSessionFilePath: piFile })));
    await writeFile(piFile, [JSON.stringify(assistantEntry("pickle-answer")), "not JSON"].join("\n"));
    await writeFile(mainPiFile, JSON.stringify(assistantEntry("main-answer", { provider: "openai", model: "gpt", usage: { input: 1, output: 2, cacheRead: 3, cacheWrite: 4 } })));
    await writeFile(join(root, "picky.json"), JSON.stringify({ sessionFilePath: mainPiFile, messages: [] }));

    const snapshot = await new HubStatisticsService(root).snapshot();

    expect(snapshot.records).toHaveLength(1);
    expect(snapshot.records[0]).toMatchObject({ id: "pickle-1", title: "Newest", project: "picky" });
    expect(snapshot.usageSamples).toEqual(expect.arrayContaining([
      expect.objectContaining({ day: "2026-09-02", provider: "anthropic", project: "picky", inputTokens: 10, outputTokens: 20, cacheTokens: 9 }),
      expect.objectContaining({ day: "2026-09-02", provider: "openai", project: "Picky", inputTokens: 1, outputTokens: 2, cacheTokens: 7 }),
    ]));
    expect(snapshot.pendingClassificationCount).toBe(1);
  });

  it("counts each stable Pi message ID once across shared paths, fork copies, and the main agent", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-hub-usage-dedup-"));
    const sessions = join(root, "sessions");
    const shared = join(root, "shared.jsonl");
    const forkOne = join(root, "fork-one.jsonl");
    const forkTwo = join(root, "fork-two.jsonl");
    const main = join(root, "main.jsonl");
    await mkdir(sessions, { recursive: true });
    await writeFile(shared, JSON.stringify(assistantEntry("shared-answer")) + "\n");
    await writeFile(forkOne, [assistantEntry("fork-base"), assistantEntry("same-text-one")].map((entry) => JSON.stringify(entry)).join("\n"));
    await writeFile(forkTwo, [assistantEntry("fork-base"), assistantEntry("same-text-two")].map((entry) => JSON.stringify(entry)).join("\n"));
    await writeFile(main, [assistantEntry("fork-base"), assistantEntry("main-answer")].map((entry) => JSON.stringify(entry)).join("\n"));
    await Promise.all([
      writeFile(join(sessions, "shared-a.json"), JSON.stringify(session("shared-a", 1, { piSessionFilePath: shared, cwd: "/work/alpha" }))),
      writeFile(join(sessions, "shared-b.json"), JSON.stringify(session("shared-b", 1, { piSessionFilePath: shared, cwd: "/work/beta" }))),
      writeFile(join(sessions, "fork-one.json"), JSON.stringify(session("fork-one", 1, { piSessionFilePath: forkOne, cwd: "/work/alpha" }))),
      writeFile(join(sessions, "fork-two.json"), JSON.stringify(session("fork-two", 1, { piSessionFilePath: forkTwo, cwd: "/work/beta" }))),
      writeFile(join(root, "picky.json"), JSON.stringify({ sessionFilePath: main, messages: [] })),
    ]);

    const service = new HubStatisticsService(root);
    const snapshots = [await service.snapshot(), await service.snapshot(), await new HubStatisticsService(root).snapshot()];
    // Deduplication and ownership survive both memory and persisted cache hits.
    for (const snapshot of snapshots) {
      expect(snapshot.usageSamples.reduce((total, sample) => total + sample.inputTokens, 0)).toBe(50);
      expect(snapshot.usageSamples.reduce((total, sample) => total + sample.outputTokens, 0)).toBe(100);
      for (const [project, expected] of [["alpha", 20], ["beta", 20], ["Picky", 10]] as const) {
        expect(snapshot.usageSamples.filter((sample) => sample.project === project)
          .reduce((total, sample) => total + sample.inputTokens, 0)).toBe(expected);
      }
    }
  });

  it("bounds the parsed Pi usage cache after scanning many stale sessions", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-hub-usage-cache-"));
    const sessions = join(root, "sessions");
    await mkdir(sessions, { recursive: true });
    await Promise.all(Array.from({ length: 65 }, async (_, index) => {
      const id = `pickle-${index}`;
      const piFile = join(root, `${id}.jsonl`);
      await writeFile(piFile, JSON.stringify(assistantEntry(`answer-${index}`)));
      await writeFile(join(sessions, `${id}.json`), JSON.stringify(session(id, 1, { piSessionFilePath: piFile })));
    }));

    const service = new HubStatisticsService(root);
    await service.snapshot();

    const cache = Reflect.get(service, "piUsageCache") as Map<string, unknown>;
    expect(cache.size).toBeLessThanOrEqual(64);
  });

  it("reuses compact per-source records across the LRU limit and reparses only changed sources", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-hub-usage-derived-cache-"));
    try {
      const sessions = join(root, "sessions");
      await mkdir(sessions, { recursive: true });
      const piFiles = await Promise.all(Array.from({ length: 65 }, async (_, index) => {
        const id = `pickle-${index}`;
        const piFile = join(root, `${id}.jsonl`);
        await writeFile(piFile, JSON.stringify(assistantEntry(`answer-${index}`, index === 0 ? { content: "SENSITIVE_TRANSCRIPT_PROMPT" } : {})));
        await writeFile(join(sessions, `${id}.json`), JSON.stringify(session(id, 1, { piSessionFilePath: piFile })));
        return piFile;
      }));

      let parseCount = 0;
      const parsedPaths: string[] = [];
      const parser = async (filePath: string) => {
        parseCount += 1;
        parsedPaths.push(filePath);
        return await parsePiUsageJsonl(filePath);
      };
      const service = new HubStatisticsService(root, { parsePiUsageJsonl: parser });

      await service.snapshot();
      expect(parseCount).toBe(65);

      const derivedDirectory = join(root, "Statistics", "pi-usage-cache", "v1");
      const derivedRecords = (await readdir(derivedDirectory)).filter((file) => file.endsWith(".json"));
      expect(derivedRecords).toHaveLength(65);
      await Promise.all(derivedRecords.map(async (file) => {
        const record = JSON.parse(await readFile(join(derivedDirectory, file), "utf8")) as Record<string, unknown>;
        expect(record).toMatchObject({ version: 1 });
        expect(record).not.toHaveProperty("content");
        expect(JSON.stringify(record)).not.toContain("SENSITIVE_TRANSCRIPT_PROMPT");
      }));

      parseCount = 0;
      vi.mocked(readFile).mockClear();
      await service.snapshot();
      expect(parseCount).toBe(0);
      const derivedReads = vi.mocked(readFile).mock.calls.filter(([path]) => (
        String(path).startsWith(derivedDirectory + "/")
      ));
      // Hydration may read all 65 records, but pruning must not read them again.
      expect(derivedReads).toHaveLength(65);
      const residentCache = Reflect.get(service, "piUsageCache") as Map<string, unknown>;
      expect(residentCache.size).toBeLessThanOrEqual(64);
      const residentEntryCaches = Object.values(service).filter((value) => (
        value instanceof Map && [...value.values()].some((entry) => (
          typeof entry === "object" && entry !== null && Array.isArray(Reflect.get(entry, "entries"))
        ))
      ));
      expect(residentEntryCaches).toHaveLength(1);
      expect(residentEntryCaches[0]).toBe(residentCache);
      expect((Reflect.get(service, "piUsageReads") as Map<string, unknown>).size).toBe(0);
      expect(Reflect.get(service, "piUsageDerivedCache")).toBeUndefined();

      const restarted = new HubStatisticsService(root, { parsePiUsageJsonl: parser });
      parseCount = 0;
      await restarted.snapshot();
      expect(parseCount).toBe(0);

      const changed = piFiles[17]!;
      await writeFile(changed, [assistantEntry("answer-17"), assistantEntry("answer-17-new")].map((entry) => JSON.stringify(entry)).join("\n"));

      parseCount = 0;
      parsedPaths.length = 0;
      const changedSnapshot = await restarted.snapshot();
      expect(parsedPaths).toEqual([changed]);
      expect(parseCount).toBe(1);
      expect(changedSnapshot.usageSamples.reduce((total, sample) => total + sample.inputTokens, 0)).toBe(660);

      await rm(piFiles[18]!);
      const newID = "pickle-new";
      const newFile = join(root, `${newID}.jsonl`);
      await writeFile(newFile, JSON.stringify(assistantEntry("answer-new")));
      await writeFile(join(sessions, `${newID}.json`), JSON.stringify(session(newID, 1, { piSessionFilePath: newFile })));

      parseCount = 0;
      parsedPaths.length = 0;
      const deletedAndNewSnapshot = await restarted.snapshot();
      expect(parsedPaths).toEqual([newFile]);
      expect(parseCount).toBe(1);
      expect(deletedAndNewSnapshot.usageSamples.reduce((total, sample) => total + sample.inputTokens, 0)).toBe(660);
      const changedRecords = await Promise.all((await readdir(derivedDirectory))
        .filter((file) => file.endsWith(".json"))
        .map(async (file) => JSON.parse(await readFile(join(derivedDirectory, file), "utf8")) as { sourcePath: string }));
      expect(changedRecords).toHaveLength(65);
      expect(changedRecords.map((record) => record.sourcePath)).not.toContain(piFiles[18]!);

      parseCount = 0;
      await restarted.snapshot();
      expect(parseCount).toBe(0);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("does not prune a missing source while an overlapping snapshot still owns it", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-hub-usage-overlap-prune-"));
    let unblockParser: (() => void) | undefined;
    try {
      const sessions = join(root, "sessions");
      const piFile = join(root, "pickle.jsonl");
      await mkdir(sessions, { recursive: true });
      await writeFile(piFile, JSON.stringify(assistantEntry("answer")));
      const sessionPath = join(sessions, "pickle.json");
      await writeFile(sessionPath, JSON.stringify(session("pickle", 1, { piSessionFilePath: piFile })));

      let blockParser = false;
      let signalParserStarted!: () => void;
      const parserStarted = new Promise<void>((resolve) => {
        signalParserStarted = resolve;
      });
      const service = new HubStatisticsService(root, {
        parsePiUsageJsonl: async (filePath) => {
          const entries = await parsePiUsageJsonl(filePath);
          if (blockParser) {
            signalParserStarted();
            await new Promise<void>((resolve) => {
              unblockParser = resolve;
            });
          }
          return entries;
        },
      });
      await service.snapshot();
      const derivedDirectory = join(root, "Statistics", "pi-usage-cache", "v1");

      blockParser = true;
      await writeFile(piFile, [assistantEntry("answer"), assistantEntry("answer-new")].map((entry) => JSON.stringify(entry)).join("\n"));
      const activeSnapshot = service.snapshot();
      await parserStarted;
      await Promise.all([rm(piFile), rm(sessionPath)]);

      await service.snapshot();
      expect((await readdir(derivedDirectory)).filter((file) => file.endsWith(".json"))).toHaveLength(1);

      unblockParser?.();
      await activeSnapshot;
      await service.snapshot();
      expect((await readdir(derivedDirectory)).filter((file) => file.endsWith(".json"))).toHaveLength(0);
    } finally {
      unblockParser?.();
      await rm(root, { recursive: true, force: true });
    }
  });

  it.each(["ENOENT", "EACCES"])("does not fail snapshots when orphan-cache deletion returns %s", async (code) => {
    const root = await mkdtemp(join(tmpdir(), "picky-hub-usage-prune-error-"));
    const actual = await vi.importActual<typeof FileSystem>("node:fs/promises");
    try {
      const sessions = join(root, "sessions");
      const piFile = join(root, "pickle.jsonl");
      await mkdir(sessions, { recursive: true });
      await writeFile(piFile, JSON.stringify(assistantEntry("answer")));
      const sessionPath = join(sessions, "pickle.json");
      await writeFile(sessionPath, JSON.stringify(session("pickle", 1, { piSessionFilePath: piFile })));
      const service = new HubStatisticsService(root);
      await service.snapshot();
      await Promise.all([rm(piFile), rm(sessionPath)]);

      vi.mocked(unlink).mockClear();
      vi.mocked(unlink).mockImplementationOnce(async (path) => {
        // Model another prune winning the unlink, or an OS access failure.
        if (code === "ENOENT") await actual.unlink(path);
        throw Object.assign(new Error("Derived-cache deletion failed"), { code });
      });

      await expect(service.snapshot()).resolves.toMatchObject({ records: [], usageSamples: [] });
      expect(unlink).toHaveBeenCalledTimes(1);
    } finally {
      vi.mocked(unlink).mockReset().mockImplementation(actual.unlink);
      await rm(root, { recursive: true, force: true });
    }
  });

  it("rebuilds a corrupt per-source record without failing statistics", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-hub-usage-corrupt-derived-"));
    try {
      const sessions = join(root, "sessions");
      const piFile = join(root, "pickle.jsonl");
      await mkdir(sessions, { recursive: true });
      await writeFile(piFile, JSON.stringify(assistantEntry("answer")));
      await writeFile(join(sessions, "pickle.json"), JSON.stringify(session("pickle", 1, { piSessionFilePath: piFile })));

      let parseCount = 0;
      const parser = async (filePath: string) => {
        parseCount += 1;
        return await parsePiUsageJsonl(filePath);
      };
      await new HubStatisticsService(root, { parsePiUsageJsonl: parser }).snapshot();
      const derivedDirectory = join(root, "Statistics", "pi-usage-cache", "v1");
      const [derivedFile] = await readdir(derivedDirectory);
      await writeFile(join(derivedDirectory, derivedFile!), "not JSON");

      parseCount = 0;
      const recovered = await new HubStatisticsService(root, { parsePiUsageJsonl: parser }).snapshot();
      expect(parseCount).toBe(1);
      expect(recovered.usageSamples[0]).toMatchObject({ inputTokens: 10, outputTokens: 20 });

      const recordWithBody = {
        ...JSON.parse(await readFile(join(derivedDirectory, derivedFile!), "utf8")),
        content: "SENSITIVE_TRANSCRIPT_PROMPT",
      };
      await writeFile(join(derivedDirectory, derivedFile!), JSON.stringify(recordWithBody));
      parseCount = 0;
      await new HubStatisticsService(root, { parsePiUsageJsonl: parser }).snapshot();
      expect(parseCount).toBe(1);
      expect(await readFile(join(derivedDirectory, derivedFile!), "utf8")).not.toContain("SENSITIVE_TRANSCRIPT_PROMPT");

      parseCount = 0;
      await new HubStatisticsService(root, { parsePiUsageJsonl: parser }).snapshot();
      expect(parseCount).toBe(0);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("removes temporary records when an atomic cache replacement fails", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-hub-usage-derived-rename-failure-"));
    try {
      const sessions = join(root, "sessions");
      const piFile = join(root, "pickle.jsonl");
      await mkdir(sessions, { recursive: true });
      await writeFile(piFile, JSON.stringify(assistantEntry("answer")));
      await writeFile(join(sessions, "pickle.json"), JSON.stringify(session("pickle", 1, { piSessionFilePath: piFile })));
      const cacheDirectory = join(root, "Statistics", "pi-usage-cache", "v1");
      const cacheFileName = createHash("sha256").update(piFile).digest("hex") + ".json";
      // Writing a sibling temp file succeeds; replacing this directory does not.
      await mkdir(join(cacheDirectory, cacheFileName), { recursive: true });

      for (let attempt = 0; attempt < 2; attempt += 1) {
        const snapshot = await new HubStatisticsService(root).snapshot();
        expect(snapshot.usageSamples[0]).toMatchObject({ inputTokens: 10, outputTokens: 20 });
      }

      expect(await readdir(cacheDirectory)).toEqual([cacheFileName]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("returns usage when a per-source cache write fails", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-hub-usage-derived-write-failure-"));
    try {
      const sessions = join(root, "sessions");
      const piFile = join(root, "pickle.jsonl");
      await mkdir(sessions, { recursive: true });
      await writeFile(piFile, JSON.stringify(assistantEntry("answer")));
      await writeFile(join(sessions, "pickle.json"), JSON.stringify(session("pickle", 1, { piSessionFilePath: piFile })));
      await mkdir(join(root, "Statistics"), { recursive: true });
      await writeFile(join(root, "Statistics", "pi-usage-cache"), "blocks the derived cache directory");

      let parseCount = 0;
      const parser = async (filePath: string) => {
        parseCount += 1;
        return await parsePiUsageJsonl(filePath);
      };
      const snapshot = await new HubStatisticsService(root, { parsePiUsageJsonl: parser }).snapshot();
      expect(snapshot.usageSamples[0]).toMatchObject({ inputTokens: 10, outputTokens: 20 });
      expect(parseCount).toBe(1);

      parseCount = 0;
      await new HubStatisticsService(root, { parsePiUsageJsonl: parser }).snapshot();
      expect(parseCount).toBe(1);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("resets persisted classifications and returns an unclassified replacement snapshot", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-hub-statistics-"));
    await mkdir(join(root, "sessions"), { recursive: true });
    await mkdir(join(root, "Statistics"), { recursive: true });
    await writeFile(join(root, "sessions", "pickle-1.json"), JSON.stringify(session("pickle-1", 0)));
    await writeFile(join(root, "Statistics", "classifications.json"), JSON.stringify({
      version: 1,
      entries: { "pickle-1": { category: "fix", fingerprint: "one", classifiedAt: "2026-09-03T00:00:00.000Z", attempts: 1 } },
    }));
    const service = new HubStatisticsService(root);

    expect((await service.snapshot()).records[0]?.category).toBe("fix");
    const reset = await service.reset();

    expect(reset.records[0]?.category).toBe("unclassified");
    await expect(readFile(join(root, "Statistics", "classifications.json"))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("defaults classification consent to false for missing and malformed persisted state", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-hub-classification-consent-"));
    const service = new HubStatisticsService(root);

    expect((await service.snapshot()).classificationEnabled).toBe(false);
    await mkdir(join(root, "Statistics"), { recursive: true });
    await writeFile(join(root, "Statistics", "classification-settings.json"), "not JSON");

    expect((await service.snapshot()).classificationEnabled).toBe(false);
  });

  it("persists explicit classification consent across service instances and reset", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-hub-classification-consent-"));
    await mkdir(join(root, "sessions"), { recursive: true });
    await writeFile(join(root, "sessions", "pickle-1.json"), JSON.stringify(session("pickle-1", 0)));
    const service = new HubStatisticsService(root);

    expect((await service.configureClassification(true)).classificationEnabled).toBe(true);
    expect((await new HubStatisticsService(root).snapshot()).classificationEnabled).toBe(true);
    expect((await service.reset()).classificationEnabled).toBe(true);
  });

  it("does not report a consent change when persistence fails", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-hub-classification-consent-"));
    await mkdir(join(root, "Statistics", "classification-settings.json"), { recursive: true });
    const service = new HubStatisticsService(root);

    await expect(service.configureClassification(true)).rejects.toBeDefined();
    expect((await service.snapshot()).classificationEnabled).toBe(false);
  });

  it("ignores malformed JSONL lines without losing valid assistant usage", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-hub-jsonl-"));
    const file = join(root, "session.jsonl");
    await writeFile(file, "bad\n" + JSON.stringify(assistantEntry("valid-answer", { usage: { input: 1, output: 2 } })));

    expect(await parsePiUsageJsonl(file)).toEqual([{
      messageId: "valid-answer",
      timestamp: "2026-09-02T12:00:00.000Z",
      provider: "anthropic",
      model: "claude",
      inputTokens: 1,
      outputTokens: 2,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
    }]);
  });
});
