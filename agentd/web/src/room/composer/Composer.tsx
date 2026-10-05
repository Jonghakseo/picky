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
import { ArrowUp, ChevronUp, Mic, Paperclip, StopFill, Terminal, VoiceWarning, Waveform, Xmark } from "../icons";
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
} from "../policy/composer";
import { sendTimingOptions } from "../policy/schedule";
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

  const status = session?.status ?? "waiting_for_input";
  const bashMode = isMain ? "none" : effectiveBashMode(draft, attachments.length);
  const isRunning = status === "running";
  const border = composerBorderState({ bashMode, isRunning, isFocused: focused });
  const submitKind: SubmitKind = isMain ? "steer" : defaultSubmitKind(status);
  const afterReplyKind = isMain ? null : afterCurrentReplySubmitKind(status);
  const uploading = attachments.some((item) => !item.uploadId && !item.failed);
  const canSend = draft.trim().length > 0 || attachments.some((item) => item.uploadId);
  const sendEnabled = canSend && props.online && props.macConnected && !uploading;

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
  }, [draft]);

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
        if (text.length === 0) return;
        const command: RemoteCommand =
          edit.kind === "scheduled"
            ? { type: "session.scheduled.edit", sessionId, scheduledId: edit.scheduledId, text }
            : { type: "session.queue.edit", sessionId, itemId: edit.itemId, text };
        if (await send(command)) clear();
        return;
      }
      if (text.length === 0 && uploadIds.length === 0) return;
      const command: RemoteCommand = isMain
        ? { type: "main.send", text, uploadIds: uploadIds.length > 0 ? uploadIds : undefined }
        : { type: "session.send", sessionId, text, kind, uploadIds: uploadIds.length > 0 ? uploadIds : undefined };
      if (await send(command)) clear();
    },
    [clear, draft, isMain, props.edit, send, sessionId, uploadIds],
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
    : t(placeholderKey(status, session?.agentCycle?.phase === "compacting"));
  const showStop = isMain ? props.mainBusy : canStop(status, (session?.messages ?? []).length > 0);

  return (
    <>
      <VoiceRow dictation={dictation} now={props.now} />
      <Note edit={props.edit} online={props.online} macConnected={props.macConnected} attachments={attachments} />
      <div class="room-composer">
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
            onInput={(event: JSX.TargetedEvent<HTMLTextAreaElement>) => onDraft(event.currentTarget.value)}
            onFocus={() => setFocused(true)}
            onBlur={() => setFocused(false)}
            onCompositionStart={() => setComposing(true)}
            onCompositionEnd={() => setComposing(false)}
            onKeyDown={(event: JSX.TargetedKeyboardEvent<HTMLTextAreaElement>) => {
              // Korean IME: Return while composing commits the syllable. The phone
              // never submits on Return at all; the send button does that.
              if (event.key === "Enter" && composing) event.stopPropagation();
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
              <input
                ref={fileInput}
                class="sr-only"
                type="file"
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
                    aria-label={t(
                      submitKind === "followUp" ? "hud.composer.submit.followUp" : "hud.composer.submit.send",
                    )}
                    disabled={!sendEnabled}
                    onClick={() => void submit(submitKind)}
                  >
                    <ArrowUp />
                  </button>
                  {isMain ? null : (
                    <>
                      <span class="send-divider" aria-hidden="true" />
                      <button
                        class="send-chevron"
                        type="button"
                        aria-label={t("hud.composer.sendTiming.accessibilityLabel")}
                        disabled={!canSend || !props.online || !props.macConnected}
                        onClick={() => setTimingOpen(true)}
                      >
                        <ChevronUp />
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
            if (text.length === 0) return;
            void send({ type: "session.schedule", sessionId, text, delayMs }).then((ok) => {
              if (ok) clear();
            });
          }}
          onDismiss={() => setTimingOpen(false)}
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

/** Model and fast mode at a glance, opening the Pickle settings menu. */
function SettingsChip({ session, onOpen }: { session?: PickyAgentSession; onOpen: () => void }): JSX.Element {
  const model = session?.currentAssistantRun?.model;
  const fast = session?.fastMode === true;
  return (
    <button
      class="settings-chip"
      type="button"
      aria-label={t("hud.composer.settings.accessibilityLabel")}
      onClick={onOpen}
    >
      {model ? (
        <span class="chip-model">
          <span class="chip-text">{model}</span>
        </span>
      ) : (
        <span class="chip-text">{t("hud.composer.settings.chip.empty")}</span>
      )}
      {fast ? (
        <>
          <span class="chip-sep" aria-hidden="true">
            ·
          </span>
          <span class="chip-text">{t("hud.composer.settings.chip.fast")}</span>
        </>
      ) : null}
      <span class="chip-chevron" aria-hidden="true">
        <ChevronUp />
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
    <div class={`voice-row${tone}`}>
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
  if (!online) return <div class="composer-note">{t("remote.room.composer.reconnecting")}</div>;
  if (!macConnected) return <div class="composer-note is-error">{t("remote.room.composer.macOffline")}</div>;
  if (attachments.some((item) => item.failed)) {
    return <div class="composer-note is-error">{t("remote.room.attachment.failed")}</div>;
  }
  if (attachments.some((item) => !item.uploadId)) {
    return <div class="composer-note">{t("remote.room.attachment.uploading")}</div>;
  }
  if (edit) {
    return (
      <div class="composer-note">
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
