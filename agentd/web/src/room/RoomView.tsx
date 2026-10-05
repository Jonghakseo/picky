/**
 * The conversation room: the HUD's conversation card, on a phone screen.
 *
 * The shell (`src/screens/RoomScreen.tsx`) resolves `picky:room` to this file
 * and hands over a `RoomViewModel` plus `RoomActions`; everything below renders
 * from those two alone, so the gallery can drive the same view from fixtures.
 */
import type { JSX } from "preact";
import { useCallback, useEffect, useRef, useState } from "preact/hooks";

import type { RemoteCommand } from "../../../src/remote/protocol";
import { Composer } from "./composer/Composer";
import { draftRestoringQueuedInputs } from "./policy/composer";
import type { RoomViewProps } from "./contract";
import { Header } from "./Header";
import { ArrowDown } from "./icons";
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
  const now = useNow(isLive(vm.room.status) || vm.main?.busy === true);

  setLocale(vm.locale);

  const roomId = vm.room.id;
  useEffect(() => {
    setDraft(actions.loadDraft());
    setEdit(null);
    setFailure(null);
    setWorkOpen(false);
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
      setFailure(result.error.message || t("remote.room.composer.sendFailed"));
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

  const isMain = vm.room.kind === "main";
  return (
    <div class="room-view" ref={root}>
      <Header
        title={vm.room.title}
        status={vm.room.status}
        contextUsage={vm.session?.contextUsage ? { percent: vm.session.contextUsage.percent } : undefined}
        showArchive={!isMain}
        showWork={!isMain}
        showMenu={false}
        onBack={actions.back}
        onWork={() => setWorkOpen(true)}
        onArchive={() => void send({ type: "session.archive", sessionId: vm.room.id, archived: !vm.room.archived })}
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
        {failure ? <div class="composer-note is-error">{failure}</div> : null}
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
