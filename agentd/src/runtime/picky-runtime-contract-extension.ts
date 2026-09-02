import type { BeforeAgentStartEvent, BeforeAgentStartEventResult, InlineExtension } from "@earendil-works/pi-coding-agent";

export const PICKY_RUNTIME_CONTRACT_EXTENSION_NAME = "picky-runtime-contract";

/**
 * Appends Picky's standing runtime contract to Pi's system prompt on every agent run.
 *
 * The system prompt is rebuilt from Pi's base prompt for each `before_agent_start`, so this
 * never accumulates and never needs a duplicate guard. Owning the contract here rather than in
 * the session's first user message is the whole point: compaction drops old messages but keeps
 * the system prompt, so the rules cannot fall out of context mid-session.
 *
 * Granularity is one `AgentSession.prompt()`, not one provider request. Retries, tool
 * continuations, and mid-run auto-compaction reuse the prompt the run started with, so a
 * settings toggle lands on the next user turn rather than interrupting an in-flight run.
 */
export function createPickyRuntimeContractExtension(getContract: () => string): InlineExtension {
  return {
    name: PICKY_RUNTIME_CONTRACT_EXTENSION_NAME,
    hidden: true,
    factory: (pi) => {
      pi.on("before_agent_start", (event) => appendContract(event, getContract()));
    },
  };
}

/** Exported for tests: the pure decision the extension's handler makes. */
export function appendContract(
  event: Pick<BeforeAgentStartEvent, "systemPrompt">,
  contract: string,
): BeforeAgentStartEventResult | undefined {
  const trimmed = contract.trim();
  if (!trimmed) return undefined;
  return { systemPrompt: `${event.systemPrompt}\n\n${trimmed}` };
}
