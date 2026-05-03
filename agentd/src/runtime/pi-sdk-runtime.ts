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
import { ExtensionUiBridge } from "../application/extension-ui-bridge.js";
import { runtimeEventFromPiEvent } from "../domain/pi-event-normalizer.js";
import type { AgentRuntime, RuntimeEvent, RuntimeSessionHandle } from "./types.js";
import { logAgentd } from "../local-log.js";

type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh";

export interface PiSdkRuntimeOptions {
  agentDir?: string;
  createRuntime?: typeof createAgentSessionRuntime;
  createServices?: typeof createAgentSessionServices;
  createSessionFromServices?: typeof createAgentSessionFromServices;
  getAgentDir?: typeof getAgentDir;
  resourceLoaderOptions?: CreateAgentSessionServicesOptions["resourceLoaderOptions"];
  customTools?: ToolDefinition[];
  thinkingLevel?: ThinkingLevel;
}

export class PiSdkRuntime implements AgentRuntime {
  constructor(private readonly options: PiSdkRuntimeOptions = {}) {}

  async create(prompt: BuiltPrompt, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    logAgentd("pi runtime create", { sessionId: options.sessionId, cwd: options.cwd, promptChars: prompt.text.length, images: prompt.imagePaths?.length ?? 0 });
    const handle = await this.createHandle(options);
    setTimeout(() => {
      handle.reportDiagnostics();
      void handle.prompt(prompt);
    }, 0);
    return handle;
  }

  async prewarm(options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    logAgentd("pi runtime prewarm", { sessionId: options.sessionId, cwd: options.cwd });
    const handle = await this.createHandle(options);
    setTimeout(() => handle.reportDiagnostics(), 0);
    return handle;
  }

  async resume(sessionFilePath: string, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    logAgentd("pi runtime resume", { sessionId: options.sessionId, cwd: options.cwd, sessionFilePath });
    const handle = await this.createHandle({ ...options, sessionFilePath });
    setTimeout(() => handle.reportDiagnostics(), 0);
    return handle;
  }

