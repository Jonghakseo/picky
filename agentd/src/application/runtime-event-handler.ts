import { extractChangedFilesFromExplicitText, extractSessionLinkArtifacts } from "../artifact-store.js";
import { mergeArtifacts } from "../domain/artifacts.js";
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

interface RuntimeMessageJournal {
  recordExtensionQuestion(sessionId: string, request: PickyExtensionUiRequest): Promise<void>;
  recordExtensionNotification(sessionId: string, request: PickyExtensionUiRequest): Promise<void>;
  cancelExtensionQuestion(sessionId: string, requestId: string): Promise<void>;
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

interface RuntimeEventHandlerDependencies {
  getSession(sessionId: string): PickyAgentSession;
  patchSession(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
  consumeNoTurnRanSessionStateRestore?(sessionId: string): Partial<PickyAgentSession> | undefined;
  appendLog(sessionId: string, line: string): Promise<void>;
  materializeTerminalArtifacts(sessionId: string): Promise<void>;
  applyQueueUpdate(sessionId: string, steering: readonly string[], followUp: readonly string[]): Promise<void>;
  incrementActivity(sessionId: string, category: ToolCategory): Promise<void>;
  commitTurnActivity(sessionId: string): Promise<void>;
  notifyPickleCompletion(sessionId: string): Promise<void>;
  isPickleSession(sessionId: string): boolean;
  emitExtensionUiRequest(request: PickyExtensionUiRequest): void;
  onInputMessage?(sessionId: string, event: Extract<RuntimeEvent, { type: "input_message" }>): Promise<void>;
  messageBuilder: RuntimeMessageJournal;
}

const THINKING_PREVIEW_CHAR_LIMIT = 240;
const THINKING_DRAFT_CHAR_LIMIT = THINKING_PREVIEW_CHAR_LIMIT * 4;

type MainRealtimeRuntimeEvent = Extract<RuntimeEvent, { type: `main_realtime_${string}` }>;

function isMainRealtimeRuntimeEvent(event: RuntimeEvent): event is MainRealtimeRuntimeEvent {
  switch (event.type) {
    case "main_realtime_state":
    case "main_realtime_input_transcript_delta":
    case "main_realtime_input_transcript_completed":
    case "main_realtime_output_audio_delta":
    case "main_realtime_output_audio_done":
    case "main_realtime_output_transcript_delta":
    case "main_realtime_output_transcript_completed":
    case "main_realtime_turn_done":
      return true;
    default:
      return false;
  }
}

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
    if (event.type === "input_message") {
      const currentStatus = this.dependencies.getSession(sessionId).status;
      if (isTerminalStatus(currentStatus) && currentStatus !== "completed") return;
      return this.applyInputMessageEvent(sessionId, event);
    }
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
      if (isIgnoredFireAndForgetExtensionUi(event)) return;
      this.thinkingActive.set(sessionId, false);
      logAgentd("extension ui event", { sessionId, waitsForInput: event.waitsForInput, method: typeof event.request.method === "string" ? event.request.method : undefined });
      return this.applyExtensionUiEvent(sessionId, event.request, event.waitsForInput);
    }
    if (event.type === "session_info") return this.applySessionInfoEvent(sessionId, event.name);
    if (event.type === "context_usage") return this.applyContextUsageEvent(sessionId, event.usage);
    if (event.type === "session_replaced") return;
    // turn_text_complete is a main-runtime-only signal used by SessionSupervisor.applyMainRuntimeEvent
    // to flush per-turn assistant text as a separate quickReply for TTS playback. Pickle session
    // runtimes already flush assistant text via assistant_delta + terminal status, so this event
    // has no meaning here and must be ignored before falling through to applyToolEvent.
    if (event.type === "turn_text_complete") return;
    if (isMainRealtimeRuntimeEvent(event)) return;
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
    // Once a session has reached a terminal status, ignore any subsequent runtime status
    // events. Stragglers (delayed agent_start emitting `running` after abort, late
    // `waiting_for_input` from a now-cancelled extension dialog, etc.) would otherwise
    // resurrect the session out of `cancelled`/`failed`/`completed` and re-open the HUD
    // loading state. Completed sessions are the exception: Pi may auto-compact immediately after a
    // successful terminal agent_end (threshold compaction), and the HUD should still show that brief state.
    // Do not allow compaction tail events to resurrect cancelled/failed/blocked sessions.
    const terminalCompactionUpdate = currentSession.status === "completed" && (event.compactionStarted || event.compactionCompleted || event.compactionFailed);
    if (isTerminalStatus(currentSession.status) && !terminalCompactionUpdate) {
      if (event.noTurnRan) this.dependencies.consumeNoTurnRanSessionStateRestore?.(sessionId);
      return;
    }
    if (event.noTurnRan && event.preserveSessionState) {
      const restore = this.dependencies.consumeNoTurnRanSessionStateRestore?.(sessionId);
      if (restore) await this.dependencies.patchSession(sessionId, restore);
      return;
    }

