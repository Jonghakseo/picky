import { extractChangedFilesFromExplicitText } from "../artifact-store.js";
import { mergeChangedFiles } from "../domain/changed-files.js";
import { sliceUtf16Safe } from "../domain/safe-truncate.js";
import { isTerminalStatus } from "../domain/session-status.js";
import { cleanFinalAnswer, summaryFromFinalAnswer } from "../domain/session-summary.js";
import { settleActiveTools } from "../domain/tool-activity.js";
import { categorizeTool, type ToolCategory } from "../domain/tool-categorizer.js";
import { logAgentd } from "../local-log.js";
import type { PickyActivitySummary, PickyAgentSession, PickyAssistantRunMetadata, PickyExtensionUiRequest } from "../protocol.js";
import type { RuntimeEvent } from "../runtime/types.js";
import { extensionUiLogLine, extensionUiWaitingSummary, mapExtensionUiRequest } from "./extension-ui-request-mapper.js";

export interface RuntimeMessageJournal {
  recordExtensionQuestion(sessionId: string, request: PickyExtensionUiRequest): Promise<void>;
  recordError(sessionId: string, errorMessage: string, errorContext?: string): Promise<void>;
  recordSystemMessage(sessionId: string, text: string): Promise<void>;
  recordUserText(sessionId: string, text: string, originatedBy: "user" | "main_agent" | "pi_extension"): Promise<void>;
  appendAssistantDelta(sessionId: string, delta: string): void;
  flushAssistantText(sessionId: string, assistantRun?: PickyAssistantRunMetadata): Promise<void>;
  appendThinkingDelta(sessionId: string, delta: string): Promise<void>;
  flushThinking(sessionId: string): Promise<void>;
  clearAllThinking(sessionId: string): Promise<void>;
  recordActivitySnapshot(sessionId: string, activitySnapshot: PickyActivitySummary): Promise<void>;
}

export interface RuntimeEventHandlerDependencies {
  getSession(sessionId: string): PickyAgentSession;
  patchSession(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
  consumeNoTurnRanSessionStateRestore?(sessionId: string): Partial<PickyAgentSession> | undefined;
  appendLog(sessionId: string, line: string): Promise<void>;
  materializeTerminalArtifacts(sessionId: string): Promise<void>;
  applyQueueUpdate(sessionId: string, steering: readonly string[], followUp: readonly string[]): Promise<void>;
  incrementActivity(sessionId: string, category: ToolCategory): Promise<void>;
  commitTurnActivity(sessionId: string): Promise<void>;
  notifySideCompletion(sessionId: string): Promise<void>;
  isSideSession(sessionId: string): boolean;
  emitExtensionUiRequest(request: PickyExtensionUiRequest): void;
  onInputMessage?(sessionId: string, event: Extract<RuntimeEvent, { type: "input_message" }>): Promise<void>;
  messageBuilder: RuntimeMessageJournal;
}

const THINKING_PREVIEW_CHAR_LIMIT = 240;
const THINKING_DRAFT_CHAR_LIMIT = THINKING_PREVIEW_CHAR_LIMIT * 4;

export class RuntimeEventHandler {
  private readonly assistantDrafts = new Map<string, string>();
  private readonly thinkingDrafts = new Map<string, string>();
  private readonly thinkingActive = new Map<string, boolean>();
  private readonly seenToolCallIds = new Map<string, Set<string>>();

  constructor(private readonly dependencies: RuntimeEventHandlerDependencies) {}

  resetAssistantDraft(sessionId: string): void {
    this.assistantDrafts.set(sessionId, "");
    this.thinkingDrafts.set(sessionId, "");
    this.thinkingActive.set(sessionId, false);
    this.seenToolCallIds.delete(sessionId);
  }

