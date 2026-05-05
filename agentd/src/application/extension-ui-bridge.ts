import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import type { ExtensionUIContext } from "@mariozechner/pi-coding-agent";
import type { PickyExtensionUiRequest } from "../protocol.js";

export type ExtensionUiMethod = PickyExtensionUiRequest["method"];

export interface ExtensionUiAnswer {
  value?: unknown;
  confirmed?: boolean;
  cancelled?: boolean;
}

export interface AskUserQuestionOption {
  value: string;
  label: string;
  description?: string;
}

export interface AskUserQuestion {
  id?: string;
  type: "radio" | "checkbox" | "text";
  prompt?: string;
  question?: string;
  label?: string;
  options?: Array<string | AskUserQuestionOption> | string;
  allowOther?: boolean;
  required?: boolean;
  placeholder?: string;
  default?: string | string[];
}

export interface AskUserQuestionRequest {
  title?: string;
  description?: string;
  questions: AskUserQuestion[] | string;
}

type DialogMethod = "select" | "confirm" | "input" | "editor" | "askUserQuestion";

interface PendingDialog {
  method: DialogMethod;
  resolve: (value: unknown) => void;
  timer?: NodeJS.Timeout;
  cleanup?: () => void;
}

export class ExtensionUiBridge extends EventEmitter {
  private pending = new Map<string, PendingDialog>();

  constructor(private readonly sessionId: string, private readonly options: { disableBlockingDialogs?: boolean } = {}) {
    super();
  }

  createContext(): ExtensionUIContext {
    const context: Partial<ExtensionUIContext> & Record<string, unknown> = {
      select: (title, options, opts) => this.dialog("select", { title, options, timeout: opts?.timeout }, opts?.signal) as Promise<string | undefined>,
      confirm: (title, message, opts) => this.dialog("confirm", { title, prompt: message, timeout: opts?.timeout }, opts?.signal) as Promise<boolean>,
      input: (title, placeholder, opts) => this.dialog("input", { title, prompt: placeholder, timeout: opts?.timeout }, opts?.signal) as Promise<string | undefined>,
      editor: (title, prefill) => this.dialog("editor", { title, prompt: prefill }) as Promise<string | undefined>,
      askUserQuestion: (request: AskUserQuestionRequest, opts?: { signal?: AbortSignal; timeout?: number }) => this.dialog("askUserQuestion", normalizeAskUserQuestionRequest(request, opts?.timeout), opts?.signal) as Promise<Record<string, unknown> | undefined>,
      ask_user_question: (request: AskUserQuestionRequest, opts?: { signal?: AbortSignal; timeout?: number }) => this.dialog("askUserQuestion", normalizeAskUserQuestionRequest(request, opts?.timeout), opts?.signal) as Promise<Record<string, unknown> | undefined>,
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
    if (!this.resolveDialog(requestId, answer)) throw new Error(`Unknown extension UI request: ${requestId}`);
  }

  private dialog(method: DialogMethod, payload: Record<string, unknown>, signal?: AbortSignal): Promise<unknown> {
    if (this.options.disableBlockingDialogs) {
      return Promise.reject(new Error(`Interactive user dialogs (${method}) are not available for the Picky main agent. Delegate to a side agent via picky_handoff if user input is required.`));
    }
    if (signal?.aborted) return Promise.resolve(this.mapAnswer(method, { cancelled: true }));

    const id = `ext-ui-${randomUUID()}`;
    const request = this.request(id, method, payload);
    return new Promise((resolve) => {
      const pending: PendingDialog = { method, resolve };
      const timeout = typeof payload.timeout === "number" ? payload.timeout : undefined;
      if (timeout && timeout > 0) {
        pending.timer = setTimeout(() => this.resolveDialog(id, { cancelled: true }), timeout);
      }
      if (signal) {
        const abortListener = () => this.resolveDialog(id, { cancelled: true });
        pending.cleanup = () => signal.removeEventListener("abort", abortListener);
        signal.addEventListener("abort", abortListener, { once: true });
      }
      this.pending.set(id, pending);
      this.emit("request", request, true);
    });
  }

  private resolveDialog(requestId: string, answer: ExtensionUiAnswer): boolean {
    const pending = this.pending.get(requestId);
    if (!pending) return false;
    this.pending.delete(requestId);
    if (pending.timer) clearTimeout(pending.timer);
    pending.cleanup?.();
    pending.resolve(this.mapAnswer(pending.method, answer));
    return true;
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
      description: typeof payload.description === "string" ? payload.description : undefined,
      options: Array.isArray(payload.options) ? payload.options.filter((option): option is string => typeof option === "string") : undefined,
      questions: Array.isArray(payload.questions) ? payload.questions : undefined,
      createdAt: new Date().toISOString(),
      payload,
    } as PickyExtensionUiRequest;
  }

  private mapAnswer(method: DialogMethod, answer: ExtensionUiAnswer): unknown {
    if (answer.cancelled) return method === "confirm" ? false : undefined;
    if (method === "confirm") return answer.confirmed ?? Boolean(answer.value);
    return answer.value;
  }
}

function normalizeAskUserQuestionRequest(request: AskUserQuestionRequest, timeout?: number): Record<string, unknown> {
  return {
    title: request.title,
    description: request.description,
    questions: parseQuestions(request.questions).map((question, index) => ({
      id: question.id?.trim() || `q${index + 1}`,
      type: question.type,
      prompt: question.prompt ?? question.question,
      label: question.label,
      options: normalizeOptions(question.options),
      allowOther: question.allowOther,
      required: question.required,
      placeholder: question.placeholder,
      default: question.default,
    })),
    timeout,
  };
}

function parseQuestions(questions: AskUserQuestion[] | string): AskUserQuestion[] {
  if (Array.isArray(questions)) return questions;
  const parsed = JSON.parse(questions) as unknown;
  if (!Array.isArray(parsed)) throw new Error("askUserQuestion questions must be an array");
  return parsed as AskUserQuestion[];
}

function normalizeOptions(options: AskUserQuestion["options"]): AskUserQuestionOption[] | undefined {
  if (!options) return undefined;
  const rawOptions = typeof options === "string" ? JSON.parse(options) as unknown : options;
  if (!Array.isArray(rawOptions)) return undefined;
  return rawOptions.map((option) => {
    if (typeof option === "string") return { value: option, label: option };
    return { value: option.value, label: option.label, description: option.description };
  });
}
