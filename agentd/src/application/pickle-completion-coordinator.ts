import { buildMainAgentPickleCompletionPrompt, type BuiltPrompt } from "../prompt-builder.js";
import type { PickyAgentSession } from "../protocol.js";
import type { RuntimeEvent, RuntimeSessionHandle } from "../runtime/types.js";

export type PickleCompletionChannelSnapshot = Readonly<{
  notifyMainOnCompletion: boolean;
  notifyMacOSOnCompletion: boolean;
}>;

export type PickleCompletionForwardRequest = {
  sessionId: string;
  prompt: string;
  cwd?: string;
  completionId: string;
  title: string;
  status: "completed";
  summary?: string;
  notifyMainOnCompletion: boolean;
  notifyMacOSOnCompletion: boolean;
};

export type ExternalPickleCompletionRequest = {
  sessionId: string;
  prompt: string;
  cwd?: string;
  completionId?: string;
  title?: string;
  status?: string;
  summary?: string;
  notifyMainOnCompletion?: boolean;
  notifyMacOSOnCompletion?: boolean;
};

type AcceptedExternalPickleCompletion = {
  sessionId: string;
  prompt: string;
  cwd?: string;
  completionId: string;
};

type MainDelivery = {
  handle: RuntimeSessionHandle;
  sendAsFollowUp: boolean;
};

export interface PickleCompletionCoordinatorDeps {
  session(sessionId: string): PickyAgentSession | undefined;
  isMainProcessing(): boolean;
  hasMainRuntime(): boolean;
  forwardCompletion?: (request: PickleCompletionForwardRequest) => Promise<void>;
  prepareMainDelivery(prompt: BuiltPrompt, cwd?: string): Promise<MainDelivery | undefined>;
  activateLocalReplyContext(sessionId: string): void;
  activateExternalReplyContext(sessionId: string): void;
  deactivateExternalReplyContext(sessionId: string): void;
  setMainProcessing(processing: boolean): void;
  resetMainTerminal(): void;
  log(message: string, fields: Record<string, string | number | boolean | undefined>): void;
}

/**
 * Owns Pickle completion delivery state: durable bell snapshots, deferred local
 * delivery, and primary-daemon admission of child completion envelopes.
 * SessionSupervisor retains session and main-runtime ownership, exposed here
 * only through narrow delivery callbacks.
 */
export class PickleCompletionCoordinator {
  private notifiedSessionIds = new Set<string>();
  private inFlightSessionIds = new Set<string>();
  private channelSnapshots = new Map<string, PickleCompletionChannelSnapshot>();
  private pendingLocalSessionIds: string[] = [];
  private pendingExternal: AcceptedExternalPickleCompletion[] = [];
  private acceptedExternalIds = new Set<string>();
  private externalAdmissions = new Map<string, Promise<void>>();
  private externalAdmissionChain = Promise.resolve();
  private drainPromise?: Promise<void>;

  constructor(private readonly deps: PickleCompletionCoordinatorDeps) {}

  async notifyLocalCompletion(sessionId: string, committedSession?: PickyAgentSession): Promise<void> {
    const session = committedSession ?? this.deps.session(sessionId);
    if (!session || session.status !== "completed") return;
    const channels = this.channelSnapshots.get(sessionId) ?? {
      notifyMainOnCompletion: session.notifyMainOnCompletion === true,
      notifyMacOSOnCompletion: session.notifyMacOSOnCompletion === true,
    };
    if (!channels.notifyMainOnCompletion && !channels.notifyMacOSOnCompletion) return;
    this.channelSnapshots.set(sessionId, channels);
    if (this.notifiedSessionIds.has(sessionId) || this.inFlightSessionIds.has(sessionId)) return;

    if (this.deps.isMainProcessing() && !this.deps.forwardCompletion) {
      if (!this.pendingLocalSessionIds.includes(sessionId)) {
        this.pendingLocalSessionIds.push(sessionId);
        this.deps.log("Pickle completion deferred", { sessionId, status: session.status, queueLength: this.pendingLocalSessionIds.length });
      }
      return;
    }
    await this.deliverLocalCompletion(sessionId, channels);
  }

