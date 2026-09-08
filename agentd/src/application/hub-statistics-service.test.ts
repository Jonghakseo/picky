import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { PickyAgentSessionSchema } from "../protocol.js";
import { HubStatisticsService, parsePiUsageJsonl } from "./hub-statistics-service.js";

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
      writeFile(join(sessions, "shared-a.json"), JSON.stringify(session("shared-a", 1, { piSessionFilePath: shared }))),
      writeFile(join(sessions, "shared-b.json"), JSON.stringify(session("shared-b", 1, { piSessionFilePath: shared }))),
      writeFile(join(sessions, "fork-one.json"), JSON.stringify(session("fork-one", 1, { piSessionFilePath: forkOne }))),
      writeFile(join(sessions, "fork-two.json"), JSON.stringify(session("fork-two", 1, { piSessionFilePath: forkTwo }))),
      writeFile(join(root, "picky.json"), JSON.stringify({ sessionFilePath: main, messages: [] })),
    ]);

    const snapshot = await new HubStatisticsService(root).snapshot();

    // shared-answer, fork-base, same-text-one, same-text-two, and main-answer.
    // The two same-text entries remain distinct because their Pi message IDs differ.
    expect(snapshot.usageSamples.reduce((total, sample) => total + sample.inputTokens, 0)).toBe(50);
    expect(snapshot.usageSamples.reduce((total, sample) => total + sample.outputTokens, 0)).toBe(100);
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
