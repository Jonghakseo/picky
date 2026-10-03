import { logAgentd } from "../local-log.js";
import type { RuntimeResourceReloadHost, RuntimeResourceReloadOutcome } from "./types.js";

export type ResourceReloadAttempt = "reloaded" | "failed" | "blocked" | "busy";

/** Pi reload runs third-party extension and MCP startup code; never let it hold input forever. */
export const RESOURCE_RELOAD_TIMEOUT_MS = 30_000;
/** Input waits this long for an in-flight reload, then is held and delivered when it ends. */
export const RESOURCE_RELOAD_SETTLE_WAIT_MS = 3_000;

export interface ResourceReloadSchedulerDeps {
  sessionId: string;
  isDisposed(): boolean;
  /** Pi is running a turn or compacting. */
  isBusy(): boolean;
  /** No adapter-side work in flight (prompt preflight, initial prompt, held-queue flush, dialogs). */
  isAdapterIdle(): boolean;
  hasPendingExtensionUi(): boolean;
  /** Async replacement fence; throws while async work or coverage blocks a reload. */
  prepareReplacement(): Promise<void>;
  reload(): Promise<{ supported: boolean }>;
  waitForReadiness(): Promise<void>;
  hasHeldPrompts(): boolean;
  flushHeldPrompts(): Promise<void>;
  log(line: string): void;
  emitReloaded(): void;
}

/**
 * Applies plugin changes to one Pi session without interrupting the user.
 *
 * Pi drains queued follow-ups inside the running turn and expands `/skill:` when a message is
 * queued, so a reload can only happen between turns and only helps messages that reach Pi
 * after it. The session therefore holds follow-ups while a reload is pending, and this
 * scheduler reloads at the next safe point (turn settled, compaction ended, async idle, or
 * the next idle input) before releasing them.
 *
 * Requests use a generation pair rather than a flag so a second install during an in-flight
 * reload is not lost.
 */
export class ResourceReloadScheduler {
  private requestedGeneration = 0;
  private appliedGeneration = 0;
  private drain?: Promise<RuntimeResourceReloadOutcome>;
  private timer?: ReturnType<typeof setTimeout>;
  private host?: RuntimeResourceReloadHost;
  private attempting = false;
  private rerunAfterDrain = false;
  private stalledReload?: Promise<unknown>;

  constructor(
    private readonly deps: ResourceReloadSchedulerDeps,
    private readonly timeouts: { reloadMs: number; settleWaitMs: number } = { reloadMs: RESOURCE_RELOAD_TIMEOUT_MS, settleWaitMs: RESOURCE_RELOAD_SETTLE_WAIT_MS },
  ) {}

  /**
   * Pi is reloading right now; input is held instead of entering a half-rebuilt runtime. A
   * reload past its timeout no longer counts: user input must not wait on a hung extension.
   */
  get reloading(): boolean {
    return this.attempting;
  }

  /** A drain is running; new input must queue behind prompts it is about to deliver. */
  get draining(): boolean {
    return this.drain !== undefined;
  }

  get pending(): boolean {
    return this.requestedGeneration > this.appliedGeneration;
  }

  get currentGeneration(): number {
    return this.requestedGeneration;
  }

  setHost(host: RuntimeResourceReloadHost): void {
    this.host = host;
  }

  /** A manual `/reload` that started at `generation` also satisfies earlier plugin requests. */
  markApplied(generation: number): void {
    this.appliedGeneration = Math.max(this.appliedGeneration, generation);
  }

  async request(): Promise<RuntimeResourceReloadOutcome> {
    if (this.deps.isDisposed()) return "unchanged";
    this.requestedGeneration += 1;
    // A drain already past its generation check would miss this request; let it finish first.
    while (this.drain) await this.drain.catch(() => undefined);
    return this.run();
  }

