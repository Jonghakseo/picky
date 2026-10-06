/**
 * The room composer.
 *
 * Source: Picky/HUD/Conversation/PickyConversationComposerView.swift and its
 * policy file. Every decision (what the send button does, what the placeholder
 * says, when the stop button exists, how a queue is restored) comes from
 * `../policy/composer.ts` and `../policy/stop.ts`; this file only assembles
 * controls and sends commands.
 */
import type { JSX } from "preact";
import { useCallback, useEffect, useMemo, useRef, useState } from "preact/hooks";

import type { PickyAgentSession, ThinkingLevel } from "../../../../src/protocol";
import type { RemoteCommand, RemoteDictationAvailability } from "../../../../src/remote/protocol";
import type { RoomActions } from "../contract";
import { ArrowTurnDownRight, ArrowUp, ChevronDownSmall, Mic, Paperclip, PlayFill, StopFill, Terminal, VoiceWarning, Waveform, Xmark } from "../icons";
import { t } from "../i18n";
import type { QueueEdit } from "../MessageList";
import type { SubmitKind } from "../policy/composer";
import {
  afterCurrentReplySubmitKind,
  canStop,
  composerBorderState,
  defaultSubmitKind,
  draftAppendingTranscript,
  draftRestoringQueuedInputs,
  effectiveBashMode,
  placeholderKey,
  returnKeyAction,
  settingsChipParts,
  submitPresentation,
  submitStatus,
} from "../policy/composer";
import { sendTimingOptions } from "../policy/schedule";
import { SingleFlightSubmitter, draftAfterFailedSend } from "../policy/submit";
import type { SlashCommand } from "../policy/slash";
import { SLASH_SOURCE_LABEL, parseSlashCommands, slashCompletion, slashKeyAction, slashQuery, slashSuggestions } from "../policy/slash";
import type { AbortScope, StopChoice } from "../policy/stop";
import { stopChoiceForSession } from "../policy/stop";
import { locale } from "../i18n";
import type { RuntimeOptions } from "./SettingsSheet";
import { SettingsSheet, parseRuntimeOptions } from "./SettingsSheet";
import { SendTimingMenu } from "./SendTimingMenu";
import { StopChoiceSheet } from "./StopChoiceSheet";
import { useDictation } from "./useDictation";

export interface Attachment {
  /** Local key before the upload finishes. */
  key: string;
  name: string;
  uploadId?: string;
  previewUrl: string;
  failed?: boolean;
}

export interface ComposerProps {
  /** The session this composer sends to; ignored in the main room. */
  sessionId: string;
  isMain: boolean;
  session?: PickyAgentSession;
  mainBusy: boolean;
  macConnected: boolean;
  /** The phone's socket to the gateway is open (`RoomViewModel.online`). */
  online: boolean;
  dictationAvailability: RemoteDictationAvailability;
  draft: string;
  onDraft: (text: string) => void;
  edit: QueueEdit | null;
  onCancelEdit: () => void;
  actions: RoomActions;
  send: (command: RemoteCommand) => Promise<boolean>;
  /** Ticks once a second while something is live, for the recording timer. */
  now: number;
}

