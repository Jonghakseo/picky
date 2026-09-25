import type { PickyAgentSession } from "../protocol.js";
import type { RuntimeAsyncTaskOwner, RuntimeAsyncTaskState } from "../runtime/async-task-types.js";

/** Reuses the supervisor's save-before-publish boundary. No second registry or write chain. */
export function asyncTaskRuntimeOptions(
  enabled: boolean,
  read: () => PickyAgentSession,
  commit: (build: (session: PickyAgentSession) => PickyAgentSession) => Promise<{ after: PickyAgentSession }>,
): { asyncTaskHost?: RuntimeAsyncTaskOwner } {
  if (!enabled) return {};
  return { asyncTaskHost: {
    read: () => stateFromSession(read()),
    async transact(build) {
      const result = await commit((session) => {
        const current = stateFromSession(session);
        const next = build(current);
        if (next === current) return session;
        return { ...session, asyncTasks: next.tasks, completionTickets: next.tickets, asyncControl: next.control, agentCycle: next.cycle };
      });
      return stateFromSession(result.after);
    },
  } };
}
function stateFromSession(session: PickyAgentSession): RuntimeAsyncTaskState {
  return { tasks: session.asyncTasks ?? [], tickets: session.completionTickets ?? [], control: session.asyncControl, cycle: session.agentCycle };
}
