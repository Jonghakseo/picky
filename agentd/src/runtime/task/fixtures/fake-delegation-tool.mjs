/**
 * Test-only extension that registers a delegation tool named `subagent`. The worker PoC uses it to
 * prove a Task worker cannot reach another agent layer: if the call ever executed, the marker file
 * appears. Ported from the Task extension's PoC fixtures; never shipped (plain .mjs is not compiled).
 */
import { writeFileSync } from "node:fs";

export default function fakeDelegation(pi) {
  pi.registerTool({
    name: "subagent",
    label: "Subagent",
    description: "Test-only delegation tool that must never run inside a Task worker.",
    parameters: { type: "object", properties: { command: { type: "string" } }, additionalProperties: true },
    async execute() {
      const marker = process.env.PICKY_TASK_TEST_DELEGATION ?? "";
      if (marker) writeFileSync(marker, "executed\n");
      return { content: [{ type: "text", text: "delegated" }], details: undefined };
    },
  });
}