    if (event.compactionCompleted && !hasLatestCompactCompletionMessage(currentSession)) {
      await this.dependencies.messageBuilder.recordSystemMessage(sessionId, event.compactionReason === "overflow" ? "Session compacted after context overflow" : "Session compacted");
    }
    if (event.compactionFailed && !hasLatestCompactFailureMessage(currentSession)) {
      await this.dependencies.messageBuilder.recordSystemMessage(sessionId, compactFailureMessage(event.summary, currentSession.contextUsage));
    }

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
      if (!event.noTurnRan && event.status === "failed" && !event.compactionFailed) await this.dependencies.messageBuilder.recordError(sessionId, event.summary ?? "Agent failed");
      if (!event.noTurnRan && event.status === "cancelled") await this.dependencies.messageBuilder.recordSystemMessage(sessionId, "Cancelled by user");
      if (currentSession.pendingExtensionUiRequest) {
        await this.dependencies.messageBuilder.cancelExtensionQuestion(sessionId, currentSession.pendingExtensionUiRequest.id);
        patch.pendingExtensionUiRequest = undefined;
      }
      patch.thinkingPreview = undefined;
      patch.tools = settleActiveTools(currentSession.tools, terminalToolPreview(event.status));
    }
    if (finalAnswer) {
      patch.finalAnswer = finalAnswer;
      patch.changedFiles = mergeChangedFiles(currentSession.changedFiles, extractChangedFilesFromExplicitText(finalAnswer));
    }
    // Surface PR/GitHub/Slack/etc. link badges in the HUD as soon as the assistant message that
    // contains the URL is committed for a non-terminal status. Previously `materializeTerminalArtifacts`
    // only ran on completed/failed/cancelled, so a `/skill:create-pr` follow-up that left the
    // session at `waiting_for_input` showed the PR URL in the bubble but no badge in the Links
    // row until either a new patch refreshed the `gh pr view` cache or the session eventually
    // terminated. Terminal events still flow through materializeTerminalArtifacts below so the
    // `artifact` listener fires there.
    if (!terminal && event.status === "waiting_for_input") {
      const flushedAssistantText = finalAnswer ?? cleanFinalAnswer(this.assistantDrafts.get(sessionId));
      if (flushedAssistantText) {
        const linkArtifacts = extractSessionLinkArtifacts(flushedAssistantText).filter((artifact) => !currentSession.artifacts.some((existing) => existing.url === artifact.url));
        if (linkArtifacts.length > 0) patch.artifacts = mergeArtifacts(currentSession.artifacts, linkArtifacts);
      }
    }
    await this.dependencies.patchSession(sessionId, patch);
    if (terminal) {
      this.assistantDrafts.set(sessionId, "");
      this.thinkingDrafts.set(sessionId, "");
      this.thinkingActive.set(sessionId, false);
      // Synthetic completions (Pi `/slash` handlers, `input` handlers returning `handled`) flip
      // the session out of the loading state but did not run any agent turn. Re-materializing
      // terminal artifacts would overwrite the previous session report with empty content, and
      // notifying Picky would deliver a bogus "Pickle session finished" message even
      // though nothing actually completed. Skip both for `noTurnRan` events.
      if (event.noTurnRan) {
        this.dependencies.consumeNoTurnRanSessionStateRestore?.(sessionId);
        return;
      }
      await this.dependencies.materializeTerminalArtifacts(sessionId);
      if (this.dependencies.isPickleSession(sessionId)) await this.dependencies.notifyPickleCompletion(sessionId);
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
      if (request.method === "setWidget") return;
      await this.dependencies.appendLog(sessionId, extensionUiLogLine(request));
      if (request.method === "notify") {
        await this.dependencies.messageBuilder.flushAssistantText(sessionId);
        await this.dependencies.messageBuilder.flushThinking(sessionId);
        await this.dependencies.messageBuilder.recordExtensionNotification(sessionId, request);
      }
      if (request.method === "set_editor_text") this.dependencies.emitExtensionUiRequest(request);
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
    // Defensive: a late `running` event for an already-settled tool would otherwise downgrade
    // the terminal status back to `running`, where settleActiveTools later flips it to `failed`.
    // The runtime chain in session-supervisor serializes events so this should not happen, but
    // keep the guard for resumed sessions or other replay paths.
    if (event.status === "running" && previous && (previous.status === "succeeded" || previous.status === "failed")) {
      logAgentd("tool activity (late running ignored)", { sessionId, tool: event.name, previousStatus: previous.status });
      return;
    }
    const tools = session.tools.filter((tool) => tool.toolCallId !== event.toolCallId);
    tools.push({
      ...previous,
      toolCallId: event.toolCallId,
      name: event.name,
      status: event.status,
      preview: event.preview,
      argsPreview: event.argsPreview ?? previous?.argsPreview,
      resultPreview: event.resultPreview ?? previous?.resultPreview,
      startedAt: previous?.startedAt ?? new Date().toISOString(),
      endedAt: event.status === "running" ? previous?.endedAt : new Date().toISOString(),
    });
    logAgentd("tool activity", { sessionId, tool: event.name, status: event.status, previewChars: event.preview?.length });
    await this.dependencies.patchSession(sessionId, { tools });
  }
}

