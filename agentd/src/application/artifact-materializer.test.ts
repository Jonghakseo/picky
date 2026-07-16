import { describe, expect, it } from "vitest";
import type { PickyAgentSession } from "../protocol.js";
import { ArtifactMaterializer } from "./artifact-materializer.js";

const timestamp = "2026-07-16T08:15:39.000Z";

function sessionFixture(overrides: Partial<PickyAgentSession> = {}): PickyAgentSession {
  return {
    id: "session-artifact-materializer",
    title: "Artifact materializer",
    status: "completed",
    createdAt: timestamp,
    updatedAt: timestamp,
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
    messages: [],
    queuedSteers: [],
    queuedFollowUps: [],
    steeringMode: "one-at-a-time",
    followUpMode: "one-at-a-time",
    activitySummary: { read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 },
    ...overrides,
  };
}

describe("ArtifactMaterializer", () => {
  it("extracts links only from user messages and the final assistant answer", async () => {
    const session = sessionFixture({
      finalAnswer: "Created https://github.com/acme/repo/pull/42",
      messages: [
        {
          id: "user-notion-link",
          kind: "user_text",
          createdAt: timestamp,
          originatedBy: "user",
          text: "Review https://app.notion.com/p/acme/Plan-0123456789abcdef0123456789abcdef",
        },
        {
          id: "assistant-intermediate-link",
          kind: "agent_text",
          createdAt: timestamp,
          text: "Intermediate output https://linear.app/acme/issue/ENG-123/ignore-this",
        },
      ],
      logs: ["tool output https://www.notion.so/acme/Example-abcdefabcdefabcdefabcdefabcdefab"],
      tools: [
        {
          toolCallId: "read-skill",
          name: "read",
          status: "succeeded",
          preview: "Notion URL example: https://www.notion.so/acme/Example-0123456789abcdef0123456789abcdef",
        },
      ],
    });

    const materialized = await new ArtifactMaterializer().materializeTerminalArtifacts(session);

    expect(materialized?.artifacts.map((artifact) => artifact.url)).toEqual([
      "https://github.com/acme/repo/pull/42",
      "https://app.notion.com/p/acme/Plan-0123456789abcdef0123456789abcdef",
    ]);
  });

  it("does not create artifacts from tool previews alone", async () => {
    const session = sessionFixture({
      tools: [
        {
          toolCallId: "read-skill",
          name: "read",
          status: "succeeded",
          preview: "Notion URL example: https://www.notion.so/acme/Example-0123456789abcdef0123456789abcdef",
        },
      ],
    });

    await expect(new ArtifactMaterializer().materializeTerminalArtifacts(session)).resolves.toBeUndefined();
  });
});
