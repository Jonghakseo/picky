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
  applyAssistantRun(sessionId: string, currentAssistantRun: RuntimeAssistantRunMetadata): Promise<void>;
}

export async function listRuntimeOptions(deps: RuntimeControlDeps, sessionId: string): Promise<RuntimeSessionOptions> {
  const handle = await deps.handle(sessionId, "list runtime options");
  if (!handle.listRuntimeOptions) throw new Error("Runtime session does not support runtime options");
  return await handle.listRuntimeOptions();
}

export function setModel(
  deps: RuntimeControlDeps,
  sessionId: string,
  provider: string,
  modelId: string,
): Promise<PickyAgentSession> {
  return applyMutation(deps, sessionId, "set model", async (handle) => {
    if (!handle.setExactModel) throw new Error("Runtime session does not support direct model selection");
    return await handle.setExactModel(provider, modelId);
  });
}

export function setThinkingLevel(
  deps: RuntimeControlDeps,
  sessionId: string,
  thinkingLevel: ThinkingLevel,
): Promise<PickyAgentSession> {
  return applyMutation(deps, sessionId, "set thinking level", async (handle) => {
    if (!handle.setThinkingLevel) throw new Error("Runtime session does not support setting thinking level");
    handle.setThinkingLevel(thinkingLevel);
    return handle.getAssistantRunMetadata?.();
  });
}

export function cycleThinkingLevel(deps: RuntimeControlDeps, sessionId: string): Promise<PickyAgentSession> {
  return applyCycle(deps, sessionId, "cycle thinking level", async (handle) => {
    if (!handle.cycleThinkingLevel) throw new Error("Runtime session does not support cycling thinking level");
    return handle.cycleThinkingLevel();
  });
}

export function cycleModel(
  deps: RuntimeControlDeps,
  sessionId: string,
  direction: ModelCycleDirection,
): Promise<PickyAgentSession> {
  return applyCycle(deps, sessionId, "cycle model", async (handle) => {
    if (!handle.cycleModel) throw new Error("Runtime session does not support cycling models");
    return await handle.cycleModel(direction);
  });
}

/**
 * Runtime reattachment persists through the session commit. Resolve the handle inside the separate
 * runtime-control admission chain, then serialize only the mutation's session commit.
 */
async function applyMutation(
  deps: RuntimeControlDeps,
  sessionId: string,
  action: string,
  mutate: (handle: RuntimeSessionHandle) => Promise<RuntimeAssistantRunMetadata | undefined>,
): Promise<PickyAgentSession> {
  const handle = await deps.handle(sessionId, action);
  let result: PickyAgentSession | undefined;
  await deps.commit(sessionId, async () => {
    const currentAssistantRun = await mutate(handle);
    if (currentAssistantRun) await deps.applyAssistantRun(sessionId, currentAssistantRun);
    result = deps.session(sessionId);
  });
  return result!;
}

async function applyCycle(
  deps: RuntimeControlDeps,
  sessionId: string,
  action: string,
  cycle: (handle: RuntimeSessionHandle) => Promise<RuntimeAssistantRunMetadata | undefined>,
): Promise<PickyAgentSession> {
  const handle = await deps.handle(sessionId, action);
  const currentAssistantRun = await cycle(handle);
  if (currentAssistantRun) await deps.patch(sessionId, { currentAssistantRun });
  return deps.session(sessionId);
}
