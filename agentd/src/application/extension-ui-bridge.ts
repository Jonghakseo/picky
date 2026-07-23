import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import type { ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import type { AutocompleteItem, AutocompleteProvider, AutocompleteSuggestions } from "@earendil-works/pi-tui";
import type { PickyExtensionNotifyType, PickyExtensionUiRequest } from "../protocol.js";

type ExtensionUiMethod = PickyExtensionUiRequest["method"];

/**
 * Marker base class for errors that originate from Picky's extension UI bridge
 * surface (e.g. a pi extension calling an API Picky does not implement). The
 * agentd extension crash guard treats every subclass as expected and swallows
 * it after detailed logging, instead of letting the daemon die.
 */
export class PickyExtensionError extends Error {
  constructor(message: string, public readonly extensionApi: string, public readonly sessionId?: string) {
    super(message);
    this.name = "PickyExtensionError";
  }
}

/**
 * Thrown by `ctx.ui.custom` in Picky's extension bridge to signal that the
 * caller asked for a TUI overlay surface that does not exist in this host.
 *
 * Picky's extension crash guard recognises this subclass and swallows it so a
 * passive extension hook (e.g. an idle-timer screensaver) cannot tear down
 * the daemon. Real bugs that surface as unhandled rejections of an unrelated
 * type are still re-thrown.
 */
export class PickyOverlayUnsupportedError extends PickyExtensionError {
  constructor(sessionId: string) {
    super(
      `Custom TUI overlays (ctx.ui.custom) are not supported in Picky (sessionId=${sessionId}). Use a non-overlay alternative such as bash, or run the command in pi's interactive TUI.`,
      "ctx.ui.custom",
      sessionId,
    );
    this.name = "PickyOverlayUnsupportedError";
  }
}

interface ExtensionUiAnswer {
  value?: unknown;
  confirmed?: boolean;
  cancelled?: boolean;
}

interface AskUserQuestionOption {
  value: string;
  label: string;
  description?: string;
}

interface AskUserQuestion {
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

interface AskUserQuestionRequest {
  title?: string;
  description?: string;
  questions: AskUserQuestion[] | string;
}

export type DialogMethod = "select" | "confirm" | "input" | "editor" | "askUserQuestion";

interface PendingDialog {
  method: DialogMethod;
  request: PickyExtensionUiRequest;
  resolve: (value: unknown) => void;
  presented: boolean;
  timer?: NodeJS.Timeout;
  cleanup?: () => void;
}

type AutocompleteProviderFactory = Parameters<ExtensionUIContext["addAutocompleteProvider"]>[0];

export interface ExtensionAutocompleteCapabilities {
  generation: number;
  triggerCharacters: string[];
}

export interface ExtensionAutocompleteQuery {
  lines: string[];
  cursorLine: number;
  cursorCol: number;
  force?: boolean;
  signal: AbortSignal;
}

export interface ExtensionAutocompleteCompletion {
  lines: string[];
  cursorLine: number;
  cursorCol: number;
}

interface ExtensionUiBridgeOptions {
  disableBlockingDialogs?: boolean;
  allowedBlockingDialogMethods?: readonly DialogMethod[];
  autocompleteGeneration?: number;
  createBaseAutocompleteProvider?: () => AutocompleteProvider;
}

export class ExtensionUiBridge extends EventEmitter {
  private pending = new Map<string, PendingDialog>();
  private queuedDialogIds: string[] = [];
  private activeDialogId: string | undefined;
  private cancellingAll = false;
  private editorText = "";
  private autocompleteProviderFactories: AutocompleteProviderFactory[] = [];
  private composedAutocompleteProvider: AutocompleteProvider | undefined;

  constructor(private readonly sessionId: string, private readonly options: ExtensionUiBridgeOptions = {}) {
    super();
  }

  createContext(): ExtensionUIContext {
    // Strict implementation: typed as `ExtensionUIContext` directly (no Partial<>),
    // so a future pi version that adds a method to ExtensionUIContext breaks this
    // assignment at compile time and forces us to add an explicit stub here.
    // Removed pi keys would surface as a TS "object literal may only specify known
    // properties" error in the same spot. Picky-internal extras such as the
    // snake_case `ask_user_question` alias are layered on AFTER the strict cast
    // so they cannot accidentally cover for a missing pi method.
    const askUserQuestion = (request: AskUserQuestionRequest, opts?: { signal?: AbortSignal; timeout?: number }) =>
      this.dialog("askUserQuestion", normalizeAskUserQuestionRequest(request, opts?.timeout), opts?.signal) as Promise<Record<string, unknown> | undefined>;

    const piStrictContext: ExtensionUIContext = {
      select: (title, options, opts) => this.dialog("select", { title, options, timeout: opts?.timeout }, opts?.signal) as Promise<string | undefined>,
      confirm: (title, message, opts) => this.dialog("confirm", { title, prompt: message, timeout: opts?.timeout }, opts?.signal) as Promise<boolean>,
      input: (title, placeholder, opts) => this.dialog("input", { title, prompt: placeholder, timeout: opts?.timeout }, opts?.signal) as Promise<string | undefined>,
      editor: (title, prefill) => this.dialog("editor", { title, prompt: prefill }) as Promise<string | undefined>,
      notify: (message, type) => void this.fireAndForget("notify", { prompt: message, notifyType: type ?? "info" }),
      setStatus: (key, text) => void this.fireAndForget("setStatus", { statusKey: key, statusText: text }),
      // Picky has no TUI widget surface. High-frequency widgets such as the
      // subagent spinner can call this every ~150ms; forwarding those no-op
      // updates through agentd floods logs/session snapshots and makes the HUD
      // render loop expensive. Keep the API available for extensions, but drop
      // the update at the host boundary.
      setWidget: () => undefined,
      setTitle: (title) => void this.fireAndForget("setTitle", { title }),
      setEditorText: (text) => this.replaceEditorText(text),
      pasteToEditor: (text) => this.appendEditorText(text),
      getEditorText: () => this.editorText,
      custom: async <T>(): Promise<T> => {
        // Picky has no TUI overlay surface. Reject with a named subclass so that
        // (a) extensions that wrap the call in try/catch keep their explicit error
        // path and (b) the agentd-level unhandled rejection guard can swallow only
        // this specific error without masking real daemon bugs.
        throw new PickyOverlayUnsupportedError(this.sessionId);
      },
      onTerminalInput: () => () => undefined,
      setWorkingMessage: () => undefined,
      setWorkingVisible: () => undefined,
      setWorkingIndicator: () => undefined,
      setHiddenThinkingLabel: () => undefined,
      setFooter: () => undefined,
      setHeader: () => undefined,
      addAutocompleteProvider: (factory) => this.addAutocompleteProvider(factory),
      // Pi custom editors are terminal components that consume raw key sequences and
      // render ANSI rows. Picky keeps its native AppKit editor, so the generic editor
      // component contract remains intentionally unsupported. The HUD projects the
      // active autocomplete prefix with native temporary text attributes instead.
      setEditorComponent: () => undefined,
      getEditorComponent: () => undefined,
      getToolsExpanded: () => false,
      setToolsExpanded: () => undefined,
      // pi's Theme shape is intentionally large and TUI-specific. Picky has no TUI
      // surface, so we expose an opaque empty stub; extensions that read theme
      // colors do their own undefined-guarding because pi's ExtensionUIContext does
      // not currently require non-null fields here.
      theme: {} as ExtensionUIContext["theme"],
      getAllThemes: () => [],
      getTheme: () => undefined,
      setTheme: () => ({ success: false, error: "Picky daemon does not manage Pi TUI themes" }),
    };
    return Object.assign(piStrictContext, {
      // Picky-side extras pi does not declare on ExtensionUIContext. Kept outside the
      // strict object so a future pi rename / removal of `askUserQuestion` is caught
      // by the strict block above instead of being silently masked by these.
      askUserQuestion,
      ask_user_question: askUserQuestion,
    });
  }

  autocompleteCapabilities(): ExtensionAutocompleteCapabilities {
    const provider = this.autocompleteProvider();
    return {
      generation: this.options.autocompleteGeneration ?? 0,
      triggerCharacters: [...(provider.triggerCharacters ?? [])],
    };
  }

  async getAutocompleteSuggestions(query: ExtensionAutocompleteQuery): Promise<AutocompleteSuggestions | null> {
    return this.autocompleteProvider().getSuggestions(
      query.lines,
      query.cursorLine,
      query.cursorCol,
      { signal: query.signal, force: query.force },
    );
  }

  applyAutocompleteCompletion(
    lines: string[],
    cursorLine: number,
    cursorCol: number,
    item: AutocompleteItem,
    prefix: string,
  ): ExtensionAutocompleteCompletion {
    return this.autocompleteProvider().applyCompletion(lines, cursorLine, cursorCol, item, prefix);
  }

  /**
   * Resolve a pending extension UI dialog.
   *
   * Returns `true` if the dialog was found and resolved, `false` if the request id
   * is unknown (already resolved, timed out, aborted, or referencing a previous
   * bridge instance after a runtime reset). Callers decide whether unknown ids are
   * a hard error (strict user-driven answer) or a no-op (idempotent cleanup such as
   * supervisor cancel-on-followUp), so this method itself does not throw.
   */
  answer(requestId: string, answer: ExtensionUiAnswer): boolean {
    return this.resolveDialog(requestId, answer);
  }

  /**
   * Cancel every blocking dialog owned by this bridge, including requests that
   * are queued behind the currently visible dialog. This must run before Pi's
   * session abort so tools blocked on ctx.ui.confirm/input can settle instead
   * of deadlocking the abort itself.
   */
  cancelAll(): number {
    const requestIds = [...this.pending.keys()];
    if (requestIds.length === 0) return 0;
    this.cancellingAll = true;
    try {
      for (const requestId of requestIds) this.resolveDialog(requestId, { cancelled: true });
    } finally {
      this.queuedDialogIds = [];
      this.activeDialogId = undefined;
      this.cancellingAll = false;
    }
    return requestIds.length;
  }

  private addAutocompleteProvider(factory: AutocompleteProviderFactory): void {
    this.autocompleteProviderFactories.push(factory);
    this.composedAutocompleteProvider = undefined;
  }

  private autocompleteProvider(): AutocompleteProvider {
    if (this.composedAutocompleteProvider) return this.composedAutocompleteProvider;
    let provider = this.options.createBaseAutocompleteProvider?.() ?? emptyAutocompleteProvider;
    const triggerCharacters = [...(provider.triggerCharacters ?? [])];
    for (const factory of this.autocompleteProviderFactories) {
      provider = factory(provider);
      triggerCharacters.push(...(provider.triggerCharacters ?? []));
    }
    if (triggerCharacters.length > 0) {
      provider.triggerCharacters = [...new Set(triggerCharacters)];
    }
    this.composedAutocompleteProvider = provider;
    return provider;
  }

  private dialog(method: DialogMethod, payload: Record<string, unknown>, signal?: AbortSignal): Promise<unknown> {
    if (this.options.disableBlockingDialogs && !this.options.allowedBlockingDialogMethods?.includes(method)) {
      return Promise.reject(new Error(`Interactive user dialogs (${method}) are not available for Picky. Delegate to Pickle via picky_start_pickle if user input is required.`));
    }
    if (signal?.aborted) return Promise.resolve(this.mapAnswer(method, { cancelled: true }));

    const id = `ext-ui-${randomUUID()}`;
    const request = this.request(id, method, payload);
    return new Promise((resolve) => {
      const pending: PendingDialog = { method, request, resolve, presented: false };
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
      if (this.activeDialogId) {
        this.queuedDialogIds.push(id);
      } else {
        this.presentDialog(id);
      }
    });
  }

  private resolveDialog(requestId: string, answer: ExtensionUiAnswer): boolean {
    const pending = this.pending.get(requestId);
    if (!pending) return false;
    this.pending.delete(requestId);
    if (pending.timer) clearTimeout(pending.timer);
    pending.cleanup?.();
    if (this.activeDialogId === requestId) this.activeDialogId = undefined;
    if (answer.cancelled && pending.presented) this.emit("cancelled", requestId);
    pending.resolve(this.mapAnswer(pending.method, answer));
    if (!this.cancellingAll) this.presentNextDialog();
    return true;
  }

  private presentDialog(requestId: string): void {
    const pending = this.pending.get(requestId);
    if (!pending || this.activeDialogId) return;
    pending.presented = true;
    this.activeDialogId = requestId;
    this.emit("request", pending.request, true);
  }

  private presentNextDialog(): void {
    while (!this.activeDialogId) {
      const requestId = this.queuedDialogIds.shift();
      if (!requestId) return;
      if (!this.pending.has(requestId)) continue;
      this.presentDialog(requestId);
    }
  }

  private fireAndForget(method: ExtensionUiMethod, payload: Record<string, unknown>): void {
    this.emit("request", this.request(`ext-ui-${randomUUID()}`, method, payload), false);
  }

  private replaceEditorText(text: unknown): void {
    this.editorText = editorTextValue(text);
    this.fireAndForget("set_editor_text", { text: this.editorText });
  }

  private appendEditorText(text: unknown): void {
    this.replaceEditorText(`${this.editorText}${editorTextValue(text)}`);
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
      text: typeof payload.text === "string" ? payload.text : undefined,
      notifyType: notifyTypeValue(payload.notifyType),
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

const emptyAutocompleteProvider: AutocompleteProvider = {
  async getSuggestions() {
    return null;
  },
  applyCompletion(lines, cursorLine, cursorCol, item, prefix) {
    const currentLine = lines[cursorLine] ?? "";
    const prefixStart = Math.max(0, cursorCol - prefix.length);
    const nextLines = [...lines];
    nextLines[cursorLine] = `${currentLine.slice(0, prefixStart)}${item.value}${currentLine.slice(cursorCol)}`;
    return { lines: nextLines, cursorLine, cursorCol: prefixStart + item.value.length };
  },
};

function notifyTypeValue(value: unknown): PickyExtensionNotifyType | undefined {
  if (value === "info" || value === "warning" || value === "error") return value;
  return undefined;
}

function editorTextValue(value: unknown): string {
  if (typeof value === "string") return value;
  if (value === undefined || value === null) return "";
  return String(value);
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
