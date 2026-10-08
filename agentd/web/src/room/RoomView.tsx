/**
 * The conversation room: the HUD's conversation card, on a phone screen.
 *
 * The shell (`src/screens/RoomScreen.tsx`) resolves `picky:room` to this file
 * and hands over a `RoomViewModel` plus `RoomActions`; everything below renders
 * from those two alone, so the gallery can drive the same view from fixtures.
 */
import type { JSX, RefObject } from "preact";
import { useCallback, useEffect, useRef, useState } from "preact/hooks";

import type { PickyExtensionUiRequest } from "../../../src/protocol";
import type { RemoteCommand } from "../../../src/remote/protocol";
import { BackgroundWorkFooter } from "./BackgroundWorkFooter";
import { Composer } from "./composer/Composer";
import { draftRestoringQueuedInputs } from "./policy/composer";
import { answerableMethod } from "./policy/question";
import type { RoomViewProps } from "./contract";
import { Header } from "./Header";
import { ArrowDown, QuestionCircle } from "./icons";
import { setLocale, t } from "./i18n";
import type { QueueEdit } from "./MessageList";
import { MessageList } from "./MessageList";
import { WorkPanel } from "./WorkPanel";
import "./styles/room.css";

/** Below this many pixels from the bottom, new messages scroll into view. */
const NEAR_BOTTOM = 80;

