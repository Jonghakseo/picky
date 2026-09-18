import { appendFile, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, expect, it, vi } from "vitest";
import { PickyAgentSessionSchema } from "../protocol.js";
import { SessionStore } from "../session-store.js";
import { SessionSupervisor } from "../session-supervisor.js";
import { MockRuntime } from "../runtime/mock-runtime.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))); });
async function setup() {
  const root = await mkdtemp(join(tmpdir(), "picky-detail-service-")); roots.push(root);
  const path = join(root, "pi.jsonl");
  await writeFile(path, JSON.stringify({ type: "message", message: { role: "assistant", content: [{ type: "toolCall", id: "call", name: "read", arguments: { path: "file" } }] } }) + "\n");
  const store = new SessionStore(root, { scopeSessionId: "child" });
  const session = PickyAgentSessionSchema.parse({ id: "child", title: "Child", status: "completed", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", piSessionFilePath: path, tools: [{ toolCallId: "call", name: "read", status: "succeeded", endedAt: new Date().toISOString() }] });
  await store.save(session);
  const runtime = new MockRuntime(); const create = vi.spyOn(runtime, "create");
  const supervisor = new SessionSupervisor(runtime, new SessionStore(root));
  const request = { sessionId: "child", toolCallId: "call", expectedSessionFile: path, part: "result" as const };
  return { root, path, store, session, supervisor, request, create };
}
it("reads retired child detail without loading, resuming or writing session metadata", async () => {
  const { root, path, store, session, supervisor, request, create } = await setup();
  const metadata = join(root, "sessions", "child", "child.json"); const before = await readFile(metadata, "utf8");
  expect(await supervisor.getToolHistoryDetail(request)).toMatchObject({ status: "pending" });
  await appendFile(path, JSON.stringify({ type: "message", message: { role: "toolResult", toolCallId: "call", toolName: "read", content: [{ type: "text", text: "x".repeat(600) + "FULL" }], isError: false } }) + "\n");
  expect(await supervisor.getToolHistoryDetail(request)).toMatchObject({ status: "ready", text: expect.stringContaining("FULL") });
  expect(create).not.toHaveBeenCalled(); expect(await readFile(metadata, "utf8")).toBe(before);
  await store.save({ ...session, piSessionFilePath: "/new-source" });
  expect(await supervisor.getToolHistoryDetail(request)).toMatchObject({ status: "sourceChanged" });
});
it("rejects unknown tools and caller paths, excludes user bash, and settles old missing results", async () => {
  const { store, session, supervisor, request } = await setup();
  expect(await supervisor.getToolHistoryDetail({ ...request, toolCallId: "unknown" })).toMatchObject({ status: "unavailable", reason: "unknownTool" });
  expect(await supervisor.getToolHistoryDetail({ ...request, expectedSessionFile: "/etc/passwd" })).toMatchObject({ status: "sourceChanged" });
  expect(await supervisor.getToolHistoryDetail({ ...request, toolCallId: "user-bash-123" })).toMatchObject({ status: "unsupported" });
  await store.save({ ...session, tools: [{ ...session.tools[0], endedAt: "2026-01-01T00:00:00Z" }] });
  expect(await supervisor.getToolHistoryDetail(request)).toMatchObject({ status: "unavailable", reason: "notPersisted" });
});
