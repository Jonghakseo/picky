import { readFile } from "node:fs/promises";
import { extname } from "node:path";
import {
  type AgentSession,
  type AgentSessionRuntime,
  type CreateAgentSessionRuntimeFactory,
  type CreateAgentSessionServicesOptions,
  type ToolDefinition,
  createAgentSessionFromServices,
  createAgentSessionRuntime,
  createAgentSessionServices,
  getAgentDir,
  SessionManager,
} from "@mariozechner/pi-coding-agent";
import type { BuiltPrompt } from "../prompt-builder.js";
import { ExtensionUiBridge } from "../extension-ui-bridge.js";
import { runtimeEventFromPiEvent } from "../pi-event-normalizer.js";
import type { AgentRuntime, RuntimeEvent, RuntimeSessionHandle } from "./types.js";

export interface PiSdkRuntimeOptions {
  agentDir?: string;
  createRuntime?: typeof createAgentSessionRuntime;
  createServices?: typeof createAgentSessionServices;
  createSessionFromServices?: typeof createAgentSessionFromServices;
  getAgentDir?: typeof getAgentDir;
  resourceLoaderOptions?: CreateAgentSessionServicesOptions["resourceLoaderOptions"];
  customTools?: ToolDefinition[];
}

export class PiSdkRuntime implements AgentRuntime {
  constructor(private readonly options: PiSdkRuntimeOptions = {}) {}

  async create(prompt: BuiltPrompt, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    const handle = await this.createHandle(options);
    setTimeout(() => {
      handle.reportDiagnostics();
      void handle.prompt(prompt);
    }, 0);
    return handle;
  }

  async prewarm(options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    const handle = await this.createHandle(options);
    setTimeout(() => handle.reportDiagnostics(), 0);
    return handle;
  }

  private async createHandle(options: { cwd?: string; sessionId?: string }): Promise<PiSdkRuntimeSession> {
    const cwd = options.cwd ?? process.cwd();
    const sessionId = options.sessionId ?? "picky-pi-session";
    const createServices = this.options.createServices ?? createAgentSessionServices;
    const createSessionFromServices = this.options.createSessionFromServices ?? createAgentSessionFromServices;
    const createRuntimeImpl = this.options.createRuntime ?? createAgentSessionRuntime;
    const agentDir = this.options.agentDir ?? (this.options.getAgentDir ?? getAgentDir)();

    const createRuntime: CreateAgentSessionRuntimeFactory = async ({ cwd: runtimeCwd, sessionManager, sessionStartEvent }) => {
      const services = await createServices({ cwd: runtimeCwd, agentDir, resourceLoaderOptions: this.options.resourceLoaderOptions });
      return {
        ...(await createSessionFromServices({ services, sessionManager, sessionStartEvent, customTools: this.options.customTools })),
        services,
        diagnostics: services.diagnostics,
      };
    };

    const runtime = await createRuntimeImpl(createRuntime, {
      cwd,
      agentDir,
      sessionManager: SessionManager.create(cwd),
    });

    const handle = new PiSdkRuntimeSession(sessionId, runtime);
    await handle.bindCurrentSession();
    return handle;
  }
}

class PiSdkRuntimeSession implements RuntimeSessionHandle {
  private listeners = new Set<(event: RuntimeEvent) => void>();
  private unsubscribe?: () => void;
  private uiBridge: ExtensionUiBridge;

  constructor(readonly id: string, private readonly runtime: AgentSessionRuntime) {
    this.uiBridge = this.createBridge();
    this.runtime.setRebindSession(async () => this.bindCurrentSession());
  }

  async prompt(prompt: BuiltPrompt): Promise<void> {
    try {
      await this.runtime.session.prompt(prompt.text, { images: await imageOptions(prompt.imagePaths), source: "rpc" });
    } catch (error) {
      this.emit({ type: "status", status: "failed", summary: messageOf(error) });
    }
  }

  async followUp(prompt: BuiltPrompt): Promise<void> {
    try {
      await this.runtime.session.prompt(prompt.text, {
        images: await imageOptions(prompt.imagePaths),
        source: "rpc",
        streamingBehavior: "followUp",
      });
    } catch (error) {
      this.emit({ type: "status", status: "failed", summary: messageOf(error) });
      throw error;
    }
  }

  async steer(text: string): Promise<void> {
    await this.runtime.session.steer(text);
  }

  async abort(): Promise<void> {
    await this.runtime.session.abort();
    this.emit({ type: "status", status: "cancelled", summary: "Cancelled" });
  }

  async answerExtensionUi(requestId: string, value: unknown): Promise<void> {
    this.uiBridge.answer(requestId, normalizeAnswer(value));
  }

  async bindCurrentSession(): Promise<void> {
    this.unsubscribe?.();
    this.uiBridge = this.createBridge();
    const session = this.runtime.session;
    await session.bindExtensions({ uiContext: this.uiBridge.createContext(), onError: (error) => this.emit({ type: "log", line: `extension error: ${messageOf(error)}` }) });
    this.unsubscribe = session.subscribe((event: unknown) => {
      const runtimeEvent = runtimeEventFromPiEvent(event);
      if (runtimeEvent) this.emit(runtimeEvent);
    });
  }

  reportDiagnostics(): void {
    for (const diagnostic of this.runtime.diagnostics) {
      this.emit({ type: "log", line: `pi diagnostic: ${JSON.stringify(diagnostic)}` });
    }
    const sessionFile = this.runtime.session.sessionFile;
    if (sessionFile) this.emit({ type: "log", line: `pi session: ${sessionFile}` });
  }

  subscribe(listener: (event: RuntimeEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private createBridge(): ExtensionUiBridge {
    const bridge = new ExtensionUiBridge(this.id);
    bridge.on("request", (request, waitsForInput) => this.emit({ type: "extension_ui", request, waitsForInput: Boolean(waitsForInput) }));
    return bridge;
  }

  private emit(event: RuntimeEvent): void {
    for (const listener of this.listeners) listener(event);
  }
}

async function imageOptions(imagePaths: string[] | undefined): Promise<Array<{ type: "image"; data: string; mimeType: string }> | undefined> {
  if (!imagePaths || imagePaths.length === 0) return undefined;
  return Promise.all(
    imagePaths.map(async (imagePath) => ({
      type: "image" as const,
      mimeType: mediaTypeFromPath(imagePath),
      data: await readFile(imagePath, "base64"),
    })),
  );
}

function mediaTypeFromPath(path: string): string {
  const extension = extname(path).toLowerCase();
  if (extension === ".jpg" || extension === ".jpeg") return "image/jpeg";
  if (extension === ".webp") return "image/webp";
  return "image/png";
}

function normalizeAnswer(value: unknown): { value?: unknown; confirmed?: boolean; cancelled?: boolean } {
  if (value && typeof value === "object") return value as { value?: unknown; confirmed?: boolean; cancelled?: boolean };
  return { value };
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export type { AgentSession, AgentSessionRuntime };
