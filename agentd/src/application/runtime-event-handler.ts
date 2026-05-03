import { extractChangedFilesFromExplicitText } from "../artifact-store.js";
import { mergeChangedFiles } from "../domain/changed-files.js";
import { cleanFinalAnswer, summaryFromFinalAnswer } from "../domain/session-summary.js";
import { logAgentd } from "../local-log.js";
import type { PickyAgentSession, PickyExtensionUiRequest } from "../protocol.js";
import type { RuntimeEvent } from "../runtime/types.js";
import { extensionUiLogLine, extensionUiWaitingSummary, mapExtensionUiRequest } from "./extension-ui-request-mapper.js";

export interface RuntimeEventHandlerDependencies {
  getSession(sessionId: string): PickyAgentSession;
  patchSession(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
  appendLog(sessionId: string, line: string): Promise<void>;
  materializeTerminalArtifacts(sessionId: string): Promise<void>;
  notifySideCompletion(sessionId: string): Promise<void>;
  isSideSession(sessionId: string): boolean;
  emitExtensionUiRequest(request: PickyExtensionUiRequest): void;
}

const THINKING_PREVIEW_CHAR_LIMIT = 240;
const THINKING_DRAFT_CHAR_LIMIT = THINKING_PREVIEW_CHAR_LIMIT * 4;

export class RuntimeEventHandler {
  private readonly assistantDrafts = new Map<string, string>();
  private readonly thinkingDrafts = new Map<string, string>();

  constructor(private readonly dependencies: RuntimeEventHandlerDependencies) {}

  resetAssistantDraft(sessionId: string): void {
    this.assistantDrafts.set(sessionId, "");
    this.thinkingDrafts.set(sessionId, "");
  }

  async handle(sessionId: string, event: RuntimeEvent): Promise<void> {
    if (event.type === "log") return this.dependencies.appendLog(sessionId, event.line);
    if (event.type === "assistant_delta") {
      this.assistantDrafts.set(sessionId, `${this.assistantDrafts.get(sessionId) ?? ""}${event.delta}`);
      return;
    }
    if (event.type === "thinking_delta") return this.applyThinkingEvent(sessionId, event);
    if (event.type === "status") return this.applyStatusEvent(sessionId, event);
    if (event.type === "extension_ui") {
      logAgentd("extension ui event", { sessionId, waitsForInput: event.waitsForInput, method: typeof event.request.method === "string" ? event.request.method : undefined });
      return this.applyExtensionUiEvent(sessionId, event.request, event.waitsForInput);
    }
    return this.applyToolEvent(sessionId, event);
  }

  private async applyStatusEvent(sessionId: string, event: Extract<RuntimeEvent, { type: "status" }>): Promise<void> {
    logAgentd("session status", { sessionId, status: event.status, summaryChars: event.summary?.length });
    const terminal = ["completed", "failed", "cancelled"].includes(event.status);
    const finalAnswer = terminal ? cleanFinalAnswer(this.assistantDrafts.get(sessionId)) : undefined;
    const currentSession = this.dependencies.getSession(sessionId);
    if (terminal && ["completed", "failed", "cancelled"].includes(currentSession.status)) return;

    const patch: Partial<PickyAgentSession> = { status: event.status, lastSummary: finalAnswer ? summaryFromFinalAnswer(finalAnswer) : event.summary };
    if (terminal) patch.thinkingPreview = undefined;
    if (finalAnswer) {
      patch.finalAnswer = finalAnswer;
      patch.changedFiles = mergeChangedFiles(currentSession.changedFiles, extractChangedFilesFromExplicitText(finalAnswer));
    }
    await this.dependencies.patchSession(sessionId, patch);
    if (terminal) {
      this.assistantDrafts.set(sessionId, "");
      this.thinkingDrafts.set(sessionId, "");
      await this.dependencies.materializeTerminalArtifacts(sessionId);
      if (this.dependencies.isSideSession(sessionId)) await this.dependencies.notifySideCompletion(sessionId);
    }
  }

  private async applyThinkingEvent(sessionId: string, event: Extract<RuntimeEvent, { type: "thinking_delta" }>): Promise<void> {
    if (!event.delta) return;

    const previousDraft = this.thinkingDrafts.get(sessionId) ?? "";
    if (previousDraft.length >= THINKING_DRAFT_CHAR_LIMIT) return;

    const nextDraft = `${previousDraft}${event.delta}`.slice(0, THINKING_DRAFT_CHAR_LIMIT);
    this.thinkingDrafts.set(sessionId, nextDraft);

    const thinkingPreview = compactThinkingPreview(nextDraft);
    if (!thinkingPreview || thinkingPreview === this.dependencies.getSession(sessionId).thinkingPreview) return;

    await this.dependencies.patchSession(sessionId, { thinkingPreview });
  }

  private async applyExtensionUiEvent(sessionId: string, rawRequest: Record<string, unknown>, waitsForInput: boolean): Promise<void> {
    const request = mapExtensionUiRequest(rawRequest);
    if (!waitsForInput) {
      await this.dependencies.appendLog(sessionId, extensionUiLogLine(request));
      return;
    }
    await this.dependencies.patchSession(sessionId, { status: "waiting_for_input", pendingExtensionUiRequest: request, lastSummary: extensionUiWaitingSummary(request) });
    this.dependencies.emitExtensionUiRequest(request);
  }

  private async applyToolEvent(sessionId: string, event: Extract<RuntimeEvent, { type: "tool" }>): Promise<void> {
    const session = this.dependencies.getSession(sessionId);
    const previous = session.tools.find((tool) => tool.toolCallId === event.toolCallId);
    const tools = session.tools.filter((tool) => tool.toolCallId !== event.toolCallId);
    tools.push({ ...previous, toolCallId: event.toolCallId, name: event.name, status: event.status, preview: event.preview, startedAt: previous?.startedAt ?? new Date().toISOString(), endedAt: event.status === "running" ? previous?.endedAt : new Date().toISOString() });
    logAgentd("tool activity", { sessionId, tool: event.name, status: event.status, previewChars: event.preview?.length });
    await this.dependencies.patchSession(sessionId, { tools });
  }
}

function compactThinkingPreview(value: string): string {
  const compact = value.replace(/\s+/g, " ").trim();
  if (compact.length <= THINKING_PREVIEW_CHAR_LIMIT) return compact;
  return `${compact.slice(0, THINKING_PREVIEW_CHAR_LIMIT - 1)}…`;
}
