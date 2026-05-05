import { describe, expect, it } from "vitest";
import { categorizeTool } from "./tool-categorizer.js";

describe("categorizeTool", () => {
  it.each(["edit", "write", "multiedit", "EDIT", "Edit"])("classifies %s as edit", (toolName) => {
    expect(categorizeTool(toolName)).toBe("edit");
  });

  it("classifies bash as bash", () => {
    expect(categorizeTool("bash")).toBe("bash");
  });

  it.each(["read", "grep", "mcp__notion__readPage", "picky_show_pointer", ""])("classifies %s as other", (toolName) => {
    expect(categorizeTool(toolName)).toBe("other");
  });
});
