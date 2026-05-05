import { randomUUID } from "node:crypto";
import type { PickyExtensionUiRequest, PickyFinalReport, PickySessionMessage } from "./protocol.js";

type MessageOrigin = "user" | "main_agent" | "pi_extension";

export interface SessionMessageBuilderDeps {
  emitAppended(sessionId: string, message: PickySessionMessage, seq: number): Promise<void>;
  emitReplaced(sessionId: string, messageId: string, message: PickySessionMessage, seq: number): Promise<void>;
  emitRemoved(sessionId: string, messageId: string, seq: number): Promise<void>;
  nextSeq(sessionId: string): number;
  now(): string;
  syncSessionMessages(sessionId: string, messages: readonly PickySessionMessage[]): Promise<void>;
}

interface JournalEntry {
  seq: number;
  message: PickySessionMessage;
}

interface SessionState {
  journal: JournalEntry[];
  removedIds: Set<string>;
  assistantDraft: string;
  thinkingDraft: string;
  activeThinkingId?: string;
}

export class SessionMessageBuilder {
  private readonly states = new Map<string, SessionState>();
  private readonly operationChains = new Map<string, Promise<void>>();

  constructor(private readonly deps: SessionMessageBuilderDeps) {}

  async recordUserText(sessionId: string, text: string, originatedBy: MessageOrigin): Promise<void> {
    await this.flushAssistantText(sessionId);
    await this.flushThinking(sessionId);
    const trimmed = text.trim();
    if (!trimmed) return;
    await this.appendInternal(sessionId, {
      id: `msg-user-${randomUUID()}`,
      kind: "user_text",
      createdAt: this.deps.now(),
      originatedBy,
      text: trimmed,
    });
  }

  async seedPinnedSession(sessionId: string, transcript: string | undefined, finalAnswer: string | undefined, title: string): Promise<void> {
    const goal = firstNonEmptyLine(transcript) ?? (title.trim() || "(no goal supplied)");
    await this.appendInternal(sessionId, {
      id: `msg-pin-user-${sessionId}`,
      kind: "user_text",
      createdAt: this.deps.now(),
      originatedBy: "pi_extension",
      text: goal,
    });
    await this.appendInternal(sessionId, {
      id: `msg-pin-system-${sessionId}`,
      kind: "system",
      createdAt: this.deps.now(),
      text: "Pinned from idle Pi session",
    });
    if (finalAnswer?.trim()) {
      await this.appendInternal(sessionId, {
        id: `msg-pin-agent-${sessionId}`,
        kind: "agent_text",
        createdAt: this.deps.now(),
        text: finalAnswer.trim(),
      });
    }
  }

  async recordExtensionQuestion(sessionId: string, request: PickyExtensionUiRequest): Promise<void> {
    await this.appendInternal(sessionId, {
      id: request.id,
      kind: "agent_question",
      createdAt: this.deps.now(),
      question: request,
    });
  }

  async cancelExtensionQuestion(sessionId: string, requestId: string): Promise<void> {
    const state = this.states.get(sessionId);
    const entry = state?.journal.find((candidate) => candidate.message.id === requestId);
    if (!state || !entry || state.removedIds.has(requestId) || entry.message.cancelledAt) return;
    await this.replaceInternal(sessionId, requestId, { ...entry.message, cancelledAt: this.deps.now() });
  }

  async recordFinalReport(sessionId: string, report: PickyFinalReport): Promise<string> {
    const id = `msg-report-${randomUUID()}`;
    await this.appendInternal(sessionId, {
      id,
      kind: "agent_report",
      createdAt: this.deps.now(),
      report,
    });
    return id;
  }

  async recordError(sessionId: string, errorMessage: string, errorContext?: string): Promise<void> {
    await this.appendInternal(sessionId, {
      id: `msg-error-${randomUUID()}`,
      kind: "agent_error",
      createdAt: this.deps.now(),
      errorMessage,
      ...(errorContext ? { errorContext } : {}),
    });
  }

  async recordSystemMessage(sessionId: string, text: string): Promise<void> {
    await this.appendInternal(sessionId, {
      id: `msg-system-${randomUUID()}`,
      kind: "system",
      createdAt: this.deps.now(),
      text,
    });
  }

  appendAssistantDelta(sessionId: string, delta: string): void {
    if (!delta) return;
    void this.flushThinking(sessionId);
    const state = this.stateFor(sessionId);
    state.assistantDraft += delta;
  }

  async flushAssistantText(sessionId: string): Promise<void> {
    const state = this.states.get(sessionId);
    if (!state?.assistantDraft) return;
    const text = state.assistantDraft;
    state.assistantDraft = "";
    await this.enqueue(sessionId, async () => this.appendAssistantTextNow(sessionId, text));
  }

