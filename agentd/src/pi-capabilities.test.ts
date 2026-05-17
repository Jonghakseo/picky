import { describe, expect, it, vi } from "vitest";
import { logAgentd } from "./local-log.js";
import { tryRefreshSystemPromptFromActiveTools } from "./runtime/pi-capabilities.js";

vi.mock("./local-log.js", () => ({
  logAgentd: vi.fn(),
}));

describe("tryRefreshSystemPromptFromActiveTools", () => {
  it("logs and returns false when refreshing active tools throws", () => {
    const session = {
      getActiveToolNames: () => ["read", "bash"],
      setActiveToolsByName: () => {
        throw new Error("refresh failed");
      },
    };

    expect(tryRefreshSystemPromptFromActiveTools(session as never, "session-refresh-error")).toBe(false);
    expect(logAgentd).toHaveBeenCalledWith("pi capability refresh system prompt failed", {
      sessionId: "session-refresh-error",
      error: "refresh failed",
    });
  });
});
