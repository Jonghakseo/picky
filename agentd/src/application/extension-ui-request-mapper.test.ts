import { describe, expect, it } from "vitest";
import { summarizeExtensionUiAnswer } from "./extension-ui-request-mapper.js";
import type { PickyExtensionUiRequest } from "../protocol.js";

const baseRequest: PickyExtensionUiRequest = {
  id: "ui-1",
  sessionId: "session-1",
  method: "askUserQuestion",
  createdAt: "2026-05-01T00:00:00.000Z",
};

describe("summarizeExtensionUiAnswer", () => {
  it("returns undefined for cancellations", () => {
    expect(summarizeExtensionUiAnswer({ ...baseRequest, method: "input" }, { cancelled: true })).toBeUndefined();
    expect(summarizeExtensionUiAnswer({ ...baseRequest, method: "select" }, { cancelled: true })).toBeUndefined();
    expect(summarizeExtensionUiAnswer({ ...baseRequest, method: "askUserQuestion" }, { cancelled: true })).toBeUndefined();
  });

  it("summarizes confirm Allow as 'Allowed' and Deny as undefined", () => {
    const request: PickyExtensionUiRequest = { ...baseRequest, method: "confirm", title: "Proceed?" };
    expect(summarizeExtensionUiAnswer(request, true)).toBe("Allowed");
    expect(summarizeExtensionUiAnswer(request, { confirmed: true })).toBe("Allowed");
    expect(summarizeExtensionUiAnswer(request, false)).toBeUndefined();
  });

  it("summarizes select / input / editor by trimming the response string", () => {
    expect(summarizeExtensionUiAnswer({ ...baseRequest, method: "select" }, "  option-a  ")).toBe("option-a");
    expect(summarizeExtensionUiAnswer({ ...baseRequest, method: "input" }, "  hello  ")).toBe("hello");
    expect(summarizeExtensionUiAnswer({ ...baseRequest, method: "editor" }, " block ")).toBe("block");
    expect(summarizeExtensionUiAnswer({ ...baseRequest, method: "input" }, "   ")).toBeUndefined();
  });

  it("summarizes a single-question askUserQuestion answer using option labels and dropping the prompt", () => {
    const request: PickyExtensionUiRequest = {
      ...baseRequest,
      method: "askUserQuestion",
      questions: [
        {
          id: "commit-confirm",
          type: "radio",
          prompt: "Continue?",
          options: [
            { value: "commit", label: "Commit" },
            { value: "stop", label: "Stop and review" },
          ],
        },
      ] as PickyExtensionUiRequest["questions"],
    };

    const summary = summarizeExtensionUiAnswer(request, { value: { "commit-confirm": "stop" } });
    expect(summary).toBe("Stop and review");
  });

  it("joins multi-question answers with prompt prefixes and middle-dot separators", () => {
    const request: PickyExtensionUiRequest = {
      ...baseRequest,
      method: "askUserQuestion",
      questions: [
        { id: "scope", type: "radio", prompt: "Scope", options: [{ value: "user", label: "User" }, { value: "project", label: "Project" }] },
        { id: "items", type: "checkbox", prompt: "Items", options: [{ value: "rule", label: "Rule" }, { value: "gotcha", label: "Gotcha" }] },
        { id: "note", type: "text", prompt: "Note" },
      ] as PickyExtensionUiRequest["questions"],
    };

    const summary = summarizeExtensionUiAnswer(request, {
      value: { scope: "project", items: ["rule", "gotcha"], note: " keep this " },
    });

    expect(summary).toBe("Scope: Project \u00b7 Items: Rule, Gotcha \u00b7 Note: keep this");
  });

  it("returns undefined when the askUserQuestion answer is empty", () => {
    const request: PickyExtensionUiRequest = {
      ...baseRequest,
      method: "askUserQuestion",
      questions: [{ id: "scope", type: "radio", prompt: "Scope", options: [] }] as PickyExtensionUiRequest["questions"],
    };

    expect(summarizeExtensionUiAnswer(request, { value: { scope: "" } })).toBeUndefined();
    expect(summarizeExtensionUiAnswer(request, { value: {} })).toBeUndefined();
  });
});