export function Composer(props: ComposerProps): JSX.Element {
  const { session, isMain, sessionId, draft, onDraft, actions, send } = props;
  const [focused, setFocused] = useState(false);
  const [composing, setComposing] = useState(false);
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [timingOpen, setTimingOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [runtimeOptions, setRuntimeOptions] = useState<RuntimeOptions | null>(null);
  const [stopSheet, setStopSheet] = useState<Exclude<StopChoice, "immediate"> | null>(null);
  const fileInput = useRef<HTMLInputElement | null>(null);
  const editor = useRef<HTMLTextAreaElement | null>(null);
  const [caret, setCaret] = useState<number | undefined>(undefined);
  const slash = useSlashCommands(isMain ? null : sessionId, isMain ? null : slashQuery(draft, caret ?? draft.length), actions);
  const pointerKeyboard = useHardwareKeyboard();
  // An arrow key proves a hardware keyboard even where the pointer is a finger
  // (an iPad with a keyboard case), so Return then takes the selected row.
  const [keyboardSeen, setKeyboardSeen] = useState(false);
  const hardwareKeyboard = pointerKeyboard || keyboardSeen;
  // Esc hides the list for the draft it was pressed on; typing brings it back.
  const [slashDismissedFor, setSlashDismissedFor] = useState<string | null>(null);
  const suggestions = slash && slashDismissedFor !== draft ? slashSuggestions(draft, caret, slash) : [];
  const [slashIndex, setSlashIndex] = useState(0);
  const selectedSlash = Math.min(slashIndex, Math.max(0, suggestions.length - 1));
  const pendingCaret = useRef<number | null>(null);
  // One send at a time: Return pressed again while the first send waits for the
  // Mac would otherwise post the same text again under a new command id.
  const [sending, setSending] = useState(false);
  const [submitter] = useState(() => new SingleFlightSubmitter(setSending));
  // The draft as of the latest render, read after an await to restore a failed send.
  const latestDraft = useRef(draft);
  latestDraft.current = draft;
  const slashListId = `slash-${sessionId}`;

  const status = session?.status ?? "waiting_for_input";
  const sendStatus = submitStatus(status, session?.agentCycle?.phase);
  const bashMode = isMain ? "none" : effectiveBashMode(draft, attachments.length);
  const isRunning = status === "running";
  const border = composerBorderState({ bashMode, isRunning, isFocused: focused });
  const submitKind: SubmitKind = isMain ? "steer" : defaultSubmitKind(sendStatus);
  const afterReplyKind = isMain ? null : afterCurrentReplySubmitKind(sendStatus);
  const uploading = attachments.some((item) => !item.uploadId && !item.failed);
  const canSend = draft.trim().length > 0 || attachments.some((item) => item.uploadId);
  const sendEnabled = canSend && props.online && props.macConnected && !uploading && !sending;

  const dictation = useDictation({
    availability: props.dictationAvailability,
    send: actions.dictate,
    onTranscript: (text) => onDraft(draftAppendingTranscript(draft, text)),
  });

  // The textarea grows with the text, up to the HUD's four-line canvas.
  useEffect(() => {
    const node = editor.current;
    if (!node) return;
    node.style.height = "auto";
    node.style.height = `${Math.min(node.scrollHeight, 78)}px`;
    // Accepting a suggestion rewrites the draft; put the caret after "/name ".
    if (pendingCaret.current !== null) {
      node.setSelectionRange(pendingCaret.current, pendingCaret.current);
      setCaret(pendingCaret.current);
      pendingCaret.current = null;
    }
  }, [draft]);

  useEffect(() => setSlashIndex(0), [draft]);

  function acceptSlash(command: SlashCommand): void {
    const next = slashCompletion(draft, caret, command);
    pendingCaret.current = next.caret;
    onDraft(next.text);
    editor.current?.focus();
  }

  const trackCaret = (event: JSX.TargetedEvent<HTMLTextAreaElement>): void => setCaret(event.currentTarget.selectionStart);

  /** Arrow keys move through the slash list, Return or Tab take the row, Esc closes it, as in the HUD. */
  function handleSlashKey(event: JSX.TargetedKeyboardEvent<HTMLTextAreaElement>, composingNow: boolean): boolean {
    const count = suggestions.length;
    const action = slashKeyAction({
      key: event.key,
      shiftKey: event.shiftKey,
      altKey: event.altKey,
      metaKey: event.metaKey,
      ctrlKey: event.ctrlKey,
      composing: composingNow,
      keyboard: hardwareKeyboard,
    });
    if (action === "none") return false;
    event.preventDefault();
    switch (action) {
      case "next":
      case "previous": {
        setKeyboardSeen(true);
        const step = action === "next" ? 1 : -1;
        setSlashIndex((selectedSlash + step + count) % count);
        break;
      }
      case "accept": {
        const command = suggestions[selectedSlash];
        if (command) acceptSlash(command);
        break;
      }
      case "dismiss":
        setSlashDismissedFor(draft);
        break;
    }
    return true;
  }

  function closeTiming(): void {
    setTimingOpen(false);
    if (hardwareKeyboard) editor.current?.focus();
  }

  const uploadIds = useMemo(
    () => attachments.map((item) => item.uploadId).filter((id): id is string => typeof id === "string"),
    [attachments],
  );

  const clear = useCallback(() => {
    onDraft("");
    setAttachments([]);
    props.onCancelEdit();
  }, [onDraft, props]);

  const submit = useCallback(
    async (kind: SubmitKind) => {
      const text = draft.trim();
      const edit = props.edit;
      if (edit) {
        // An edit keeps its draft until the Mac accepts it: clearing early would
        // also leave edit mode, and a retry would then send a new message.
        await submitter.run<RemoteCommand>({
          take: () => {
            if (text.length === 0) return null;
            return edit.kind === "scheduled"
              ? { type: "session.scheduled.edit", sessionId, scheduledId: edit.scheduledId, text }
              : { type: "session.queue.edit", sessionId, itemId: edit.itemId, text };
          },
          send,
          onSuccess: clear,
        });
        return;
      }
      await submitter.run({
        take: () => {
          if (text.length === 0 && uploadIds.length === 0) return null;
          const command: RemoteCommand = isMain
            ? { type: "main.send", text, uploadIds: uploadIds.length > 0 ? uploadIds : undefined }
            : { type: "session.send", sessionId, text, kind, uploadIds: uploadIds.length > 0 ? uploadIds : undefined };
          const snapshot = { command, draft, attachments };
          // Clear before the round trip so Return visibly worked.
          onDraft("");
          setAttachments([]);
          return snapshot;
        },
        send: (snapshot) => send(snapshot.command),
        onFailure: (snapshot) => {
          onDraft(draftAfterFailedSend(latestDraft.current, snapshot.draft));
          setAttachments((list) => [...snapshot.attachments, ...list]);
        },
      });
    },
    [attachments, clear, draft, isMain, onDraft, props.edit, send, sessionId, submitter, uploadIds],
  );

  async function attach(files: FileList | null): Promise<void> {
    if (!files) return;
    for (const file of Array.from(files)) {
      const key = `${file.name}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
      const previewUrl = URL.createObjectURL(file);
      setAttachments((list) => [...list, { key, name: file.name, previewUrl }]);
      try {
        const response = await actions.upload(file, file.name);
        setAttachments((list) =>
          list.map((item) => (item.key === key ? { ...item, uploadId: response.uploadId } : item)),
        );
      } catch {
        setAttachments((list) => list.map((item) => (item.key === key ? { ...item, failed: true } : item)));
      }
    }
  }

  async function openSettings(): Promise<void> {
    setSettingsOpen(true);
    const response = await actions.query({ type: "session.runtimeOptions", sessionId });
    setRuntimeOptions(parseRuntimeOptions(response.ok ? response.data : null));
  }

  function stop(): void {
    if (isMain) {
      void send({ type: "main.abort" });
      return;
    }
    if (!session) return;
    const choice = stopChoiceForSession(session);
    if (choice === "immediate") {
      void abort("response");
      return;
    }
    setStopSheet(choice);
  }

  /** The HUD puts queued input back in the composer before it aborts, so nothing is lost. */
  async function abort(scope: AbortScope): Promise<void> {
    setStopSheet(null);
    const queued = [...(session?.queuedSteers ?? []), ...(session?.queuedFollowUps ?? [])];
    const restored = draftRestoringQueuedInputs(draft, queued);
    if (restored !== null) {
      onDraft(restored);
      await send({ type: "session.queue.clear", sessionId, kind: "all" });
    }
    await send({ type: "session.abort", sessionId, scope });
  }

  const placeholder = isMain
    ? t("remote.room.composer.placeholder.steer")
    : t(placeholderKey(sendStatus, session?.agentCycle?.phase === "compacting"));
  // The Picky room only sends; it has no follow-up of its own.
  const submit_ = submitPresentation(isMain ? null : submitKind, bashMode);
  const showStop = isMain ? props.mainBusy : canStop(status, (session?.messages ?? []).length > 0);

  return (
    <>
      <VoiceRow dictation={dictation} now={props.now} />
      <Note edit={props.edit} online={props.online} macConnected={props.macConnected} attachments={attachments} />
      <div class="room-composer">
        {/* How many suggestions there are, said once when the list changes. */}
        <span class="sr-only" role="status">
          {suggestions.length > 0 ? t("remote.room.slash.count", suggestions.length) : ""}
        </span>
        {suggestions.length > 0 ? (
          <SlashPanel
            id={slashListId}
            suggestions={suggestions}
            selectedIndex={hardwareKeyboard ? selectedSlash : -1}
            onHover={setSlashIndex}
            onAccept={acceptSlash}
          />
        ) : null}
        <div class={`composer is-${border}`}>
          {attachments.length > 0 ? (
            <div class="composer-attachments">
              {attachments.map((item) => (
                <div class={`attachment-chip${item.failed ? " is-failed" : ""}`} key={item.key}>
                  <span class="attachment-thumb">
                    <img src={item.previewUrl} alt="" />
                  </span>
                  <span class="attachment-name">{item.name}</span>
                  <button
                    class="attachment-remove"
                    type="button"
                    aria-label={t("remote.room.attachment.remove")}
                    onClick={() => setAttachments((list) => list.filter((entry) => entry.key !== item.key))}
                  >
                    <Xmark />
                  </button>
                </div>
              ))}
            </div>
          ) : null}
          <textarea
            ref={editor}
            class="composer-editor"
            rows={1}
            value={draft}
            placeholder={placeholder}
            // A multi-line textbox with list autocomplete: the caret stays in the
            // field while the list's active row is announced. `role="combobox"`
            // is not allowed on a textarea, and a textbox needs no aria-expanded.
            aria-label={placeholder}
            aria-autocomplete="list"
            aria-controls={suggestions.length > 0 ? slashListId : undefined}
            aria-activedescendant={suggestions.length > 0 && hardwareKeyboard ? slashOptionId(slashListId, selectedSlash) : undefined}
            onInput={(event: JSX.TargetedEvent<HTMLTextAreaElement>) => {
              setCaret(event.currentTarget.selectionStart);
              onDraft(event.currentTarget.value);
            }}
            onSelect={trackCaret}
            onClick={trackCaret}
            onKeyUp={trackCaret}
            onFocus={() => setFocused(true)}
            onBlur={() => setFocused(false)}
            onCompositionStart={() => setComposing(true)}
            onCompositionEnd={() => setComposing(false)}
            onKeyDown={(event: JSX.TargetedKeyboardEvent<HTMLTextAreaElement>) => {
              // Korean IME: Return while composing commits the syllable. Safari
              // reports that keydown with keyCode 229 after compositionend.
              const imeComposing = composing || event.isComposing || event.keyCode === 229;
              if (imeComposing && event.key === "Enter") {
                event.stopPropagation();
                return;
              }
              if (suggestions.length > 0 && handleSlashKey(event, imeComposing)) return;
              const action = returnKeyAction({
                key: event.key,
                shiftKey: event.shiftKey,
                altKey: event.altKey,
                metaKey: event.metaKey,
                ctrlKey: event.ctrlKey,
                composing: imeComposing,
                hardwareKeyboard,
              });
              if (action === "none" || action === "newline") return;
              event.preventDefault();
              if (!sendEnabled) return;
              // The Picky room has no "after this reply": its queue is the main agent's.
              void submit(action === "submitAfterReply" && afterReplyKind !== null ? afterReplyKind : submitKind);
            }}
          />
          <div class="composer-actions">
            <div class="actions-leading">
              <button
                class="toolbar-icon"
                type="button"
                aria-label={t("hud.composer.attachment.accessibilityLabel")}
                onClick={() => fileInput.current?.click()}
              >
                <Paperclip />
              </button>
              {/* The paperclip button is the control; this input only opens the picker. */}
              <input
                ref={fileInput}
                class="sr-only"
                type="file"
                tabIndex={-1}
                aria-hidden="true"
                accept="image/*"
                multiple
                onChange={(event: JSX.TargetedEvent<HTMLInputElement>) => {
                  void attach(event.currentTarget.files);
                  event.currentTarget.value = "";
                }}
              />
              {bashMode !== "none" ? (
                <span class={`bash-badge${bashMode === "private" ? " is-private" : ""}`}>
                  <Terminal />
                  <span class="bash-badge-text">{bashMode === "private" ? "!!" : "!"}</span>
                </span>
              ) : null}
              {isMain ? null : (
                <SettingsChip session={session} onOpen={() => void openSettings()} />
              )}
            </div>
            <div class="actions-trailing">
              <div class="actions-tools">
                <button
                  class={`toolbar-icon${dictation.state.kind === "listening" ? " is-active" : ""}`}
                  type="button"
                  aria-label={t("hud.composer.mic.accessibilityLabel")}
                  disabled={dictation.state.kind === "transcribing"}
                  onClick={dictation.toggle}
                >
                  {dictation.state.kind === "listening" ? <Waveform /> : <Mic />}
                </button>
              </div>
              <div class="actions-primary">
                {showStop ? (
                  <button
                    class="toolbar-icon is-stop"
                    type="button"
                    aria-label={t("hud.composer.stop.accessibilityLabel")}
                    onClick={stop}
                  >
                    <StopFill />
                  </button>
                ) : null}
                <div class={`send${sendEnabled ? "" : " is-disabled"}${timingOpen ? " is-menu-open" : ""}`}>
                  <button
                    class="send-main"
                    type="button"
                    aria-label={t(submit_.labelKey)}
                    disabled={!sendEnabled}
                    onClick={() => void submit(submitKind)}
                  >
                    {submit_.icon === "play" ? <PlayFill /> : submit_.icon === "turnDownRight" ? <ArrowTurnDownRight /> : <ArrowUp />}
                  </button>
                  {isMain ? null : (
                    <>
                      <span class="send-divider" aria-hidden="true" />
                      <button
                        class="send-chevron"
                        type="button"
                        aria-label={t("hud.composer.sendTiming.accessibilityLabel")}
                        disabled={!canSend || !props.online || !props.macConnected || sending}
                        onClick={() => setTimingOpen(true)}
                      >
                        <ChevronDownSmall />
                      </button>
                    </>
                  )}
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
      {timingOpen ? (
        <SendTimingMenu
          options={sendTimingOptions({
            now: Date.now(),
            locale: locale(),
            canSendAfterCurrentReply: afterReplyKind !== null,
            hasAttachments: attachments.length > 0,
          })}
          onAfterCurrentReply={() => {
            setTimingOpen(false);
            void submit(afterReplyKind ?? "followUp");
          }}
          onSchedule={(delayMs) => {
            setTimingOpen(false);
            const text = draft.trim();
            void submitter.run<RemoteCommand>({
              take: () => (text.length === 0 ? null : { type: "session.schedule", sessionId, text, delayMs }),
              send,
              onSuccess: clear,
            });
          }}
          onDismiss={closeTiming}
        />
      ) : null}
      {settingsOpen ? (
        <SettingsSheet
          options={runtimeOptions}
          model={session?.currentAssistantRun?.model}
          thinkingLevel={session?.currentAssistantRun?.thinkingLevel as ThinkingLevel | undefined}
          fastMode={session?.fastMode === true}
          fastModeSupported={session?.fastModeSupported === true}
          notifyMain={session?.notifyMainOnCompletion === true}
          notifyMacOS={session?.notifyMacOSOnCompletion === true}
          onSelectModel={(model) =>
            void send({ type: "session.setModel", sessionId, provider: model.provider, modelId: model.modelId })
          }
          onSelectThinking={(level) => void send({ type: "session.setThinking", sessionId, thinkingLevel: level })}
          onToggleFast={(enabled) => void send({ type: "session.setFast", sessionId, enabled })}
          onToggleNotify={(target, enabled) => void send({ type: "session.setNotify", sessionId, target, enabled })}
          onDismiss={() => setSettingsOpen(false)}
        />
      ) : null}
      {stopSheet ? (
        <StopChoiceSheet choice={stopSheet} onStop={(scope) => void abort(scope)} onDismiss={() => setStopSheet(null)} />
      ) : null}
    </>
  );
}

/**
 * The Pickle's slash commands, fetched once a "/" word is being typed and kept
 * for the room. A failed fetch tries again the next time a "/" word starts,
 * not on every keystroke. `null` until a list is available.
 */
function useSlashCommands(sessionId: string | null, query: string | null, actions: RoomActions): SlashCommand[] | null {
  const [held, setHeld] = useState<{ sessionId: string; commands: SlashCommand[] } | null>(null);
  const inFlight = useRef<string | null>(null);
  const typing = query !== null;
  useEffect(() => {
    if (!sessionId || !typing) return;
    if (held?.sessionId === sessionId || inFlight.current === sessionId) return;
    inFlight.current = sessionId;
    void actions.query({ type: "session.slashCommands", sessionId }).then((response) => {
      if (inFlight.current !== sessionId) return;
      inFlight.current = null;
      if (response.ok) setHeld({ sessionId, commands: parseSlashCommands(response.data) });
    });
    // `actions` is rebuilt every render by the shell.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId, typing, held]);
  return held && held.sessionId === sessionId ? held.commands : null;
}

/** Rows above the composer, as `PickyComposerAutocompletePanelView` draws them. */
function slashOptionId(listId: string, index: number): string {
  return `${listId}-option-${index}`;
}

function SlashPanel({
  id,
  suggestions,
  selectedIndex,
  onHover,
  onAccept,
}: {
  id: string;
  suggestions: SlashCommand[];
  /** Keyboard selection; -1 on a touch screen, where rows are only tapped. */
  selectedIndex: number;
  /** A pointer over a row moves the keyboard selection to it, as in the HUD. */
  onHover: (index: number) => void;
  onAccept: (command: SlashCommand) => void;
}): JSX.Element {
  const panel = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    panel.current?.querySelector(".slash-row.is-selected")?.scrollIntoView({ block: "nearest" });
  }, [selectedIndex]);
  return (
    <div class="slash-panel" id={id} role="listbox" aria-label={t("remote.room.slash.accessibilityLabel")} ref={panel}>
      {suggestions.map((command, index) => (
        <button
          key={`${command.source}:${command.name}`}
          id={slashOptionId(id, index)}
          // The caret stays in the composer; rows are reached with the arrows.
          tabIndex={-1}
          onPointerEnter={(event: PointerEvent) => {
            if (event.pointerType === "mouse") onHover(index);
          }}
          class={`slash-row${index === selectedIndex ? " is-selected" : ""}`}
          type="button"
          role="option"
          aria-selected={index === selectedIndex}
          // Keep the keyboard up: the textarea must not lose focus on the tap.
          onPointerDown={(event) => event.preventDefault()}
          onClick={() => onAccept(command)}
        >
          <span class="slash-name">/{command.name}</span>
          <span class="slash-source">{SLASH_SOURCE_LABEL[command.source]}</span>
          {command.description ? <span class="slash-description">{command.description}</span> : null}
        </button>
      ))}
    </div>
  );
}

/**
 * True with a mouse or trackpad (a browser on the Mac, an iPad with a
 * keyboard case), where Return can send. A phone keyboard keeps Return as a
 * new line.
 */
function useHardwareKeyboard(): boolean {
  const query = "(hover: hover) and (pointer: fine)";
  const [matches, setMatches] = useState(() => globalThis.matchMedia?.(query).matches ?? false);
  useEffect(() => {
    const list = globalThis.matchMedia?.(query);
    if (!list) return;
    const update = (): void => setMatches(list.matches);
    list.addEventListener("change", update);
    return () => list.removeEventListener("change", update);
  }, []);
  return matches;
}

/** Model and fast mode at a glance, opening the Pickle settings menu. */
/** Model, thinking level and Fast at a glance (`opus-5-5 · high`), opening the Pickle settings menu. */
function SettingsChip({ session, onOpen }: { session?: PickyAgentSession; onOpen: () => void }): JSX.Element {
  const { model, suffixes } = settingsChipParts(session?.currentAssistantRun, session?.fastMode === true, t("hud.composer.settings.chip.fast"));
  const value = [model, ...suffixes].filter((part): part is string => part !== null).join(", ");
  return (
    <button
      class="settings-chip"
      type="button"
      // The HUD's label plus its accessibilityValue: what it is, then what is set.
      aria-label={value ? `${t("hud.composer.settings.accessibilityLabel")}, ${value}` : t("hud.composer.settings.accessibilityLabel")}
      onClick={onOpen}
    >
      {model ? (
        <span class="chip-model">
          <span class="chip-text">{model}</span>
        </span>
      ) : null}
      {suffixes.map((suffix, index) => (
        <>
          {index > 0 || model ? (
            <span class="chip-sep" aria-hidden="true">
              ·
            </span>
          ) : null}
          <span class="chip-text">{suffix}</span>
        </>
      ))}
      {!model && suffixes.length === 0 ? <span class="chip-text">{t("hud.composer.settings.chip.empty")}</span> : null}
      <span class="chip-chevron" aria-hidden="true">
        <ChevronDownSmall />
      </span>
    </button>
  );
}

/** The one-line voice status the HUD shows above the composer while dictating. */
function VoiceRow({
  dictation,
  now,
}: {
  dictation: ReturnType<typeof useDictation>;
  now: number;
}): JSX.Element | null {
  const state = dictation.state;
  if (state.kind === "idle") return null;
  let tone = "";
  let primary = "";
  let hint: string | null = null;
  switch (state.kind) {
    case "preparing":
      primary = t("hud.composer.voice.preparing");
      break;
    case "listening":
      tone = " is-listening";
      primary = t("hud.composer.voice.listening", elapsed(state.startedAt, now));
      hint = t("remote.room.voice.listening.hint");
      break;
    case "transcribing":
      primary = t("hud.composer.voice.transcribing");
      hint = t("hud.composer.voice.transcribing.hint");
      break;
    case "failed":
      tone = " is-failed";
      primary = t("hud.composer.voice.failed");
      hint = t("hud.composer.voice.failed.hint");
      break;
    case "permission":
      tone = " is-failed";
      primary = t("hud.composer.voice.permission");
      hint = t("remote.room.voice.permission.hint");
      break;
    case "macUnavailable":
      tone = " is-failed";
      primary = t("remote.room.voice.macUnavailable");
      hint =
        state.reason === "macPermission"
          ? t("remote.room.voice.macUnavailable.permission.hint")
          : state.reason === "macService"
            ? t("remote.room.voice.macUnavailable.service.hint")
            : null;
      break;
  }
  const recording = state.kind === "listening" || state.kind === "preparing";
  return (
    <div class={`voice-row${tone}`} role="status">
      <span class="voice-icon" aria-hidden="true">
        {tone === " is-failed" ? <VoiceWarning /> : recording ? <Waveform /> : <Mic />}
      </span>
      <span class="voice-text">
        <span class="voice-primary">{primary}</span>
        {hint ? <span class="voice-hint">{hint}</span> : null}
      </span>
      {recording ? (
        <button
          class="voice-cancel"
          type="button"
          aria-label={t("remote.room.voice.cancel")}
          onClick={dictation.cancel}
        >
          <Xmark />
        </button>
      ) : null}
    </div>
  );
}

/** Why sending is blocked, or what the composer is editing right now. */
function Note({
  edit,
  online,
  macConnected,
  attachments,
}: {
  edit: QueueEdit | null;
  online: boolean;
  macConnected: boolean;
  attachments: Attachment[];
}): JSX.Element | null {
  if (!online) return <div class="composer-note" role="status">{t("remote.room.composer.reconnecting")}</div>;
  if (!macConnected) return <div class="composer-note is-error" role="alert">{t("remote.room.composer.macOffline")}</div>;
  if (attachments.some((item) => item.failed)) {
    return <div class="composer-note is-error" role="alert">{t("remote.room.attachment.failed")}</div>;
  }
  if (attachments.some((item) => !item.uploadId)) {
    return <div class="composer-note" role="status">{t("remote.room.attachment.uploading")}</div>;
  }
  if (edit) {
    return (
      <div class="composer-note" role="status">
        {t(edit.kind === "scheduled" ? "remote.room.composer.editingScheduled" : "remote.room.composer.editingQueued")}
      </div>
    );
  }
  return null;
}

function elapsed(startedAt: number, now: number): string {
  const seconds = Math.max(0, Math.floor((now - startedAt) / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}
