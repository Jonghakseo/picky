import { describe, expect, it } from "vitest";
import { categorizeTool } from "./tool-categorizer.js";

describe("categorizeTool", () => {
  it("classifies read as read", () => {
    expect(categorizeTool("read")).toBe("read");
  });

  it("classifies bash as bash", () => {
    expect(categorizeTool("bash")).toBe("bash");
  });

  it.each(["edit", "multiedit", "EDIT", "Edit"])("classifies %s as edit", (toolName) => {
    expect(categorizeTool(toolName)).toBe("edit");
  });

  it("classifies write as write", () => {
    expect(categorizeTool("write")).toBe("write");
  });

  it.each(["todo_write", "todowrite", "TODO_WRITE"])('classifies %s as todo', (toolName) => {
    expect(categorizeTool(toolName)).toBe("todo");
  });

  it.each(["subagent", "SUBAGENT"])('classifies %s as subagent', (toolName) => {
    expect(categorizeTool(toolName)).toBe("subagent");
  });

  it.each(["grep", "mcp__notion__readPage", "some_unknown_tool", ""])("classifies %s as other", (toolName) => {
    expect(categorizeTool(toolName)).toBe("other");
  });
});
