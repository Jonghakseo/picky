import type { PickyToolActivity } from "../protocol.js";

export function hasActiveTools(tools: PickyToolActivity[]): boolean {
  return tools.some((tool) => isActiveToolStatus(tool.status));
}

export function settleActiveTools(tools: PickyToolActivity[], preview: string, endedAt = new Date().toISOString()): PickyToolActivity[] {
  if (!hasActiveTools(tools)) return tools;
  return tools.map((tool) => (
    isActiveToolStatus(tool.status)
      ? { ...tool, status: "failed" as const, preview, endedAt: tool.endedAt ?? endedAt }
      : tool
  ));
}

function isActiveToolStatus(status: string): boolean {
  return status === "running" || status === "started";
}
