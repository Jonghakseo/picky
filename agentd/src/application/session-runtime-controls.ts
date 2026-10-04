import { KeyedSerialQueue } from "../domain/keyed-serial-queue.js";
import type { ModelCycleDirection, PickyAgentSession } from "../protocol.js";
import type {
  RuntimeAssistantRunMetadata,
  RuntimeSessionHandle,
  RuntimeSessionOptions,
  ThinkingLevel,
} from "../runtime/types.js";

/**
 * Collaborators the runtime-control mutations need from the supervisor. Passed as closures so the
 * feature lives outside the `session-supervisor.ts` facade without exposing its private surface.
 */
export interface RuntimeControlDeps {
  handle(sessionId: string, action: string): Promise<RuntimeSessionHandle>;
  session(sessionId: string): PickyAgentSession;
  patch(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
  /** Serializes the session commit itself, separately from the runtime-control admission chain. */
  commit(sessionId: string, work: () => Promise<void>): Promise<void>;
  /** Commits a session patch from inside `commit` without taking the session write lock again. */
  commitPatch(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
}

/**
 * Per-Pickle model, thinking level, and fast mode controls. Owns the admission chain that keeps
 * runtime-control commands for one session in arrival order while a detached runtime resumes.
 */
export class SessionRuntimeControls {
  private readonly admission = new KeyedSerialQueue();

  constructor(private readonly deps: RuntimeControlDeps) {}

  async listOptions(sessionId: string): Promise<RuntimeSessionOptions> {
    const handle = await this.deps.handle(sessionId, "list runtime options");
    if (!handle.listRuntimeOptions) throw new Error("Runtime session does not support runtime options");
    return await handle.listRuntimeOptions();
  }

  setModel(sessionId: string, provider: string, modelId: string): Promise<PickyAgentSession> {
    return this.applyMutation(sessionId, "set model", async (handle) => {
      if (!handle.setExactModel) throw new Error("Runtime session does not support direct model selection");
      return await handle.setExactModel(provider, modelId);
    });
  }

  setThinkingLevel(sessionId: string, thinkingLevel: ThinkingLevel): Promise<PickyAgentSession> {
    return this.applyMutation(sessionId, "set thinking level", async (handle) => {
      if (!handle.setThinkingLevel) throw new Error("Runtime session does not support setting thinking level");
      handle.setThinkingLevel(thinkingLevel);
      return handle.getAssistantRunMetadata?.();
    });
  }

  /**
   * Persists the Pickle's fast mode choice and applies it to the live runtime. The session field
   * is the durable owner: a resumed or reattached handle is restored from it, so the choice
   * survives daemon restarts and per-Pickle daemons.
   */
  setFastMode(sessionId: string, enabled: boolean): Promise<PickyAgentSession> {
    return this.applyMutation(sessionId, "set fast mode", async (handle) => {
      if (!handle.setFastMode) throw new Error("Runtime session does not support fast mode");
      handle.setFastMode(enabled);
      await this.deps.commitPatch(sessionId, { fastMode: enabled });
      return undefined;
    });
  }

  cycleThinkingLevel(sessionId: string): Promise<PickyAgentSession> {
    return this.applyCycle(sessionId, "cycle thinking level", async (handle) => {
      if (!handle.cycleThinkingLevel) throw new Error("Runtime session does not support cycling thinking level");
      return handle.cycleThinkingLevel();
    });
  }

  cycleModel(sessionId: string, direction: ModelCycleDirection): Promise<PickyAgentSession> {
    return this.applyCycle(sessionId, "cycle model", async (handle) => {
      if (!handle.cycleModel) throw new Error("Runtime session does not support cycling models");
      return await handle.cycleModel(direction);
    });
  }

  /**
   * Runtime reattachment persists through the session commit. Resolve the handle inside the separate
   * runtime-control admission chain, then serialize only the mutation's session commit.
   */
  private applyMutation(
    sessionId: string,
    action: string,
    mutate: (handle: RuntimeSessionHandle) => Promise<RuntimeAssistantRunMetadata | undefined>,
  ): Promise<PickyAgentSession> {
    return this.admission.run(sessionId, async () => {
      const handle = await this.deps.handle(sessionId, action);
      let result: PickyAgentSession | undefined;
      await this.deps.commit(sessionId, async () => {
        const currentAssistantRun = await mutate(handle);
        if (currentAssistantRun) await this.deps.commitPatch(sessionId, { currentAssistantRun });
        result = this.deps.session(sessionId);
      });
      return result!;
    });
  }

  private applyCycle(
    sessionId: string,
    action: string,
    cycle: (handle: RuntimeSessionHandle) => Promise<RuntimeAssistantRunMetadata | undefined>,
  ): Promise<PickyAgentSession> {
    return this.admission.run(sessionId, async () => {
      const handle = await this.deps.handle(sessionId, action);
      const currentAssistantRun = await cycle(handle);
      if (currentAssistantRun) await this.deps.patch(sessionId, { currentAssistantRun });
      return this.deps.session(sessionId);
    });
  }
}
