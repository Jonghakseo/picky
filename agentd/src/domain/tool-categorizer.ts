export type ToolCategory = "edit" | "bash" | "thinking" | "other";

const EDIT_TOOLS = new Set(["edit", "write", "multiedit"]);
const BASH_TOOLS = new Set(["bash"]);

export function categorizeTool(toolName: string): Exclude<ToolCategory, "thinking"> {
  const normalized = toolName.trim().toLowerCase();
  if (EDIT_TOOLS.has(normalized)) return "edit";
  if (BASH_TOOLS.has(normalized)) return "bash";
  return "other";
}
