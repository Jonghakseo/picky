import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { PickyAgentSessionSchema } from "../protocol.js";
import { HubStatisticsService } from "./hub-statistics-service.js";
import { PickleClassifier, buildPickleClassificationInput, parseClassificationResponse } from "./pickle-classifier.js";

function session(overrides: Record<string, unknown> = {}) {
  return PickyAgentSessionSchema.parse({
    id: "pickle-1",
    title: "Fix broken navigation",
    status: "completed",
    cwd: "/work/picky",
    createdAt: "2026-09-01T00:00:00.000Z",
    updatedAt: "2026-09-02T00:00:00.000Z",
    messages: Array.from({ length: 6 }, (_, index) => ({
      id: `message-${index}`,
      kind: "user_text",
      originatedBy: "user",
      createdAt: "2026-09-01T00:00:00.000Z",
      text: `Message ${index} ${"x".repeat(400)}`,
    })),
    tools: [
      { toolCallId: "tool-1", name: "read", status: "succeeded" },
      { toolCallId: "tool-2", name: "read", status: "succeeded" },
      { toolCallId: "tool-3", name: "edit", status: "succeeded" },
    ],
    activitySummary: { read: 2, bash: 0, edit: 1, write: 0, thinking: 0, other: 0 },
    changedFiles: [{ path: "Picky/App.swift", status: "modified" }],
    subagentRuns: [{ runId: 1, agent: "reviewer", task: "review", status: "done" }],
    ...overrides,
  });
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

async function classifierFixture() {
  const root = await mkdtemp(join(tmpdir(), "picky-classifier-"));
  await mkdir(join(root, "sessions"), { recursive: true });
  await writeFile(join(root, "sessions", "pickle-1.json"), JSON.stringify(session()));
  return { root, statistics: new HubStatisticsService(root) };
}

async function enableClassifier(classifier: PickleClassifier, statistics: HubStatisticsService): Promise<void> {
  await statistics.configureClassification(true);
  classifier.setClassificationEnabled(true);
}

describe("PickleClassifier", () => {
  it("builds a bounded metadata-only classification input", () => {
    const input = buildPickleClassificationInput(session());

    expect(input.length).toBeLessThanOrEqual(600);
    expect(input).toContain("title=Fix broken navigation");
    expect(input).toContain("tools=read:2,edit:1");
    expect(input).toContain("changedFiles=1");
    expect(input).toContain("Message 0");
    expect(input).not.toContain("Message 5");
  });

  it("stores model categories for eligible terminal Pickles", async () => {
    const { root, statistics } = await classifierFixture();
    const complete = vi.fn(async () => '[{"id":"pickle-1","category":"fix"}]');
    const classifier = new PickleClassifier({
      statistics,
      completer: { complete },
      now: () => new Date("2026-10-01T00:00:00.000Z"),
    });

    await enableClassifier(classifier, statistics);
    await classifier.runOnce();

    expect(complete).toHaveBeenCalledOnce();
    expect(complete).toHaveBeenCalledWith(expect.objectContaining({ maxTokens: 300 }));
    const saved = JSON.parse(await readFile(join(root, "Statistics", "classifications.json"), "utf8"));
    expect(saved.entries["pickle-1"]).toMatchObject({ category: "fix", attempts: 1 });
  });

  it("does not send running or recently inactive non-terminal Pickles to the model", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-classifier-"));
    await mkdir(join(root, "sessions"), { recursive: true });
    await writeFile(join(root, "sessions", "running.json"), JSON.stringify(session({ id: "running", status: "running" })));
    await writeFile(join(root, "sessions", "waiting.json"), JSON.stringify(session({ id: "waiting", status: "waiting_for_input", updatedAt: "2026-10-01T00:00:00.000Z" })));
    const complete = vi.fn();
    const classifier = new PickleClassifier({
      statistics: new HubStatisticsService(root),
      completer: { complete },
      now: () => new Date("2026-10-01T01:00:00.000Z"),
    });

    await enableClassifier(classifier, new HubStatisticsService(root));
    await classifier.runOnce();

    expect(complete).not.toHaveBeenCalled();
  });

  it("does not call the model before explicit classification consent", async () => {
    const { statistics } = await classifierFixture();
    const complete = vi.fn(async () => '[{"id":"pickle-1","category":"fix"}]');
    const classifier = new PickleClassifier({
      statistics,
      completer: { complete },
      now: () => new Date("2026-10-01T00:00:00.000Z"),
    });

    await classifier.start();
    await classifier.runOnce();

    expect(complete).not.toHaveBeenCalled();
  });

  it("resumes classification only from persisted explicit consent", async () => {
    const { statistics } = await classifierFixture();
    const complete = vi.fn(async () => '[{"id":"pickle-1","category":"fix"}]');
    const classifier = new PickleClassifier({
      statistics,
      completer: { complete },
      now: () => new Date("2026-10-01T00:00:00.000Z"),
    });
    await statistics.configureClassification(true);

    await classifier.start();
    await classifier.runOnce();

    expect(complete).toHaveBeenCalledOnce();
    classifier.stop();
  });

  it("discards a late model completion when reset advances the classification generation", async () => {
    const { root, statistics } = await classifierFixture();
    const completion = deferred<string>();
    const called = deferred<void>();
    const classifier = new PickleClassifier({
      statistics,
      completer: { complete: vi.fn(() => { called.resolve(); return completion.promise; }) },
      now: () => new Date("2026-10-01T00:00:00.000Z"),
    });

    await enableClassifier(classifier, statistics);
    const running = classifier.runOnce();
    await called.promise;
    const reset = await statistics.reset();
    completion.resolve('[{"id":"pickle-1","category":"fix"}]');
    await running;

    expect(reset.records[0]?.category).toBe("unclassified");
    await expect(readFile(join(root, "Statistics", "classifications.json"), "utf8")).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("disabling aborts and discards an uncancellable model completion", async () => {
    const { root, statistics } = await classifierFixture();
    const completion = deferred<string>();
    const called = deferred<void>();
    let signal: AbortSignal | undefined;
    const classifier = new PickleClassifier({
      statistics,
      completer: { complete: vi.fn((input) => { signal = input.signal; called.resolve(); return completion.promise; }) },
      now: () => new Date("2026-10-01T00:00:00.000Z"),
    });

    await enableClassifier(classifier, statistics);
    const running = classifier.runOnce();
    await called.promise;
    await statistics.configureClassification(false);
    classifier.setClassificationEnabled(false);
    expect(signal?.aborted).toBe(true);
    completion.resolve('[{"id":"pickle-1","category":"fix"}]');
    await running;

    await expect(readFile(join(root, "Statistics", "classifications.json"), "utf8")).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("retries malformed model output three times, then stores an unclassified fourth failure", async () => {
    const { root, statistics } = await classifierFixture();
    const complete = vi.fn(async () => "not JSON");
    const classifier = new PickleClassifier({
      statistics,
      completer: { complete },
      now: () => new Date("2026-10-01T00:00:00.000Z"),
    });

    await enableClassifier(classifier, statistics);
    await classifier.runOnce();
    await classifier.runOnce();
    await classifier.runOnce();
    await classifier.runOnce();
    await classifier.runOnce();

    expect(complete).toHaveBeenCalledTimes(4);
    const saved = JSON.parse(await readFile(join(root, "Statistics", "classifications.json"), "utf8"));
    expect(saved.entries["pickle-1"]).toMatchObject({ category: "unclassified", attempts: 4 });
    expect(parseClassificationResponse('[{"id":"one","category":"unknown"},{"id":"two","category":"review"}]')).toEqual(new Map([["two", "review"]]));
  });
});
