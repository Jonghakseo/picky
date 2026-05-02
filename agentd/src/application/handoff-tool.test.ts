import { describe, expect, it } from "vitest";
import { createPickyHandoffTool, type PickyHandoffRequest } from "./handoff-tool.js";

describe("handoff tools", () => {
  it("passes an optional cwd override to the handoff callback and result details", async () => {
    let received: PickyHandoffRequest | undefined;
    const tool = createPickyHandoffTool(async (request) => {
      received = request;
      return { sessionId: "session-1", title: request.title, cwd: request.cwd };
    });

    const result = await tool.execute(
      "tool-1",
      { title: "사이드 조사", instructions: "Inspect this repo", cwd: "  /tmp/override-project  " } as never,
      undefined,
      undefined,
      {} as never,
    );

    expect(received).toMatchObject({ title: "사이드 조사", instructions: "Inspect this repo", cwd: "/tmp/override-project" });
    expect(result.details).toMatchObject({ sessionId: "session-1", title: "사이드 조사", cwd: "/tmp/override-project" });
  });
});
