import { describe, expect, it } from "vitest";
import { ExtensionUiBridge } from "./extension-ui-bridge.js";

describe("ExtensionUiBridge", () => {
  it("resolves confirm requests from app answers", async () => {
    const bridge = new ExtensionUiBridge("session-1");
    const context = bridge.createContext();
    const requestPromise = nextRequest(bridge);
    const promise = context.confirm("Allow?", "Proceed?");
    const request = await requestPromise;

    expect(request.method).toBe("confirm");
    expect(request.sessionId).toBe("session-1");
    bridge.answer(request.id, { confirmed: true });
    await expect(promise).resolves.toBe(true);
  });

  it("maps cancelled confirm to false and cancelled input to undefined", async () => {
    const bridge = new ExtensionUiBridge("session-1");
    const context = bridge.createContext();

    const confirmRequest = nextRequest(bridge);
    const confirm = context.confirm("Allow?", "Proceed?");
    bridge.answer((await confirmRequest).id, { cancelled: true });
    await expect(confirm).resolves.toBe(false);

    const inputRequest = nextRequest(bridge);
    const input = context.input("Name", "placeholder");
    bridge.answer((await inputRequest).id, { cancelled: true });
    await expect(input).resolves.toBeUndefined();
  });

  it("resolves askUserQuestion form requests with radio checkbox and text answers", async () => {
    const bridge = new ExtensionUiBridge("session-1");
    const context = bridge.createContext() as ReturnType<ExtensionUiBridge["createContext"]> & { askUserQuestion: (request: unknown) => Promise<Record<string, unknown> | undefined> };
    const requestPromise = nextRequest(bridge);
    const promise = context.askUserQuestion({
      title: "Confirm memory changes",
      questions: [
        { id: "scope", type: "radio", prompt: "Scope?", options: ["user", { value: "project", label: "Project" }], default: "project" },
        { id: "items", type: "checkbox", prompt: "Items?", options: ["a", "b"], default: ["a"], allowOther: true },
        { id: "note", type: "text", prompt: "Note", placeholder: "optional", required: false },
      ],
    });
    const request = await requestPromise;

    expect(request.method).toBe("askUserQuestion");
    expect(request.questions?.map((question) => question.id)).toEqual(["scope", "items", "note"]);
    expect(request.questions?.[0].options).toEqual([{ value: "user", label: "user" }, { value: "project", label: "Project" }]);
    bridge.answer(request.id, { value: { scope: "project", items: ["a", "custom"], note: "ship it" } });
    await expect(promise).resolves.toEqual({ scope: "project", items: ["a", "custom"], note: "ship it" });
  });

  it("emits fire-and-forget requests without blocking", async () => {
    const bridge = new ExtensionUiBridge("session-1");
    const requestPromise = nextRequest(bridge);
    bridge.createContext().notify("Saved", "info");
    const request = await requestPromise;
    expect(request.method).toBe("notify");
    expect(request.prompt).toBe("Saved");
  });
});

function nextRequest(bridge: ExtensionUiBridge): Promise<{ id: string; sessionId: string; method: string; prompt?: string; questions?: Array<{ id?: string; options?: Array<{ value: string; label: string }> }> }> {
  return new Promise((resolve) => bridge.once("request", (request) => resolve(request)));
}
