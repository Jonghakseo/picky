import { describe, expect, it } from "vitest";
import { ExtensionUiBridge, PickyOverlayUnsupportedError } from "./application/extension-ui-bridge.js";

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

  it("serializes concurrent blocking dialogs so each request remains answerable", async () => {
    const bridge = new ExtensionUiBridge("session-serial");
    const context = bridge.createContext();
    const requests: Array<{ id: string; prompt?: string }> = [];
    bridge.on("request", (request, waitsForInput) => {
      if (waitsForInput) requests.push(request);
    });

    const first = context.confirm("Delete first?", "first");
    const second = context.confirm("Delete second?", "second");
    const third = context.confirm("Delete third?", "third");

    expect(requests.map((request) => request.prompt)).toEqual(["first"]);
    bridge.answer(requests[0].id, { confirmed: true });
    await expect(first).resolves.toBe(true);
    expect(requests.map((request) => request.prompt)).toEqual(["first", "second"]);

    bridge.answer(requests[1].id, { confirmed: false });
    await expect(second).resolves.toBe(false);
    expect(requests.map((request) => request.prompt)).toEqual(["first", "second", "third"]);

    bridge.answer(requests[2].id, { confirmed: true });
    await expect(third).resolves.toBe(true);
  });

  it("cancels the active and queued dialogs without presenting queued requests", async () => {
    const bridge = new ExtensionUiBridge("session-cancel-all");
    const context = bridge.createContext();
    const requests: Array<{ id: string }> = [];
    const cancelled: string[] = [];
    bridge.on("request", (request, waitsForInput) => {
      if (waitsForInput) requests.push(request);
    });
    bridge.on("cancelled", (requestId) => cancelled.push(requestId));

    const first = context.confirm("Delete first?", "first");
    const second = context.confirm("Delete second?", "second");
    const input = context.input("Name", "placeholder");

    expect(requests).toHaveLength(1);
    expect(bridge.cancelAll()).toBe(3);
    await expect(Promise.all([first, second, input])).resolves.toEqual([false, false, undefined]);
    expect(requests).toHaveLength(1);
    expect(cancelled).toEqual([requests[0].id]);
    expect(bridge.cancelAll()).toBe(0);
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
    bridge.createContext().notify("Saved", "warning");
    const request = await requestPromise;
    expect(request.method).toBe("notify");
    expect(request.prompt).toBe("Saved");
    expect(request.notifyType).toBe("warning");
  });

  it("mirrors editor text updates into set_editor_text requests", async () => {
    const bridge = new ExtensionUiBridge("session-1");
    const context = bridge.createContext();

    const setRequestPromise = nextRequest(bridge);
    context.setEditorText("review comments");
    const setRequest = await setRequestPromise;
    expect(setRequest.method).toBe("set_editor_text");
    expect(setRequest.text).toBe("review comments");
    expect(context.getEditorText()).toBe("review comments");

    const pasteRequestPromise = nextRequest(bridge);
    context.pasteToEditor("\nmore");
    const pasteRequest = await pasteRequestPromise;
    expect(pasteRequest.method).toBe("set_editor_text");
    expect(pasteRequest.text).toBe("review comments\nmore");
    expect(context.getEditorText()).toBe("review comments\nmore");
  });

  it("ignores setWidget because Picky has no TUI widget surface", async () => {
    const bridge = new ExtensionUiBridge("session-1");
    const requests: unknown[] = [];
    bridge.on("request", (request) => requests.push(request));

    bridge.createContext().setWidget("spinner", ["tick"]);
    bridge.createContext().setWidget("spinner", undefined);
    await delay(20);

    expect(requests).toEqual([]);
  });

  it("cancels a dialog immediately when its AbortSignal is already aborted", async () => {
    const bridge = new ExtensionUiBridge("session-1");
    const controller = new AbortController();
    controller.abort();

    const input = bridge.createContext().input("Name", "placeholder", { signal: controller.signal });

    await expect(Promise.race([input, delay(20).then(() => "timed-out")])).resolves.toBeUndefined();
  });

  it("rejects ctx.ui.custom with PickyOverlayUnsupportedError tagged with the session id", async () => {
    const bridge = new ExtensionUiBridge("session-overlay-fail");
    const context = bridge.createContext();
    await expect(context.custom(() => ({}) as never)).rejects.toMatchObject({
      name: "PickyOverlayUnsupportedError",
      sessionId: "session-overlay-fail",
    });
    await expect(context.custom(() => ({}) as never)).rejects.toBeInstanceOf(PickyOverlayUnsupportedError);
  });

  it("does not throw later when an answered dialog AbortSignal is aborted", async () => {
    const bridge = new ExtensionUiBridge("session-1");
    const controller = new AbortController();
    const requestPromise = nextRequest(bridge);
    const input = bridge.createContext().input("Name", "placeholder", { signal: controller.signal });
    const request = await requestPromise;

    bridge.answer(request.id, { value: "Alice" });
    await expect(input).resolves.toBe("Alice");
    await expectNoUncaughtException(() => controller.abort());
  });

  it("returns true for live dialogs and false for unknown ids so callers can decide whether stale cleanup is fatal", async () => {
    // Regression: supervisor.cancelPendingExtensionUiForUserInput used to throw
    // "Unknown extension UI request: ..." when the bridge had already discarded
    // the dialog (turn completed, runtime resume, etc.). The exception
    // propagated out of supervisor.followUp and the user's next chat message
    // looked like it had been silently dropped. The bridge now reports the
    // outcome and lets each caller decide.
    const bridge = new ExtensionUiBridge("session-stale");
    const requestPromise = nextRequest(bridge);
    const dialog = bridge.createContext().confirm("Allow?", "Proceed?");
    const request = await requestPromise;

    expect(bridge.answer(request.id, { confirmed: true })).toBe(true);
    await expect(dialog).resolves.toBe(true);

    expect(bridge.answer(request.id, { confirmed: true })).toBe(false);
    expect(bridge.answer("ext-ui-never-issued", { cancelled: true })).toBe(false);
  });
});

function nextRequest(bridge: ExtensionUiBridge): Promise<{ id: string; sessionId: string; method: string; prompt?: string; text?: string; notifyType?: string; questions?: Array<{ id?: string; options?: Array<{ value: string; label: string }> }> }> {
  return new Promise((resolve) => bridge.once("request", (request) => resolve(request)));
}

async function expectNoUncaughtException(action: () => void): Promise<void> {
  let handler: ((error: Error) => void) | undefined;
  const uncaught = new Promise<string>((resolve) => {
    handler = (error) => resolve(error.message);
    process.once("uncaughtException", handler);
  });
  action();
  const result = await Promise.race([uncaught, delay(20).then(() => undefined)]);
  if (handler) process.off("uncaughtException", handler);
  expect(result).toBeUndefined();
}

async function delay(milliseconds: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, milliseconds));
}