  deliverExternalCompletion(
    requestOrSessionId: ExternalPickleCompletionRequest | string,
    legacyPrompt?: string,
    legacyCwd?: string,
  ): Promise<void> {
    const request = typeof requestOrSessionId === "string"
      ? { sessionId: requestOrSessionId, prompt: legacyPrompt ?? "", cwd: legacyCwd }
      : requestOrSessionId;
    if (request.status && request.status !== "completed") return Promise.resolve();
    const completionId = request.completionId ?? `legacy:${request.sessionId}:${request.prompt}`;
    if (this.acceptedExternalIds.has(completionId)) return Promise.resolve();
    const existingAdmission = this.externalAdmissions.get(completionId);
    if (existingAdmission) return existingAdmission;

    const admission = this.externalAdmissionChain
      .catch(() => undefined)
      .then(() => this.admitExternalCompletion({
        sessionId: request.sessionId,
        prompt: request.prompt,
        cwd: request.cwd,
        completionId,
      }))
      .then(() => { this.acceptedExternalIds.add(completionId); });
    const trackedAdmission = admission.finally(() => {
      if (this.externalAdmissions.get(completionId) === trackedAdmission) {
        this.externalAdmissions.delete(completionId);
      }
    });
    this.externalAdmissions.set(completionId, trackedAdmission);
    this.externalAdmissionChain = admission.catch(() => undefined);
    return trackedAdmission;
  }

  handleExternalInputDelivery(event: Extract<RuntimeEvent, { type: "input_delivery" }>): void {
    const completion = this.pendingExternal[0];
    if (!completion
      || event.role !== "user"
      || event.originatedBy !== "internal"
      || event.text !== completion.prompt) return;

    this.pendingExternal.shift();
    this.deps.activateExternalReplyContext(completion.sessionId);
    this.deps.resetMainTerminal();
    this.deps.log("Pickle completion forwarded notify started", {
      sessionId: completion.sessionId,
      completionId: completion.completionId,
      queueLength: this.pendingExternal.length,
    });
  }

  scheduleLocalDrain(): void {
    void this.runLocalDrain().catch((error) => {
      this.deps.log("Pickle completion drain failed", {
        error: error instanceof Error ? error.message : String(error),
      });
    });
  }

  clearLocalTracking(sessionId: string): void {
    this.notifiedSessionIds.delete(sessionId);
    this.inFlightSessionIds.delete(sessionId);
    this.channelSnapshots.delete(sessionId);
    const queueIndex = this.pendingLocalSessionIds.indexOf(sessionId);
    if (queueIndex >= 0) {
      this.pendingLocalSessionIds.splice(queueIndex, 1);
      this.deps.log("Pickle completion dequeued", { sessionId, queueLength: this.pendingLocalSessionIds.length });
    }
  }

  reset(): void {
    const pendingCount = this.pendingLocalSessionIds.length + this.pendingExternal.length;
    if (pendingCount > 0) this.deps.log("Picky pending Pickle completions cleared", { count: pendingCount });
    this.pendingLocalSessionIds = [];
    this.channelSnapshots.clear();
    this.pendingExternal = [];
    this.acceptedExternalIds.clear();
    this.externalAdmissions.clear();
    this.externalAdmissionChain = Promise.resolve();
  }

