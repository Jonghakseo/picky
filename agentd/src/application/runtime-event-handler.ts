import { extractChangedFilesFromExplicitText } from "../artifact-store.js";
import { mergeChangedFiles } from "../domain/changed-files.js";
import { sliceUtf16Safe } from "../domain/safe-truncate.js";
import { isTerminalStatus } from "../domain/session-status.js";
import { cleanFinalAnswer, summaryFromFinalAnswer } from "../domain/session-summary.js";
import { settleActiveTools } from "../domain/tool-activity.js";
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
    // Prefer the final assistant message carried by the runtime event (Pi turn_end/agent_end)
    // over the streamed assistant_delta accumulator, which would otherwise concatenate every
    // intermediate message in a multi-turn ReAct loop. Failed runtime events often carry only a
    // diagnostic summary while the draft is merely partial output, so do not promote the draft to
    // finalAnswer for failures unless Pi explicitly provides event.finalAnswer.
    const explicitFinalAnswer = cleanFinalAnswer(event.finalAnswer);
    const finalAnswer = terminal
      ? (explicitFinalAnswer ?? (event.status === "failed" ? undefined : cleanFinalAnswer(this.assistantDrafts.get(sessionId))))
      : undefined;
    const currentSession = this.dependencies.getSession(sessionId);
    // Once a session has reached a terminal status, ignore any subsequent runtime status
    // events. Stragglers (delayed agent_start emitting `running` after abort, late
    // `waiting_for_input` from a now-cancelled extension dialog, etc.) would otherwise
    // resurrect the session out of `cancelled`/`failed`/`completed` and re-open the HUD
    // loading state. The supervisor's steer/followUp paths intentionally bypass this
    // handler when they want to revive a terminal session.
    if (isTerminalStatus(currentSession.status)) return;

    const patch: Partial<PickyAgentSession> = { status: event.status, lastSummary: finalAnswer ? summaryFromFinalAnswer(finalAnswer) : event.summary };
    if (terminal) {
      patch.thinkingPreview = undefined;
      patch.tools = settleActiveTools(currentSession.tools, terminalToolPreview(event.status));
    }
    if (finalAnswer) {
      patch.finalAnswer = finalAnswer;
      patch.changedFiles = mergeChangedFiles(currentSession.changedFiles, extractChangedFilesFromExplicitText(finalAnswer));
    }
    await this.dependencies.patchSession(sessionId, patch);
    if (terminal) {
      this.assistantDrafts.set(sessionId, "");
      this.thinkingDrafts.set(sessionId, "");
      // Synthetic completions (Pi `/slash` handlers, `input` handlers returning `handled`) flip
      // the session out of the loading state but did not run any agent turn. Re-materializing
      // terminal artifacts would overwrite the previous session report with empty content, and
      // notifying the main agent would deliver a bogus "side session finished" message even
      // though nothing actually completed. Skip both for `noTurnRan` events.
      if (event.noTurnRan) return;
      await this.dependencies.materializeTerminalArtifacts(sessionId);
      if (this.dependencies.isSideSession(sessionId)) await this.dependencies.notifySideCompletion(sessionId);
    }
  }

  private async applyThinkingEvent(sessionId: string, event: Extract<RuntimeEvent, { type: "thinking_delta" }>): Promise<void> {
    if (!event.delta) return;

    const previousDraft = this.thinkingDrafts.get(sessionId) ?? "";
    if (previousDraft.length >= THINKING_DRAFT_CHAR_LIMIT) return;

    const nextDraft = sliceUtf16Safe(`${previousDraft}${event.delta}`, THINKING_DRAFT_CHAR_LIMIT);
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
  return `${sliceUtf16Safe(compact, THINKING_PREVIEW_CHAR_LIMIT - 1)}…`;
}

function terminalToolPreview(status: string): string {
  if (status === "cancelled") return "Tool stopped because the session was cancelled.";
  if (status === "failed") return "Tool stopped because the session failed.";
  return "Tool stopped when the session ended.";
}
