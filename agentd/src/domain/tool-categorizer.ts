export type ToolCategory = "read" | "bash" | "edit" | "write" | "todo" | "subagent" | "thinking" | "other";

const READ_TOOLS = new Set(["read"]);
const BASH_TOOLS = new Set(["bash"]);
const EDIT_TOOLS = new Set(["edit", "multiedit"]);
const WRITE_TOOLS = new Set(["write"]);
const TODO_TOOLS = new Set(["todo_write", "todowrite"]);
const SUBAGENT_TOOLS = new Set(["subagent"]);

export function categorizeTool(toolName: string): Exclude<ToolCategory, "thinking"> {
  const normalized = toolName.trim().toLowerCase();
  if (READ_TOOLS.has(normalized)) return "read";
  if (BASH_TOOLS.has(normalized)) return "bash";
  if (EDIT_TOOLS.has(normalized)) return "edit";
  if (WRITE_TOOLS.has(normalized)) return "write";
  if (TODO_TOOLS.has(normalized)) return "todo";
  if (SUBAGENT_TOOLS.has(normalized)) return "subagent";
  return "other";
}