  async handle(sessionId: string, event: RuntimeEvent): Promise<void> {
    if (event.type === "log") return this.dependencies.appendLog(sessionId, event.line);
    if (event.type === "input_message") return this.applyInputMessageEvent(sessionId, event);
    if (event.type !== "status" && isTerminalStatus(this.dependencies.getSession(sessionId).status)) return;
    if (event.type === "assistant_delta") {
      this.thinkingActive.set(sessionId, false);
      this.dependencies.messageBuilder.appendAssistantDelta(sessionId, event.delta);
      this.assistantDrafts.set(sessionId, `${this.assistantDrafts.get(sessionId) ?? ""}${event.delta}`);
      return;
    }
    if (event.type === "thinking_delta") return this.applyThinkingEvent(sessionId, event);
    if (event.type === "queue_update") return this.dependencies.applyQueueUpdate(sessionId, event.steering, event.followUp);
    if (event.type === "status") {
      this.thinkingActive.set(sessionId, false);
      return this.applyStatusEvent(sessionId, event);
    }
    if (event.type === "extension_ui") {
      this.thinkingActive.set(sessionId, false);
      logAgentd("extension ui event", { sessionId, waitsForInput: event.waitsForInput, method: typeof event.request.method === "string" ? event.request.method : undefined });
      return this.applyExtensionUiEvent(sessionId, event.request, event.waitsForInput);
    }
    if (event.type === "session_info") return this.applySessionInfoEvent(sessionId, event.name);
    if (event.type === "context_usage") return this.applyContextUsageEvent(sessionId, event.usage);
    return this.applyToolEvent(sessionId, event);
  }

  private async applyInputMessageEvent(sessionId: string, event: Extract<RuntimeEvent, { type: "input_message" }>): Promise<void> {
    if (event.originatedBy === "internal" || event.display === false) return;
    await this.dependencies.onInputMessage?.(sessionId, event);
    await this.dependencies.messageBuilder.flushAssistantText(sessionId);
    await this.dependencies.messageBuilder.flushThinking(sessionId);
    await this.dependencies.commitTurnActivity(sessionId);
    await this.dependencies.messageBuilder.recordUserText(sessionId, event.text, event.originatedBy === "pi_extension" ? "pi_extension" : event.originatedBy);
    this.assistantDrafts.set(sessionId, "");
    this.thinkingDrafts.set(sessionId, "");
    this.thinkingActive.set(sessionId, false);
    await this.dependencies.patchSession(sessionId, { status: "running", lastSummary: event.role === "custom" ? "Pi extension message started" : "Pi extension follow-up started", finalAnswer: undefined, thinkingPreview: undefined });
  }

  private async applyContextUsageEvent(sessionId: string, usage: { tokens: number | null; contextWindow: number; percent: number | null } | undefined): Promise<void> {
    const current = this.dependencies.getSession(sessionId).contextUsage;
    if (sameContextUsage(current, usage)) return;
    await this.dependencies.patchSession(sessionId, { contextUsage: usage });
  }