  private async deliverLocalCompletion(sessionId: string, channelSnapshot?: PickleCompletionChannelSnapshot): Promise<void> {
    this.pendingLocalSessionIds = this.pendingLocalSessionIds.filter((pendingSessionId) => pendingSessionId !== sessionId);
    if (this.notifiedSessionIds.has(sessionId) || this.inFlightSessionIds.has(sessionId)) return;
    const session = this.deps.session(sessionId);
    if (!session || session.status !== "completed") return;
    const channels = channelSnapshot ?? this.channelSnapshots.get(sessionId) ?? {
      notifyMainOnCompletion: session.notifyMainOnCompletion === true,
      notifyMacOSOnCompletion: session.notifyMacOSOnCompletion === true,
    };
    if (!channels.notifyMainOnCompletion && !channels.notifyMacOSOnCompletion) return;
    this.inFlightSessionIds.add(sessionId);
    try {
      const prompt = buildMainAgentPickleCompletionPrompt(session);
      if (this.deps.forwardCompletion) {
        try {
          await this.deps.forwardCompletion({
            sessionId,
            prompt: prompt.text,
            cwd: session.cwd,
            completionId: `${sessionId}:${session.revision ?? 0}`,
            title: session.title,
            status: "completed",
            summary: session.lastSummary,
            notifyMainOnCompletion: channels.notifyMainOnCompletion,
            notifyMacOSOnCompletion: channels.notifyMacOSOnCompletion,
          });
          this.notifiedSessionIds.add(sessionId);
          this.deps.log("Pickle completion forwarded to app coordinator", { sessionId, status: session.status });
        } catch (error) {
          this.deps.log("Pickle completion forward failed", { sessionId, error: error instanceof Error ? error.message : String(error) });
        }
        return;
      }

      if (!channels.notifyMainOnCompletion) {
        this.deps.log("Pickle macOS completion delivery unavailable without app coordinator", { sessionId });
        return;
      }
      this.deps.activateLocalReplyContext(sessionId);
      const delivery = await this.deps.prepareMainDelivery(prompt, session.cwd);
      if (!delivery) {
        this.deps.log("Pickle completion delivery unavailable", { sessionId, status: session.status });
        return;
      }

      this.notifiedSessionIds.add(sessionId);
      this.deps.resetMainTerminal();
      this.deps.setMainProcessing(true);
      this.deps.log("Pickle completion notifying Picky", { sessionId, status: session.status });
      if (delivery.sendAsFollowUp) await delivery.handle.followUp(prompt);
    } finally {
      this.inFlightSessionIds.delete(sessionId);
    }
  }

  private async admitExternalCompletion(request: AcceptedExternalPickleCompletion): Promise<void> {
    if (!this.deps.hasMainRuntime()) {
      this.deps.log("Pickle completion forwarded notify rejected", { sessionId: request.sessionId, reason: "no main runtime" });
      throw new Error("Main runtime is not configured for Pickle completion delivery");
    }

    const wasMainProcessing = this.deps.isMainProcessing();
    const prompt: BuiltPrompt = { text: request.prompt, imagePaths: [] };
    this.pendingExternal.push(request);
    if (!wasMainProcessing) this.deps.activateExternalReplyContext(request.sessionId);

    try {
      const delivery = await this.deps.prepareMainDelivery(prompt, request.cwd);
      if (!delivery) throw new Error("Main agent handle is unavailable");
      if (!wasMainProcessing) this.deps.setMainProcessing(true);
      if (delivery.sendAsFollowUp) {
        await delivery.handle.followUp(prompt);
      } else {
        this.pendingExternal = this.pendingExternal.filter((completion) => completion.completionId !== request.completionId);
      }
      this.deps.log("Pickle completion forwarded notify accepted", {
        sessionId: request.sessionId,
        completionId: request.completionId,
        queued: wasMainProcessing ? 1 : 0,
      });
    } catch (error) {
      this.pendingExternal = this.pendingExternal.filter((completion) => completion.completionId !== request.completionId);
      if (!wasMainProcessing) {
        this.deps.deactivateExternalReplyContext(request.sessionId);
        this.deps.setMainProcessing(false);
      }
      this.deps.log("Pickle completion forwarded followUp failed", {
        sessionId: request.sessionId,
        error: error instanceof Error ? error.message : String(error),
      });
      throw error;
    }
  }

  private runLocalDrain(): Promise<void> {
    if (this.drainPromise) return this.drainPromise;
    const drain = this.drainPendingLocalCompletions();
    this.drainPromise = drain;
    void drain.finally(() => {
      if (this.drainPromise === drain) this.drainPromise = undefined;
    }).catch(() => undefined);
    return drain;
  }

  private async drainPendingLocalCompletions(): Promise<void> {
    while (!this.deps.isMainProcessing()) {
      const sessionId = this.pendingLocalSessionIds.shift();
      if (!sessionId) return;
      this.deps.log("Pickle completion draining", { sessionId, queueLength: this.pendingLocalSessionIds.length });
      await this.deliverLocalCompletion(sessionId);
    }
  }
}