  async appendThinkingDelta(sessionId: string, delta: string): Promise<void> {
    await this.enqueue(sessionId, async () => this.appendThinkingDeltaNow(sessionId, delta));
  }

  async flushThinking(sessionId: string): Promise<void> {
    await this.enqueue(sessionId, async () => this.flushThinkingNow(sessionId));
  }

  hydrateSession(sessionId: string, messages: readonly PickySessionMessage[] | undefined): void {
    if (!messages?.length) return;
    this.states.set(sessionId, {
      journal: messages.map((message, index) => ({ seq: index + 1, message })),
      removedIds: new Set(),
      assistantDraft: "",
      thinkingDraft: "",
    });
  }

  onSessionRemoved(sessionId: string): void {
    this.states.delete(sessionId);
    this.operationChains.delete(sessionId);
  }

  private async appendAssistantTextNow(sessionId: string, text: string): Promise<void> {
    if (!text) return;
    await this.appendInternal(sessionId, {
      id: `msg-agent-text-${randomUUID()}`,
      kind: "agent_text",
      createdAt: this.deps.now(),
      text,
    });
  }

  private async appendThinkingDeltaNow(sessionId: string, delta: string): Promise<void> {
    if (!delta) return;
    const state = this.stateFor(sessionId);
    state.thinkingDraft += delta;
    if (!state.activeThinkingId) {
      const id = `msg-thinking-${randomUUID()}`;
      state.activeThinkingId = id;
      await this.appendInternal(sessionId, {
        id,
        kind: "agent_thinking",
        createdAt: this.deps.now(),
        text: state.thinkingDraft,
      });
      return;
    }
    const entry = state.journal.find((candidate) => candidate.message.id === state.activeThinkingId);
    if (!entry) return;
    await this.replaceInternal(sessionId, state.activeThinkingId, { ...entry.message, createdAt: this.deps.now(), text: state.thinkingDraft });
  }

  private async flushThinkingNow(sessionId: string): Promise<void> {
    const state = this.states.get(sessionId);
    if (!state?.activeThinkingId) return;
    const id = state.activeThinkingId;
    state.activeThinkingId = undefined;
    state.thinkingDraft = "";
    await this.removeInternal(sessionId, id);
  }

  private async enqueue(sessionId: string, operation: () => Promise<void>): Promise<void> {
    const previous = this.operationChains.get(sessionId) ?? Promise.resolve();
    const next = previous.then(operation);
    const tracked = next.catch(() => undefined);
    this.operationChains.set(sessionId, tracked);
    await next;
    if (this.operationChains.get(sessionId) === tracked) this.operationChains.delete(sessionId);
  }

  private async appendInternal(sessionId: string, message: PickySessionMessage): Promise<void> {
    const state = this.stateFor(sessionId);
    if (state.journal.some((entry) => entry.message.id === message.id) || state.removedIds.has(message.id)) return;
    const index = state.journal.push({ seq: 0, message }) - 1;
    await this.sync(sessionId, state);
    const seq = this.deps.nextSeq(sessionId);
    state.journal[index] = { seq, message };
    await this.deps.emitAppended(sessionId, message, seq);
  }

  private async replaceInternal(sessionId: string, messageId: string, message: PickySessionMessage): Promise<void> {
    const state = this.states.get(sessionId);
    if (!state || state.removedIds.has(messageId)) return;
    const index = state.journal.findIndex((entry) => entry.message.id === messageId);
    if (index < 0) return;
    state.journal[index] = { seq: 0, message };
    await this.sync(sessionId, state);
    const seq = this.deps.nextSeq(sessionId);
    state.journal[index] = { seq, message };
    await this.deps.emitReplaced(sessionId, messageId, message, seq);
  }

  private async removeInternal(sessionId: string, messageId: string): Promise<void> {
    const state = this.states.get(sessionId);
    if (!state || state.removedIds.has(messageId)) return;
    const index = state.journal.findIndex((entry) => entry.message.id === messageId);
    if (index < 0) return;
    state.journal.splice(index, 1);
    state.removedIds.add(messageId);
    await this.sync(sessionId, state);
    const seq = this.deps.nextSeq(sessionId);
    await this.deps.emitRemoved(sessionId, messageId, seq);
  }

  private async sync(sessionId: string, state: SessionState): Promise<void> {
    await this.deps.syncSessionMessages(sessionId, state.journal.map((entry) => entry.message));
  }

  private stateFor(sessionId: string): SessionState {
    const existing = this.states.get(sessionId);
    if (existing) return existing;
    const state: SessionState = { journal: [], removedIds: new Set(), assistantDraft: "", thinkingDraft: "" };
    this.states.set(sessionId, state);
    return state;
  }
}

function firstNonEmptyLine(value: string | undefined): string | undefined {
  return value?.split(/\r?\n/).map((line) => line.trim()).find((line) => line.length > 0);
}
