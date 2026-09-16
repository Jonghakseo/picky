import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createAgentSessionServices, ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it, vi } from "vitest";
import { PiSdkRuntime } from "./pi-sdk-runtime.js";
import { runtimeModelScopesFromServices } from "./pi-model-resolution.js";
import type { RuntimeSessionHandle } from "./types.js";

const remoteId = "picky-remote-catalog-test-model";
const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const close of cleanup.splice(0).reverse()) await close();
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

async function fixture(options: { offline?: boolean; fail?: boolean; hang?: boolean } = {}) {
  const directory = await mkdtemp(join(tmpdir(), "picky-model-catalog-"));
  cleanup.push(() => rm(directory, { recursive: true, force: true }));
  vi.stubEnv("PI_CODING_AGENT_DIR", directory);
  if (options.offline) vi.stubEnv("PI_OFFLINE", "1");
  else vi.stubEnv("PI_OFFLINE", undefined);
  let requests = 0;
  let openaiRequests = 0;
  const server: Server = createServer((request, response) => {
    requests++;
    if (request.url === "/api/models/providers/openai") openaiRequests++;
    if (options.hang) return;
    if (options.fail) { response.writeHead(400).end(); return; }
    if (request.url !== "/api/models/providers/openai") { response.writeHead(404).end(); return; }
    response.writeHead(200, { "content-type": "application/json", "last-modified": "Tue, 01 Jan 2030 00:00:00 GMT" });
    response.end(JSON.stringify([remoteModel]));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  cleanup.push(() => new Promise<void>((resolve, reject) => {
    server.closeAllConnections();
    server.close((error) => error ? reject(error) : resolve());
  }));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Missing test catalog address");
  const authPath = join(directory, "auth.json");
  await writeFile(authPath, JSON.stringify({ openai: { type: "api_key", key: "test-not-a-real-key" } }));
  const modelRuntime = await ModelRuntime.create({
    authPath,
    modelsPath: join(directory, "models.json"),
    catalogBaseUrl: `http://127.0.0.1:${address.port}`,
  });
  const baseline = modelRuntime.getModels("openai")[0];
  if (!baseline) throw new Error("Missing built-in OpenAI model");
  const remoteModel = { ...baseline, id: remoteId, name: "Remote catalog test model" };
  const services = await createAgentSessionServices({
    cwd: directory,
    agentDir: directory,
    modelRuntime,
    resourceLoaderOptions: { noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true },
  });
  const runtime = new PiSdkRuntime({ agentDir: directory, modelPattern: `openai/${remoteId}`, createServices: async () => services });
  const prewarm = async () => {
    const handle: RuntimeSessionHandle = await runtime.prewarm({ cwd: directory });
    cleanup.push(async () => { await handle.dispose?.(); });
    return handle;
  };
  return { runtime, services, baseline, modelRuntime, prewarm, requests: () => requests, openaiRequests: () => openaiRequests, setFailure: (fail: boolean) => { options.fail = fail; } };
}

describe("Picky remote model catalog", () => {
  it("includes a remote-only model in the standalone model list with an empty cache", async () => {
    const f = await fixture();
    expect(f.modelRuntime.getModels().some((model) => model.id === remoteId)).toBe(false);
    const models = await f.runtime.listAvailableModels();
    expect(models).toContainEqual(expect.objectContaining({ provider: "openai", modelId: remoteId }));
  });

  it("resolves a remote-only initial model before creating a session and exposes it in allModels", async () => {
    const f = await fixture();
    const handle = await f.prewarm();
    const options = await handle.listRuntimeOptions!();
    expect(options.currentModel).toEqual({ provider: "openai", modelId: remoteId });
    expect(options.allModels).toContainEqual(expect.objectContaining({ modelId: remoteId }));
  });

  it("refreshes the live picker and coalesces concurrent catalog requests", async () => {
    const f = await fixture();
    const session = { setScopedModels: () => {} } as unknown as Parameters<typeof runtimeModelScopesFromServices>[1];
    const [first, second] = await Promise.all([
      runtimeModelScopesFromServices(f.services, session),
      runtimeModelScopesFromServices(f.services, session),
    ]);
    expect(first.allModels).toContainEqual(expect.objectContaining({ modelId: remoteId }));
    expect(second.allModels).toEqual(first.allModels);
    expect(f.openaiRequests()).toBe(1);
    const requests = f.requests();
    await runtimeModelScopesFromServices(f.services, session);
    expect(f.requests()).toBe(requests);
  });

  it("keeps built-in models available when the catalog returns provider errors", async () => {
    const f = await fixture({ fail: true });
    const models = await f.runtime.listAvailableModels();
    expect(f.requests()).toBeGreaterThan(0);
    expect(models).toContainEqual(expect.objectContaining({ modelId: f.baseline.id }));
    expect(models.some((model) => model.modelId === remoteId)).toBe(false);
  });

  it("retries after a failed refresh and retains cached remote models during a later outage", async () => {
    const f = await fixture({ fail: true });
    expect((await f.runtime.listAvailableModels()).some((model) => model.modelId === remoteId)).toBe(false);
    const now = Date.now();
    const clock = vi.spyOn(Date, "now").mockReturnValue(now + 60_001);
    f.setFailure(false);
    expect(await f.runtime.listAvailableModels()).toContainEqual(expect.objectContaining({ modelId: remoteId }));
    clock.mockReturnValue(now + 5 * 60 * 60 * 1000);
    const requests = f.requests();
    f.setFailure(true);
    expect(await f.runtime.listAvailableModels()).toContainEqual(expect.objectContaining({ modelId: remoteId }));
    expect(f.requests()).toBeGreaterThan(requests);
  });

  it("keeps the model list usable if the SDK refresh throws", async () => {
    const f = await fixture();
    vi.spyOn(f.modelRuntime, "refresh").mockRejectedValue(new Error("Catalog unavailable"));
    expect(await f.runtime.listAvailableModels()).toContainEqual(expect.objectContaining({ modelId: f.baseline.id }));
  });

  it("honors PI_OFFLINE without contacting the catalog", async () => {
    const f = await fixture({ offline: true });
    const models = await f.runtime.listAvailableModels();
    expect(f.requests()).toBe(0);
    expect(models).toContainEqual(expect.objectContaining({ modelId: f.baseline.id }));
  });

  it("returns existing models when a stalled catalog reaches the refresh deadline", async () => {
    const f = await fixture({ hang: true });
    const models = await f.runtime.listAvailableModels();
    expect(f.requests()).toBeGreaterThan(0);
    expect(models).toContainEqual(expect.objectContaining({ modelId: f.baseline.id }));
  }, 10_000);
});
