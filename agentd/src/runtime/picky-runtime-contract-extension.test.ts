import { describe, expect, it } from "vitest";
import { buildPickyRuntimeContract } from "../domain/picky-runtime-contract.js";
import { appendContract, createPickyRuntimeContractExtension, PICKY_RUNTIME_CONTRACT_EXTENSION_NAME } from "./picky-runtime-contract-extension.js";

type BeforeAgentStartHandler = (event: { systemPrompt: string }) => { systemPrompt?: string } | undefined;

async function registerHandler(getContract: () => string): Promise<BeforeAgentStartHandler> {
  const extension = createPickyRuntimeContractExtension(getContract);
  const factory = typeof extension === "function" ? extension : extension.factory;
  let handler: BeforeAgentStartHandler | undefined;
  await factory({
    on: (event: string, registered: BeforeAgentStartHandler) => {
      if (event === "before_agent_start") handler = registered;
    },
  } as never);
  if (!handler) throw new Error("before_agent_start handler was not registered");
  return handler;
}

describe("createPickyRuntimeContractExtension", () => {
  it("registers a hidden inline extension under a stable name", () => {
    const extension = createPickyRuntimeContractExtension(() => "contract");
    expect(extension).toMatchObject({ name: PICKY_RUNTIME_CONTRACT_EXTENSION_NAME, hidden: true });
  });

  it("appends the contract after Pi's own system prompt", async () => {
    const handler = await registerHandler(() => "## Picky runtime contract\n[RECT: x=<number>");

    const result = handler({ systemPrompt: "Pi base prompt" });

    expect(result?.systemPrompt).toBe("Pi base prompt\n\n## Picky runtime contract\n[RECT: x=<number>");
  });

  it("re-supplies the contract on every run regardless of what the base prompt already says", async () => {
    // Pi hands a freshly built base prompt to each run. A base prompt that happens to mention
    // the contract heading (an AGENTS.md quoting it, say) must not suppress the real rules.
    const handler = await registerHandler(() => buildPickyRuntimeContract(new Set()));

    const first = handler({ systemPrompt: "Pi base prompt" });
    const second = handler({ systemPrompt: "Pi base prompt with ## Picky runtime contract quoted" });

    expect(first?.systemPrompt).toContain("[RECT: x=<number>");
    expect(second?.systemPrompt).toContain("[RECT: x=<number>");
  });

  it("reads the contract per turn so a settings toggle lands without a new session", async () => {
    let disabled = false;
    const handler = await registerHandler(() => buildPickyRuntimeContract(disabled ? new Set(["picky_screen_overlay"]) : new Set()));

    expect(handler({ systemPrompt: "base" })?.systemPrompt).toContain("[RECT: x=<number>");
    disabled = true;
    expect(handler({ systemPrompt: "base" })?.systemPrompt).not.toContain("[RECT: x=<number>");
  });

  it("leaves Pi's prompt untouched when there is no contract to add", async () => {
    const handler = await registerHandler(() => "   ");
    expect(handler({ systemPrompt: "base" })).toBeUndefined();
  });

  it("survives a rebuilt base prompt, which is what compaction produces", () => {
    const contract = buildPickyRuntimeContract(new Set());

    // Compaction replaces the message history but Pi rebuilds the same base system prompt, so
    // the contract is re-attached to whatever base prompt the next run starts from.
    const beforeCompaction = appendContract({ systemPrompt: "base" }, contract);
    const afterCompaction = appendContract({ systemPrompt: "base" }, contract);

    expect(beforeCompaction?.systemPrompt).toContain("[RECT: x=<number>");
    expect(afterCompaction?.systemPrompt).toBe(beforeCompaction?.systemPrompt);
  });
});
