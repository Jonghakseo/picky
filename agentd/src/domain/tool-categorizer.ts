export type ToolCategory = "read" | "bash" | "edit" | "write" | "thinking" | "other";

const READ_TOOLS = new Set(["read"]);
const BASH_TOOLS = new Set(["bash"]);
const EDIT_TOOLS = new Set(["edit", "multiedit"]);
const WRITE_TOOLS = new Set(["write"]);

export function categorizeTool(toolName: string): Exclude<ToolCategory, "thinking"> {
  const normalized = toolName.trim().toLowerCase();
  if (READ_TOOLS.has(normalized)) return "read";
  if (BASH_TOOLS.has(normalized)) return "bash";
  if (EDIT_TOOLS.has(normalized)) return "edit";
  if (WRITE_TOOLS.has(normalized)) return "write";
  return "other";
}
