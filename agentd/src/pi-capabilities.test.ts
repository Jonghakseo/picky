import { describe, expect, it, vi } from "vitest";
import { tryRefreshSystemPromptFromActiveTools } from "./runtime/pi-capabilities.js";

describe("tryRefreshSystemPromptFromActiveTools", () => {
  it("logs and returns false when refreshing active tools throws", () => {
    const logAgentd = vi.fn();
    const session = {
      getActiveToolNames: () => ["read", "bash"],
      setActiveToolsByName: () => {
        throw new Error("refresh failed");
      },
    };

    expect(tryRefreshSystemPromptFromActiveTools(session as never, "session-refresh-error", logAgentd)).toBe(false);
    expect(logAgentd).toHaveBeenCalledWith("pi capability refresh system prompt failed", {
      sessionId: "session-refresh-error",
      error: "refresh failed",
    });
  });
});