  private async applySessionInfoEvent(sessionId: string, name: string): Promise<void> {
    const trimmed = name.trim();
    if (!trimmed) return;
    const session = this.dependencies.getSession(sessionId);
    if (session.title === trimmed) return;
    logAgentd("session info name", { sessionId, previousTitle: session.title, name: trimmed });
    await this.dependencies.patchSession(sessionId, { title: trimmed });
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
    const finalAnswer = explicitFinalAnswer ?? (terminal ? (event.status === "failed" ? undefined : cleanFinalAnswer(this.assistantDrafts.get(sessionId))) : undefined);
    const currentSession = this.dependencies.getSession(sessionId);
    if (event.noTurnRan && event.preserveSessionState) {
      const restore = this.dependencies.consumeNoTurnRanSessionStateRestore?.(sessionId);
      if (restore) await this.dependencies.patchSession(sessionId, restore);
      return;
    }
    // Once a session has reached a terminal status, ignore any subsequent runtime status
    // events. Stragglers (delayed agent_start emitting `running` after abort, late
    // `waiting_for_input` from a now-cancelled extension dialog, etc.) would otherwise
    // resurrect the session out of `cancelled`/`failed`/`completed` and re-open the HUD
    // loading state. The supervisor's steer/followUp paths intentionally bypass this
    // handler when they want to revive a terminal session.
    if (isTerminalStatus(currentSession.status)) return;

    const patch: Partial<PickyAgentSession> = { status: event.status, lastSummary: finalAnswer ? summaryFromFinalAnswer(finalAnswer) : event.summary };
    if (event.assistantRun) patch.currentAssistantRun = event.assistantRun;
    if (terminal || event.status === "waiting_for_input" || finalAnswer) {
      await this.dependencies.messageBuilder.flushAssistantText(sessionId, event.assistantRun);
      if (terminal) {
        await this.dependencies.messageBuilder.clearAllThinking(sessionId);
      } else {
        await this.dependencies.messageBuilder.flushThinking(sessionId);
      }
      await this.dependencies.commitTurnActivity(sessionId);
    }
    if (terminal) {
      if (!event.noTurnRan && event.status === "failed") await this.dependencies.messageBuilder.recordError(sessionId, event.summary ?? "Agent failed");
      if (!event.noTurnRan && event.status === "cancelled") await this.dependencies.messageBuilder.recordSystemMessage(sessionId, "Cancelled by user");
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
      this.thinkingActive.set(sessionId, false);
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

    const shouldIncrementThinking = this.thinkingActive.get(sessionId) !== true;
    if (shouldIncrementThinking) this.thinkingActive.set(sessionId, true);

    const previousDraft = this.thinkingDrafts.get(sessionId) ?? "";
    if (previousDraft.length >= THINKING_DRAFT_CHAR_LIMIT) {
      if (shouldIncrementThinking) await this.dependencies.incrementActivity(sessionId, "thinking");
      return;
    }

    const nextDraft = sliceUtf16Safe(`${previousDraft}${event.delta}`, THINKING_DRAFT_CHAR_LIMIT);
    this.thinkingDrafts.set(sessionId, nextDraft);

    await this.dependencies.messageBuilder.appendThinkingDelta(sessionId, event.delta);
    if (shouldIncrementThinking) await this.dependencies.incrementActivity(sessionId, "thinking");

    const thinkingPreview = compactThinkingPreview(this.thinkingDrafts.get(sessionId) ?? nextDraft);
    if (!thinkingPreview || thinkingPreview === this.dependencies.getSession(sessionId).thinkingPreview) return;

    await this.dependencies.patchSession(sessionId, { thinkingPreview });
  }

  private async applyExtensionUiEvent(sessionId: string, rawRequest: Record<string, unknown>, waitsForInput: boolean): Promise<void> {
    const request = mapExtensionUiRequest(rawRequest);
    if (!waitsForInput) {
      await this.dependencies.appendLog(sessionId, extensionUiLogLine(request));
      return;
    }
    await this.dependencies.messageBuilder.flushAssistantText(sessionId);
    await this.dependencies.messageBuilder.flushThinking(sessionId);
    await this.dependencies.commitTurnActivity(sessionId);
    await this.dependencies.patchSession(sessionId, { status: "waiting_for_input", pendingExtensionUiRequest: request, lastSummary: extensionUiWaitingSummary(request) });
    await this.dependencies.messageBuilder.recordExtensionQuestion(sessionId, request);
    this.dependencies.emitExtensionUiRequest(request);
  }

  private async applyToolEvent(sessionId: string, event: Extract<RuntimeEvent, { type: "tool" }>): Promise<void> {
    this.thinkingActive.set(sessionId, false);
    const seen = this.seenToolCallIds.get(sessionId) ?? new Set<string>();
    const shouldIncrementActivity = event.status === "running" && !seen.has(event.toolCallId);
    if (shouldIncrementActivity) {
      seen.add(event.toolCallId);
      this.seenToolCallIds.set(sessionId, seen);
    }
    if (event.status === "running") {
      await this.dependencies.messageBuilder.flushAssistantText(sessionId);
      await this.dependencies.messageBuilder.flushThinking(sessionId);
    }
    if (shouldIncrementActivity) await this.dependencies.incrementActivity(sessionId, categorizeTool(event.name));

    const session = this.dependencies.getSession(sessionId);
    const previous = session.tools.find((tool) => tool.toolCallId === event.toolCallId);
    const tools = session.tools.filter((tool) => tool.toolCallId !== event.toolCallId);
    tools.push({ ...previous, toolCallId: event.toolCallId, name: event.name, status: event.status, preview: event.preview, startedAt: previous?.startedAt ?? new Date().toISOString(), endedAt: event.status === "running" ? previous?.endedAt : new Date().toISOString() });
    logAgentd("tool activity", { sessionId, tool: event.name, status: event.status, previewChars: event.preview?.length });
    await this.dependencies.patchSession(sessionId, { tools });
  }
}

function sameContextUsage(
  a: { tokens: number | null; contextWindow: number; percent: number | null } | undefined,
  b: { tokens: number | null; contextWindow: number; percent: number | null } | undefined,
): boolean {
  if (a === b) return true;
  if (!a || !b) return false;
  return a.tokens === b.tokens && a.contextWindow === b.contextWindow && a.percent === b.percent;
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
