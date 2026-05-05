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

  it.each(["grep", "mcp__notion__readPage", "picky_show_pointer", ""])("classifies %s as other", (toolName) => {
    expect(categorizeTool(toolName)).toBe("other");
  });
});
