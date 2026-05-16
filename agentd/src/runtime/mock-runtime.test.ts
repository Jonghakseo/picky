import { describe, expect, it } from "vitest";
import { MockRuntimeSession } from "./mock-runtime.js";

describe("MockRuntimeSession queue foundation", () => {
  it("mirrors queue state and drains it via clearQueue", async () => {
    const session = new MockRuntimeSession("mock-test");

    expect(session.steeringMode).toBe("one-at-a-time");
    expect(session.followUpMode).toBe("one-at-a-time");
    expect(session.getSteeringMessages()).toEqual([]);
    expect(session.getFollowUpMessages()).toEqual([]);

    await session.steer({ text: "review logs", imagePaths: [] });
    await session.followUp({ text: "summarize later", imagePaths: [] });

    expect(session.getSteeringMessages()).toEqual(["review logs"]);
    expect(session.getFollowUpMessages()).toEqual(["summarize later"]);
    expect(session.clearQueue()).toEqual({ steering: ["review logs"], followUp: ["summarize later"] });
    expect(session.getSteeringMessages()).toEqual([]);
    expect(session.getFollowUpMessages()).toEqual([]);
  });
});