function isIgnoredFireAndForgetExtensionUi(event: Extract<RuntimeEvent, { type: "extension_ui" }>): boolean {
  return !event.waitsForInput && event.request.method === "setWidget";
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

function hasLatestCompactCompletionMessage(session: PickyAgentSession): boolean {
  const messages = session.messages ?? [];
  const message = messages[messages.length - 1];
  if (message?.kind !== "system") return false;
  const normalized = message.text?.trim().toLowerCase();
  return normalized === "session compacted" || normalized === "session compacted after context overflow";
}

function hasLatestCompactFailureMessage(session: PickyAgentSession): boolean {
  const messages = session.messages ?? [];
  const message = messages[messages.length - 1];
  if (message?.kind !== "system") return false;
  return message.text?.trim().toLowerCase().startsWith("auto-compaction failed") === true;
}

function compactFailureMessage(summary: string | undefined, usage: PickyAgentSession["contextUsage"]): string {
  const detail = compactFailureDetail(summary);
  const usageText = usage ? ` Current usage remains ${formatTokenCount(usage.tokens)}/${formatTokenCount(usage.contextWindow)} tokens.` : "";
  return `Auto-compaction failed\n\n${detail}\n\nContext was not reduced.${usageText}`;
}

function compactFailureDetail(summary: string | undefined): string {
  const trimmed = summary?.trim() || "Summarization failed.";
  const withoutPrefix = trimmed.replace(/^auto-compaction failed:\s*/i, "").trim();
  return sliceUtf16Safe(withoutPrefix || trimmed, 500);
}

function formatTokenCount(value: number | null | undefined): string {
  return typeof value === "number" ? Math.round(value).toLocaleString("en-US") : "unknown";
}

function terminalToolPreview(status: string): string {
  if (status === "cancelled") return "Tool stopped because the session was cancelled.";
  if (status === "failed") return "Tool stopped because the session failed.";
  return "Tool stopped when the session ended.";
}