  private async createHandle(options: { cwd?: string; sessionId?: string; sessionFilePath?: string }): Promise<PiSdkRuntimeSession> {
    const cwd = options.cwd ?? process.cwd();
    const sessionId = options.sessionId ?? "picky-pi-session";
    const createServices = this.options.createServices ?? createAgentSessionServices;
    const createSessionFromServices = this.options.createSessionFromServices ?? createAgentSessionFromServices;
    const createRuntimeImpl = this.options.createRuntime ?? createAgentSessionRuntime;
    const agentDir = this.options.agentDir ?? (this.options.getAgentDir ?? getAgentDir)();

    const createRuntime: CreateAgentSessionRuntimeFactory = async ({ cwd: runtimeCwd, sessionManager, sessionStartEvent }) => {
      const services = await createServices({ cwd: runtimeCwd, agentDir, resourceLoaderOptions: this.options.resourceLoaderOptions });
      return {
        ...(await createSessionFromServices({ services, sessionManager, sessionStartEvent, customTools: this.options.customTools, thinkingLevel: this.options.thinkingLevel })),
        services,
        diagnostics: services.diagnostics,
      };
    };

    const runtime = await createRuntimeImpl(createRuntime, {
      cwd,
      agentDir,
      sessionManager: options.sessionFilePath ? SessionManager.open(options.sessionFilePath, undefined, cwd) : SessionManager.create(cwd),
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
  private readonly transcriptRepairLogLine?: string;
  private queuedSteeringCount = 0;
  private queuedFollowUpCount = 0;
  private pendingExtensionUiRequestIds = new Set<string>();

  constructor(readonly id: string, private readonly runtime: AgentSessionRuntime) {
    this.uiBridge = this.createBridge();
    this.transcriptRepairLogLine = repairDanglingToolCalls(runtime.session);
    this.runtime.setRebindSession(async () => this.bindCurrentSession());
  }

  async prompt(prompt: BuiltPrompt): Promise<void> {
    logAgentd("pi prompt", { sessionId: this.id, promptChars: prompt.text.length, images: prompt.imagePaths?.length ?? 0 });
    try {
      await this.runtime.session.prompt(prompt.text, { images: await imageOptions(prompt.imagePaths), source: "rpc" });
    } catch (error) {
      this.emit({ type: "status", status: "failed", summary: messageOf(error) });
    }
  }

  async followUp(prompt: BuiltPrompt): Promise<void> {
    logAgentd("pi follow-up", { sessionId: this.id, promptChars: prompt.text.length, images: prompt.imagePaths?.length ?? 0 });
    try {
      await this.promptWithOptions(prompt, "followUp");
    } catch (error) {
      this.emit({ type: "status", status: "failed", summary: messageOf(error) });
      throw error;
    }
  }

  async interrupt(prompt: BuiltPrompt): Promise<void> {
    logAgentd("pi interrupt", { sessionId: this.id, wasStreaming: this.runtime.session.isStreaming, promptChars: prompt.text.length });
    try {
      if (this.runtime.session.isStreaming) {
        await this.runtime.session.abort();
      }
      await this.promptWithOptions(prompt);
    } catch (error) {
      this.emit({ type: "status", status: "failed", summary: messageOf(error) });
      throw error;
    }
  }

  async steer(text: string): Promise<void> {
    logAgentd("pi steer", { sessionId: this.id, textChars: text.length });
    try {
      await this.promptWithOptions({ text, imagePaths: [] }, "steer");
    } catch (error) {
      this.emit({ type: "status", status: "failed", summary: messageOf(error) });
      throw error;
    }
  }

  async abort(): Promise<void> {
    logAgentd("pi abort", { sessionId: this.id });
    await this.runtime.session.abort();
    this.emit({ type: "status", status: "cancelled", summary: "Cancelled" });
  }

  async answerExtensionUi(requestId: string, value: unknown): Promise<void> {
    this.pendingExtensionUiRequestIds.delete(requestId);
    this.uiBridge.answer(requestId, normalizeAnswer(value));
  }

  async bindCurrentSession(): Promise<void> {
    logAgentd("pi bind session", { sessionId: this.id });
    this.unsubscribe?.();
    this.uiBridge = this.createBridge();
    const session = this.runtime.session;
    await session.bindExtensions({ uiContext: this.uiBridge.createContext(), onError: (error) => this.emit({ type: "log", line: `extension error: ${messageOf(error)}` }) });
    this.unsubscribe = session.subscribe((event: unknown) => {
      const runtimeEvent = this.runtimeEventFromPiEvent(event);
      if (runtimeEvent) this.emit(runtimeEvent);
    });
  }

  reportDiagnostics(): void {
    if (this.transcriptRepairLogLine) this.emit({ type: "log", line: this.transcriptRepairLogLine });
    for (const diagnostic of this.runtime.diagnostics) {
      this.emit({ type: "log", line: `pi diagnostic: ${JSON.stringify(diagnostic)}` });
    }
    const sessionFile = this.runtime.session.sessionFile;
    if (sessionFile) {
      logAgentd("pi session file", { sessionId: this.id, sessionFile });
      this.emit({ type: "log", line: `pi session: ${sessionFile}` });
    }
  }

  subscribe(listener: (event: RuntimeEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private runtimeEventFromPiEvent(event: unknown): RuntimeEvent | undefined {
    const record = asRecord(event);
    if (record.type === "queue_update") {
      this.queuedSteeringCount = Array.isArray(record.steering) ? record.steering.length : 0;
      this.queuedFollowUpCount = Array.isArray(record.followUp) ? record.followUp.length : 0;
    }

    const runtimeEvent = runtimeEventFromPiEvent(event, {
      hasQueuedSteering: this.queuedSteeringCount > 0,
      hasQueuedFollowUp: this.queuedFollowUpCount > 0,
      hasPendingExtensionUiRequest: this.pendingExtensionUiRequestIds.size > 0,
    });

    if (runtimeEvent?.type === "extension_ui" && runtimeEvent.waitsForInput) {
      const requestId = typeof runtimeEvent.request.id === "string" ? runtimeEvent.request.id : undefined;
      if (requestId) this.pendingExtensionUiRequestIds.add(requestId);
    }

    return runtimeEvent;
  }

  private async promptWithOptions(prompt: BuiltPrompt, streamingBehavior?: "steer" | "followUp"): Promise<void> {
    await this.promptUntilAccepted(prompt.text, {
      images: await imageOptions(prompt.imagePaths),
      source: "rpc",
      streamingBehavior,
    });
  }

  private async promptUntilAccepted(
    text: string,
    options: { images?: Awaited<ReturnType<typeof imageOptions>>; source: "rpc"; streamingBehavior?: "steer" | "followUp" },
  ): Promise<void> {
    let accepted = false;
    let settled = false;
    let resolveAccepted!: () => void;
    let rejectAccepted!: (error: unknown) => void;
    const acceptedPromise = new Promise<void>((resolve, reject) => {
      resolveAccepted = resolve;
      rejectAccepted = reject;
    });
    const resolveOnce = () => {
      if (settled) return;
      settled = true;
      resolveAccepted();
    };
    const rejectOnce = (error: unknown) => {
      if (settled) return;
      settled = true;
      rejectAccepted(error);
    };

    const promptPromise = this.runtime.session.prompt(text, {
      ...options,
      preflightResult: (success: boolean) => {
        if (!success) return;
        accepted = true;
        resolveOnce();
      },
    });

    void promptPromise
      .then(resolveOnce)
      .catch((error) => {
        if (accepted) {
          this.emit({ type: "status", status: "failed", summary: messageOf(error) });
          return;
        }
        rejectOnce(error);
      });

    await acceptedPromise;
  }

  private createBridge(): ExtensionUiBridge {
    const bridge = new ExtensionUiBridge(this.id);
    bridge.on("request", (request, waitsForInput) => {
      const waits = Boolean(waitsForInput);
      if (waits) this.pendingExtensionUiRequestIds.add(request.id);
      this.emit({ type: "extension_ui", request, waitsForInput: waits });
    });
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

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : {};
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function repairDanglingToolCalls(session: AgentSession): string | undefined {
  const messages = (session.state.messages ?? []) as unknown[];
  const repair = repairDanglingToolCallsInMessages(messages);
  if (repair.count === 0) return undefined;
  const names = [...new Set(repair.toolNames)].join(", ");
  return `pi transcript repaired: skipped ${repair.count} interrupted tool call(s)${names ? ` (${names})` : ""} from a previous runtime`;
}

function repairDanglingToolCallsInMessages(messages: unknown[]): { count: number; toolNames: string[] } {
  let pending: { message: Record<string, unknown>; calls: Array<{ id: string; name: string }>; matchedIds: Set<string> } | undefined;
  let count = 0;
  const toolNames: string[] = [];

  const repairPending = () => {
    if (!pending) return;
    const missing = pending.calls.filter((call) => !pending!.matchedIds.has(call.id));
    if (missing.length === 0) return;
    repairAssistantMessageWithDanglingToolCalls(pending.message, pending.matchedIds, missing);
    count += missing.length;
    toolNames.push(...missing.map((call) => call.name));
  };

  for (const value of messages) {
    const message = asRecord(value);
    if (pending) {
      const toolCallId = message.role === "toolResult" ? stringValue(message.toolCallId) : undefined;
      if (toolCallId && pending.calls.some((call) => call.id === toolCallId)) {
        pending.matchedIds.add(toolCallId);
        if (pending.calls.every((call) => pending!.matchedIds.has(call.id))) pending = undefined;
        continue;
      }
      repairPending();
      pending = undefined;
    }

    if (message.role !== "assistant") continue;
    const calls = toolCallsFromContent(message.content);
    if (calls.length > 0) pending = { message, calls, matchedIds: new Set() };
  }

  if (pending) repairPending();
  return { count, toolNames };
}

function repairAssistantMessageWithDanglingToolCalls(message: Record<string, unknown>, matchedIds: Set<string>, missing: Array<{ id: string; name: string }>): void {
  const content = Array.isArray(message.content) ? message.content : [];
  const textBlocks = content.filter((block) => asRecord(block).type === "text");
  const matchedToolCallBlocks = content.filter((block) => {
    const record = asRecord(block);
    return record.type === "toolCall" && typeof record.id === "string" && matchedIds.has(record.id);
  });
  const names = [...new Set(missing.map((call) => call.name))].join(", ") || "tool";
  const note = {
    type: "text",
    text: `[Picky note: previous ${names} tool call${missing.length === 1 ? "" : "s"} did not finish because the local Picky runtime restarted. Continue from the current filesystem state and rerun any needed checks.]`,
  };
  message.content = [...textBlocks, note, ...matchedToolCallBlocks];
  if (matchedToolCallBlocks.length === 0 && message.stopReason === "toolUse") message.stopReason = "end_turn";
}

function toolCallsFromContent(content: unknown): Array<{ id: string; name: string }> {
  if (!Array.isArray(content)) return [];
  return content.flatMap((block) => {
    const record = asRecord(block);
    const id = stringValue(record.id);
    if (record.type !== "toolCall" || !id) return [];
    return [{ id, name: stringValue(record.name) ?? "tool" }];
  });
}

function normalizeAnswer(value: unknown): { value?: unknown; confirmed?: boolean; cancelled?: boolean } {
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    if ("value" in record || "confirmed" in record || "cancelled" in record) {
      return record as { value?: unknown; confirmed?: boolean; cancelled?: boolean };
    }
  }
  return { value };
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export type { AgentSession, AgentSessionRuntime };
