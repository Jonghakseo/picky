import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import type { ExtensionUIContext } from "@mariozechner/pi-coding-agent";
import type { PickyExtensionUiRequest } from "./protocol.js";

export type ExtensionUiMethod = PickyExtensionUiRequest["method"];

export interface ExtensionUiAnswer {
  value?: unknown;
  confirmed?: boolean;
  cancelled?: boolean;
}

interface PendingDialog {
  method: "select" | "confirm" | "input" | "editor";
  resolve: (value: unknown) => void;
  timer?: NodeJS.Timeout;
}

export class ExtensionUiBridge extends EventEmitter {
  private pending = new Map<string, PendingDialog>();

  constructor(private readonly sessionId: string) {
    super();
  }

  createContext(): ExtensionUIContext {
    const context: Partial<ExtensionUIContext> = {
      select: (title, options, opts) => this.dialog("select", { title, options, timeout: opts?.timeout }, opts?.signal) as Promise<string | undefined>,
      confirm: (title, message, opts) => this.dialog("confirm", { title, prompt: message, timeout: opts?.timeout }, opts?.signal) as Promise<boolean>,
      input: (title, placeholder, opts) => this.dialog("input", { title, prompt: placeholder, timeout: opts?.timeout }, opts?.signal) as Promise<string | undefined>,
      editor: (title, prefill) => this.dialog("editor", { title, prompt: prefill }) as Promise<string | undefined>,
      notify: (message, type) => void this.fireAndForget("notify", { prompt: message, notifyType: type ?? "info" }),
      setStatus: (key, text) => void this.fireAndForget("setStatus", { statusKey: key, statusText: text }),
      setWidget: (key, content, options) => void this.fireAndForget("setWidget", { widgetKey: key, widgetLines: Array.isArray(content) ? content : undefined, widgetPlacement: options?.placement }),
      setTitle: (title) => void this.fireAndForget("setTitle", { title }),
      setEditorText: (text) => void this.fireAndForget("set_editor_text", { text }),
      pasteToEditor: (text) => void this.fireAndForget("set_editor_text", { text }),
      getEditorText: () => "",
      custom: async <T>() => undefined as T,
      onTerminalInput: () => () => undefined,
      setWorkingMessage: () => undefined,
      setWorkingVisible: () => undefined,
      setWorkingIndicator: () => undefined,
      setHiddenThinkingLabel: () => undefined,
      setFooter: () => undefined,
      setHeader: () => undefined,
      addAutocompleteProvider: () => undefined,
      setEditorComponent: () => undefined,
      getEditorComponent: () => undefined,
      getToolsExpanded: () => false,
      setToolsExpanded: () => undefined,
      theme: {} as ExtensionUIContext["theme"],
      getAllThemes: () => [],
      getTheme: () => undefined,
      setTheme: () => ({ success: false, error: "Picky daemon does not manage Pi TUI themes" }),
    };
    return context as ExtensionUIContext;
  }

  answer(requestId: string, answer: ExtensionUiAnswer): void {
    const pending = this.pending.get(requestId);
    if (!pending) throw new Error(`Unknown extension UI request: ${requestId}`);
    this.pending.delete(requestId);
    if (pending.timer) clearTimeout(pending.timer);
    pending.resolve(this.mapAnswer(pending.method, answer));
  }

  private dialog(method: PendingDialog["method"], payload: Record<string, unknown>, signal?: AbortSignal): Promise<unknown> {
    const id = `ext-ui-${randomUUID()}`;
    const request = this.request(id, method, payload);
    return new Promise((resolve) => {
      const pending: PendingDialog = { method, resolve };
      const timeout = typeof payload.timeout === "number" ? payload.timeout : undefined;
      if (timeout && timeout > 0) {
        pending.timer = setTimeout(() => this.answer(id, { cancelled: true }), timeout);
      }
      if (signal) signal.addEventListener("abort", () => this.answer(id, { cancelled: true }), { once: true });
      this.pending.set(id, pending);
      this.emit("request", request, true);
    });
  }

  private fireAndForget(method: ExtensionUiMethod, payload: Record<string, unknown>): void {
    this.emit("request", this.request(`ext-ui-${randomUUID()}`, method, payload), false);
  }

  private request(id: string, method: ExtensionUiMethod, payload: Record<string, unknown>): PickyExtensionUiRequest {
    return {
      id,
      sessionId: this.sessionId,
      method,
      title: typeof payload.title === "string" ? payload.title : undefined,
      prompt: typeof payload.prompt === "string" ? payload.prompt : undefined,
      options: Array.isArray(payload.options) ? payload.options.filter((option): option is string => typeof option === "string") : undefined,
      createdAt: new Date().toISOString(),
      payload,
    } as PickyExtensionUiRequest;
  }

  private mapAnswer(method: PendingDialog["method"], answer: ExtensionUiAnswer): unknown {
    if (answer.cancelled) return method === "confirm" ? false : undefined;
    if (method === "confirm") return answer.confirmed ?? Boolean(answer.value);
    return answer.value;
  }
}