export function RoomView({ vm, actions }: RoomViewProps): JSX.Element {
  const scroll = useRef<HTMLDivElement | null>(null);
  const [atBottom, setAtBottom] = useState(true);
  const [hasNew, setHasNew] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const [draft, setDraft] = useState(() => actions.loadDraft());
  const [edit, setEdit] = useState<QueueEdit | null>(null);
  const [workOpen, setWorkOpen] = useState(false);
  const [archiveBusy, setArchiveBusy] = useState(false);
  const now = useNow(isLive(vm.room.status) || vm.main?.busy === true);

  setLocale(vm.locale);

  const roomId = vm.room.id;
  useEffect(() => {
    setDraft(actions.loadDraft());
    setEdit(null);
    setFailure(null);
    setWorkOpen(false);
    setArchiveBusy(false);
    // A different room is a different conversation: start at its latest message.
    setAtBottom(true);
    setHasNew(false);
    // `actions` is rebuilt every render by the shell; the room id is the identity here.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [roomId]);

  const onDraft = useCallback(
    (text: string) => {
      setDraft(text);
      actions.saveDraft(text);
    },
    [actions],
  );

  const send = useCallback(
    async (command: RemoteCommand): Promise<boolean> => {
      const result = await actions.command(command);
      if (result.ok) {
        setFailure(null);
        actions.feedback?.("success");
        return true;
      }
      // The gateway's error text is English diagnostics; the phone shows its own copy by code.
      setFailure(t(result.error.code === "macOffline" ? "remote.room.composer.macOffline" : "remote.room.composer.sendFailed"));
      actions.feedback?.("error");
      return false;
    },
    [actions],
  );

  // The keyboard shrinks the visual viewport; the room shrinks with it so the
  // composer stays above the keyboard instead of hiding behind it.
  const root = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    const viewport = window.visualViewport;
    if (!viewport) return;
    const apply = (): void => {
      const inset = Math.max(0, window.innerHeight - viewport.height - viewport.offsetTop);
      root.current?.style.setProperty("--keyboard-inset", `${Math.round(inset)}px`);
    };
    apply();
    viewport.addEventListener("resize", apply);
    viewport.addEventListener("scroll", apply);
    return () => {
      viewport.removeEventListener("resize", apply);
      viewport.removeEventListener("scroll", apply);
    };
  }, []);

  // Auto-scroll only from the bottom: reading older messages is never interrupted.
  const signature = conversationSignature(vm);
  useEffect(() => {
    const node = scroll.current;
    if (!node) return;
    if (atBottom) {
      node.scrollTop = node.scrollHeight;
      setHasNew(false);
    } else {
      setHasNew(true);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [signature]);

  function toBottom(): void {
    const node = scroll.current;
    if (!node) return;
    node.scrollTo({ top: node.scrollHeight, behavior: "smooth" });
    setAtBottom(true);
    setHasNew(false);
  }

  // Archiving hides the Pickle from the dock, so the room has nothing left to
  // show: return to the list the way the HUD closes the card. One request at
  // a time, or a second tap would arrive after the list flipped and restore it.
  async function toggleArchive(): Promise<void> {
    if (archiveBusy) return;
    const archiving = !vm.room.archived;
    setArchiveBusy(true);
    const ok = await send({ type: "session.archive", sessionId: vm.room.id, archived: archiving });
    setArchiveBusy(false);
    if (ok && archiving) actions.back();
  }

  // A phone screen is short, so a waiting question scrolls away quickly. The bar
  // above the composer only points back at it; answering still happens in the bubble.
  const pending = vm.main ? vm.main.pendingQuestion : vm.session?.pendingExtensionUiRequest;
  const waiting = pending && answerableMethod(pending) ? pending : undefined;
  const questionOffscreen = useOffscreenQuestion(waiting?.id, scroll, signature);

  function openQuestion(): void {
    const bubble = questionElement(scroll.current, waiting?.id);
    if (!bubble) return;
    bubble.scrollIntoView({ behavior: "smooth", block: "center" });
    const control = bubble.querySelector<HTMLElement>(".q-opt, .q-field, .q-chip-btn, .q-btn.is-primary");
    control?.focus({ preventScroll: true });
  }

  const isMain = vm.room.kind === "main";
  const wide = vm.layout === "wide";
  return (
    <div class={`room-view${wide ? " is-wide" : ""}`} ref={root}>
      <Header
        title={vm.room.title}
        status={vm.room.status}
        contextUsage={vm.session?.contextUsage ? { percent: vm.session.contextUsage.percent } : undefined}
        showArchive={!isMain}
        archived={vm.room.archived}
        archiveBusy={archiveBusy}
        showWork={!isMain}
        showMenu={false}
        showBack={!wide}
        onBack={actions.back}
        onWork={() => setWorkOpen(true)}
        onArchive={() => void toggleArchive()}
      />
      <div
        class="room-scroll"
        ref={scroll}
        onScroll={(event: JSX.TargetedEvent<HTMLDivElement>) => {
          const node = event.currentTarget;
          const bottom = node.scrollHeight - node.scrollTop - node.clientHeight <= NEAR_BOTTOM;
          setAtBottom(bottom);
          if (bottom) setHasNew(false);
        }}
      >
        {vm.loading ? (
          <div class="room-state">{t("remote.room.loading")}</div>
        ) : (
          <MessageList
            sessionId={vm.room.id}
            session={vm.session}
            main={vm.main}
            actions={actions}
            send={send}
            onEdit={(next) => {
              setEdit(next);
              onDraft(next.text);
            }}
            onRestore={(item) => {
              const next = draftRestoringQueuedInputs(draft, [item]);
              if (next !== null) onDraft(next);
            }}
            now={now}
          />
        )}
      </div>
      <div class="room-foot">
        {hasNew ? (
          <button class="new-messages" type="button" onClick={toBottom}>
            <ArrowDown />
            <span>{t("remote.room.newMessages")}</span>
          </button>
        ) : null}
        {failure ? <div class="composer-note is-error" role="alert">{failure}</div> : null}
        {isMain ? null : <BackgroundWorkFooter session={vm.session} now={now} />}
        {questionOffscreen && waiting ? (
          <div class="q-pin">
            <QuestionCircle class="q-head-icon" />
            <span class="q-pin-text">
              <span class="q-pin-status">{t("hud.question.needed")}</span>
              <span class="q-pin-title">{questionTitle(waiting)}</span>
            </span>
            <button class="q-btn is-primary" type="button" onClick={openQuestion}>
              {t("remote.room.question.answer")}
            </button>
          </div>
        ) : null}
        <Composer
          sessionId={vm.room.id}
          isMain={isMain}
          session={vm.session}
          mainBusy={vm.main?.busy === true}
          macConnected={vm.macConnected}
          online={vm.online}
          dictationAvailability={vm.dictation}
          draft={draft}
          onDraft={onDraft}
          edit={edit}
          onCancelEdit={() => setEdit(null)}
          actions={actions}
          send={send}
          now={now}
        />
      </div>
      {workOpen ? (
        <WorkPanel sessionId={vm.room.id} session={vm.session} actions={actions} onDismiss={() => setWorkOpen(false)} />
      ) : null}
    </div>
  );
}

function questionElement(scroll: HTMLDivElement | null, questionId: string | undefined): HTMLElement | null {
  if (!scroll || !questionId) return null;
  const bubbles = scroll.querySelectorAll<HTMLElement>("[data-question-id]");
  for (const bubble of Array.from(bubbles)) {
    if (bubble.dataset.questionId === questionId) return bubble;
  }
  return null;
}

function questionTitle(request: PickyExtensionUiRequest): string {
  const first = request.questions?.[0];
  return request.title ?? request.prompt ?? first?.prompt ?? first?.label ?? "";
}

/**
 * Whether the waiting question's bubble is out of the transcript's view. The
 * signature re-runs the lookup after the transcript redraws, so the bar also
 * appears for a question that arrives while the user is reading older messages.
 */
function useOffscreenQuestion(questionId: string | undefined, scroll: RefObject<HTMLDivElement | null>, signature: string): boolean {
  const [offscreen, setOffscreen] = useState(false);
  useEffect(() => {
    const root = scroll.current;
    const target = questionElement(root, questionId);
    if (!root || !target || typeof IntersectionObserver === "undefined") {
      setOffscreen(false);
      return;
    }
    const observer = new IntersectionObserver(
      (entries) => {
        const entry = entries[entries.length - 1];
        if (entry) setOffscreen(!entry.isIntersecting);
      },
      // A question peeking over the bottom edge is not answerable yet, so the
      // last 64px of the transcript do not count as "in view".
      { root, threshold: 0, rootMargin: "0px 0px -64px 0px" },
    );
    observer.observe(target);
    return () => observer.disconnect();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [questionId, signature]);
  return questionId === undefined ? false : offscreen;
}

/** Wall clock for elapsed times; it only ticks while something is actually live. */
function useNow(active: boolean): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!active) return;
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [active]);
  return now;
}

function isLive(status: string): boolean {
  return status === "running" || status === "queued";
}

/**
 * Changes that should pull the view to the newest row. The revision covers every
 * projected mutation; the main room has no revision, so its transcript length
 * and activity stand in.
 */
function conversationSignature(vm: RoomViewProps["vm"]): string {
  if (vm.main) return `main:${vm.main.messages.length}:${vm.main.busy}:${vm.main.pendingQuestion?.id ?? ""}`;
  return `session:${vm.session?.revision ?? 0}:${(vm.session?.messages ?? []).length}`;
}