  /**
   * Completes a pending or in-flight reload before new input; never requests a new one. Waits at
   * most `settleWaitMs`, so a slow reload never blocks the caller: input arriving while Pi is
   * still reloading is held and delivered when the reload ends.
   */
  async finishBeforeInput(): Promise<RuntimeResourceReloadOutcome> {
    if (this.deps.isDisposed() || !this.hasWork()) return "unchanged";
    if (this.deps.isBusy()) return "deferred";
    let timer: ReturnType<typeof setTimeout> | undefined;
    const deadline = new Promise<RuntimeResourceReloadOutcome>((resolve) => { timer = setTimeout(() => resolve("deferred"), this.timeouts.settleWaitMs); });
    try {
      return await Promise.race([this.run(), deadline]);
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  schedule(): void {
    // A running drain may already be past the point that would pick up new work.
    if (this.drain) { this.rerunAfterDrain = true; return; }
    if (this.deps.isDisposed() || !this.hasWork() || this.timer) return;
    // Run after Pi finishes settled hooks and their deferred actions for this event.
    this.timer = setTimeout(() => {
      this.timer = undefined;
      void this.run();
    }, 0);
  }

  dispose(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
  }

  run(): Promise<RuntimeResourceReloadOutcome> {
    if (!this.drain) {
      this.drain = this.drainOnce()
        .catch((error): RuntimeResourceReloadOutcome => {
          logAgentd("pi resource reload drain failed", { sessionId: this.deps.sessionId, error: messageOf(error) });
          return "deferred";
        })
        .finally(() => {
          this.drain = undefined;
          if (this.rerunAfterDrain) { this.rerunAfterDrain = false; this.schedule(); }
        });
    }
    return this.drain;
  }

  private hasWork(): boolean {
    // Held prompts count: a turn that started during the reload must not strand them.
    return this.pending || this.drain !== undefined || this.deps.hasHeldPrompts();
  }

  private canReloadNow(): boolean {
    return !this.deps.isDisposed() && !this.deps.isBusy() && this.deps.isAdapterIdle() && this.stalledReload === undefined;
  }

  private async drainOnce(): Promise<RuntimeResourceReloadOutcome> {
    let outcome: RuntimeResourceReloadOutcome = "unchanged";
    let blocked = false;
    while (this.pending) {
      if (!this.canReloadNow()) {
        outcome = "deferred";
        // An idle extension dialog or a timed-out reload has no settle event to retry from soon;
        // don't hold input behind it. The reload stays pending.
        blocked = !this.deps.isBusy() && (this.deps.hasPendingExtensionUi() || this.stalledReload !== undefined);
        break;
      }
      const target = this.requestedGeneration;
      const attempt = await this.attempt();
      if (attempt === "blocked") { outcome = "deferred"; blocked = true; break; }
      if (attempt === "busy") { outcome = "deferred"; break; }
      // A failed reload is reported and not retried in a loop; the app offers a retry, which
      // requests a new generation.
      this.markApplied(target);
      outcome = attempt === "failed" ? "failed" : "reloaded";
      if (attempt === "failed") break;
    }
    // Held follow-ups wait only for the reload, never for unrelated async work. If async work
    // blocks the reload, deliver them now with current resources and retry the reload later.
    if ((!this.pending || blocked) && !this.deps.isBusy()) await this.deliverHeldPrompts();
    return outcome;
  }

  private async attempt(): Promise<ResourceReloadAttempt> {
    try {
      await this.deps.prepareReplacement();
    } catch (error) {
      logAgentd("pi resource reload waiting for async work", { sessionId: this.deps.sessionId, error: messageOf(error) });
      return "blocked";
    }
    // Async preparation awaits; a turn may have started meanwhile.
    if (!this.canReloadNow()) return "busy";
    this.attempting = true;
    const work = (async () => {
      const outcome = await this.deps.reload();
      if (!outcome.supported) return false;
      await this.deps.waitForReadiness();
      return true;
    })();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timedOut = Symbol("timedOut");
    try {
      const result = await Promise.race([work, new Promise<typeof timedOut>((resolve) => { timer = setTimeout(() => resolve(timedOut), this.timeouts.reloadMs); })]);
      if (result === timedOut) {
        // Keep later reloads off the runtime until Pi finishes, but stop holding user input.
        const stalled = work.catch(() => undefined).finally(() => { if (this.stalledReload === stalled) this.stalledReload = undefined; this.schedule(); });
        this.stalledReload = stalled;
        logAgentd("pi resource reload timed out", { sessionId: this.deps.sessionId, timeoutMs: this.timeouts.reloadMs });
        this.deps.log("plugin reload is taking too long; continuing with the current plugins");
        return "failed";
      }
      if (!result) {
        this.deps.log("plugin reload skipped: this Pi runtime cannot reload resources");
        return "failed";
      }
    } catch (error) {
      const message = messageOf(error);
      logAgentd("pi resource reload failed", { sessionId: this.deps.sessionId, error: message });
      this.deps.log(`plugin reload failed: ${message}`);
      return "failed";
    } finally {
      if (timer) clearTimeout(timer);
      this.attempting = false;
    }
    logAgentd("pi resources reloaded for plugin change", { sessionId: this.deps.sessionId });
    this.deps.log("pi resources reloaded");
    this.deps.emitReloaded();
    return "reloaded";
  }

  private async deliverHeldPrompts(): Promise<void> {
    if (this.deps.isDisposed() || !this.deps.hasHeldPrompts()) return;
    const host = this.host;
    if (!host) {
      await this.deps.flushHeldPrompts();
      return;
    }
    let started = false;
    try {
      // The reload closed async input admission; the host reopens it as for any user input.
      await host.runInput(async () => {
        started = true;
        await this.deps.flushHeldPrompts();
      });
    } catch (error) {
      // Never bypass the host's input fence (archive, prepared release). The prompts stay held
      // and visible; the next settle point or user input retries delivery.
      logAgentd("pi held input admission failed", { sessionId: this.deps.sessionId, started: started ? 1 : 0, error: messageOf(error) });
      if (!started) this.deps.log(`queued message is waiting: ${messageOf(error)}`);
    }
  }
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
