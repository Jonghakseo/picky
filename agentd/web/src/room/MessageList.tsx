/**
 * The transcript: one row per journal message, plus the live rows the HUD
 * draws under it (presence, queued input, scheduled messages).
 *
 * Source: Picky/HUD/Conversation/PickyConversationListView.swift. The row kinds
 * and their order come from `policy/message.ts`, so the phone never decides on
 * its own what a message looks like.
 */
import type { JSX } from "preact";

import type { PickyAgentSession, PickyQueueItem, PickySubagentRun } from "../../../src/protocol";
import type { RemoteCommand, RemoteMainState } from "../../../src/remote/protocol";
import {
  ActivitySummary,
  AgentBubble,
  DateDivider,
  PendingQueueRow,
  PresenceRow,
  ScheduledRow,
  SubagentRuns,
  ToolImageBubble,
  UserBubble,
} from "./bubbles/Bubbles";
import { ErrorBubble } from "./bubbles/ErrorBubble";
import { QuestionBubble } from "./bubbles/QuestionBubble";
import {
  CompactCompletionRow,
  CompactFailureBubble,
  ExtensionCustomMessageBubble,
  NotifyBubble,
} from "./bubbles/SystemBubbles";
import type { RoomActions } from "./contract";
import { crossesDay, dateDividerTitle, parseTimestamp, timeOfDay } from "./format";
import { locale, t } from "./i18n";
import { Markdown } from "./markdown/Markdown";
import { queueItemText } from "./policy/composer";
import type { ErrorRecovery } from "./policy/message";
import { CONTINUE_PROMPT_KEY, bubbleKind, errorRecovery, visibleActivityCounts } from "./policy/message";
import { derivePresence } from "./policy/presence";
import { resolveQuestionRequest } from "./policy/question";
import { absoluteDetail, relativeTitle } from "./policy/schedule";
import { extensionCustomMessagePresentation } from "./policy/system-message";

export type QueueEdit =
  | { kind: "queue"; itemId: string; text: string }
  | { kind: "scheduled"; scheduledId: string; text: string };

export interface MessageListProps {
  sessionId: string;
  session?: PickyAgentSession;
  main?: RemoteMainState;
  actions: RoomActions;
  /** `true` when the command was accepted; the caller shows the failure note. */
  send: (command: RemoteCommand) => Promise<boolean>;
  /** Pulls a queued or scheduled text back into the composer for editing. */
  onEdit: (edit: QueueEdit) => void;
  /** Puts a withdrawn steer's text back into the composer draft. */
  onRestore: (item: PickyQueueItem) => void;
  now: number;
}

export function MessageList(props: MessageListProps): JSX.Element {
  return props.main ? <MainRows {...props} main={props.main} /> : <SessionRows {...props} />;
}

function SessionRows({ sessionId, session, actions, send, onEdit, onRestore, now }: MessageListProps): JSX.Element {
  const session_ = session;
  if (!session_) return <div class="msgs" />;
  const language = locale();
  const messages = session_.messages ?? [];
  let previousDay: number | null = null;
  const rows: JSX.Element[] = [];

  for (const message of messages) {
    const at = parseTimestamp(message.createdAt);
    if (at !== null && crossesDay(previousDay, at)) {
      rows.push(<DateDivider key={`day-${message.id}`} title={dateDividerTitle(at, now, language)} />);
      previousDay = at;
    }
    const time = at === null ? null : timeOfDay(at, language);
    const kind = bubbleKind(message);
    const links = {
      onOpenExternal: (url: string) => actions.openExternal(url),
      onOpenFile: (path: string) => actions.openFile(path),
    };
    switch (kind) {
      case "hidden":
        break;
      case "userText":
        rows.push(<UserBubble key={message.id} text={message.text ?? ""} time={time} {...links} />);
        break;
      case "agentText":
        rows.push(<AgentBubble key={message.id} text={message.text ?? ""} time={time} {...links} />);
        break;
      case "question": {
        const copy = message.question;
        if (!copy) break;
        const { request, active } = resolveQuestionRequest(copy, session_.pendingExtensionUiRequest, message.cancelledAt);
        rows.push(
          <QuestionBubble
            key={message.id}
            request={request}
            active={active}
            onAnswer={(value) => send({ type: "session.answer", sessionId, requestId: request.id, value })}
          />,
        );
        break;
      }
      case "questionFallback":
        rows.push(<AgentBubble key={message.id} text={message.text ?? t("hud.question.empty")} time={time} {...links} />);
        break;
      case "error": {
        const recovery = errorRecovery(message, session_.lastRequest, t(CONTINUE_PROMPT_KEY));
        rows.push(
          <ErrorBubble
            key={message.id}
            message={message}
            recovery={recovery}
            onRecover={(choice: ErrorRecovery) => {
              void send({ type: "session.send", sessionId, text: choice.text, kind: "steer" });
            }}
          />,
        );
        break;
      }
      case "activitySummary": {
        const counts = visibleActivityCounts(message.activitySnapshot);
        const total = counts.reduce((sum, entry) => sum + entry.count, 0);
        rows.push(<ActivitySummary key={message.id} total={total} counts={counts} />);
        break;
      }
      case "subagentInvocation": {
        const runs = invocationRuns(message.subagentInvocation, session_.subagentRuns ?? []);
        if (runs.length > 0) rows.push(<SubagentRuns key={message.id} runs={runs} />);
        break;
      }
      case "toolImage": {
        const toolImage = message.toolImage;
        if (!toolImage) break;
        rows.push(
          <ToolImageBubble
            key={message.id}
            toolImage={toolImage}
            src={actions.fileUrl(toolImage.path)}
            onOpen={() => actions.openFile(toolImage.path)}
          />,
        );
        break;
      }
      case "compactCompletion":
        rows.push(<CompactCompletionRow key={message.id} message={message} />);
        break;
      case "compactFailure":
        rows.push(<CompactFailureBubble key={message.id} message={message} />);
        break;
      case "notify":
        rows.push(<NotifyBubble key={message.id} message={message} {...links} />);
        break;
      case "extensionCustomMessage": {
        const presentation = extensionCustomMessagePresentation(message);
        if (presentation) rows.push(<ExtensionCustomMessageBubble key={message.id} presentation={presentation} />);
        break;
      }
      case "systemText":
        // The HUD draws a plain system line through the agent bubble surface.
        // A date divider would not: its label is `white-space: nowrap`.
        if ((message.text ?? "").trim().length > 0) {
          rows.push(<AgentBubble key={message.id} text={message.text ?? ""} time={time} {...links} />);
        }
        break;
    }
  }

  // Steers and follow-ups offer what the HUD offers for each. A steer is already
  // taken at the next tool boundary, so it has no "send now" (the daemon's
  // send-now only promotes follow-ups); "edit" withdraws it and puts the text
  // back in the composer (PickyPendingSteerBubbleView). Follow-ups are edited in
  // place and can be sent now (PickyScheduledMessagesBarView).
  for (const item of session_.queuedSteers ?? []) {
    const text = queueItemText(item);
    const itemId = item.id;
    // Screen context cannot go back into the composer, so such a steer can only be cancelled.
    const restorable = (item.attachedImagesCount ?? 0) === 0;
    rows.push(
      <PendingQueueRow
        key={`queued-steer-${itemId ?? text}`}
        text={text}
        onEdit={
          itemId && restorable
            ? () => {
                // Removed first, so a steer the Pickle already took never comes back as a draft.
                void send({ type: "session.queue.remove", sessionId, itemId }).then((ok) => {
                  if (ok) onRestore(item);
                });
              }
            : undefined
        }
        onRemove={() => {
          if (itemId) void send({ type: "session.queue.remove", sessionId, itemId });
        }}
      />,
    );
  }
  for (const item of session_.queuedFollowUps ?? []) {
    const text = queueItemText(item);
    const itemId = item.id;
    rows.push(
      <PendingQueueRow
        key={`queued-followup-${itemId ?? text}`}
        text={text}
        onEdit={itemId ? () => onEdit({ kind: "queue", itemId, text }) : undefined}
        onRemove={() => {
          if (itemId) void send({ type: "session.queue.remove", sessionId, itemId });
        }}
        onSendNow={itemId ? () => void send({ type: "session.queue.sendNow", sessionId, itemId }) : undefined}
      />,
    );
  }

  for (const scheduled of session_.scheduledMessages ?? []) {
    const dueAt = parseTimestamp(scheduled.dueAt);
    const when =
      dueAt === null
        ? ""
        : `${relativeTitle(now, dueAt)} · ${absoluteDetail(dueAt, now, language)}`;
    rows.push(
      <ScheduledRow
        key={`scheduled-${scheduled.id}`}
        text={scheduled.text}
        when={when}
        onEdit={() => onEdit({ kind: "scheduled", scheduledId: scheduled.id, text: scheduled.text })}
        onCancel={() => void send({ type: "session.scheduled.cancel", sessionId, scheduledId: scheduled.id })}
        onSendNow={() => void send({ type: "session.scheduled.sendNow", sessionId, scheduledId: scheduled.id })}
      />,
    );
  }

  const presence = derivePresence(session_);
  if (presence) rows.push(<PresenceRow key="presence" presence={presence} now={now} />);

  return <div class="msgs">{rows}</div>;
}

/**
 * The main room has no journal projection: the gateway keeps a short transcript
 * and one activity line, which is what the HUD's main card shows too.
 */
function MainRows({ main, send, actions, now }: MessageListProps & { main: RemoteMainState }): JSX.Element {
  const language = locale();
  let previousDay: number | null = null;
  const rows: JSX.Element[] = [];
  for (const message of main.messages) {
    const at = parseTimestamp(message.createdAt);
    if (at !== null && crossesDay(previousDay, at)) {
      rows.push(<DateDivider key={`day-${message.id}`} title={dateDividerTitle(at, now, language)} />);
      previousDay = at;
    }
    const time = at === null ? null : timeOfDay(at, language);
    const image = message.image;
    if (image) {
      rows.push(
        <ToolImageBubble
          key={message.id}
          toolImage={{ toolName: image.toolName, path: image.path, ...(image.mimeType ? { mimeType: image.mimeType } : {}) }}
          src={actions.fileUrl(image.path)}
          onOpen={() => actions.openFile(image.path)}
        />,
      );
      continue;
    }
    rows.push(
      message.role === "user" ? (
        <UserBubble
          key={message.id}
          text={message.text}
          time={time}
          onOpenExternal={actions.openExternal}
          onOpenFile={actions.openFile}
        />
      ) : (
        <AgentBubble
          key={message.id}
          text={message.text}
          time={time}
          onOpenExternal={actions.openExternal}
          onOpenFile={actions.openFile}
        />
      ),
    );
  }

  const request = main.pendingQuestion;
  if (request) {
    rows.push(
      <QuestionBubble
        key={`question-${request.id}`}
        request={request}
        active
        onAnswer={(value) => send({ type: "main.answer", requestId: request.id, value })}
      />,
    );
  }

  const activityText = mainActivityText(main);
  if (activityText) {
    rows.push(
      <div class="main-activity" key="main-activity">
        <span class="presence-dots" aria-hidden="true">
          <i />
          <i />
          <i />
        </span>
        <span class="main-activity-text">{activityText}</span>
      </div>,
    );
  }

  return <div class="msgs">{rows}</div>;
}

/** One line for what the main agent is doing: a tool name, or its thinking preview. */
function mainActivityText(main: RemoteMainState): string | null {
  const activity = main.activity;
  if (!activity) return main.busy ? t("hud.presence.thinking") : null;
  if (activity.kind === "thinking") return activity.thinkingPreview?.trim() || t("hud.presence.thinking");
  const name = activity.toolName?.trim();
  return name && name.length > 0 ? name : t("hud.liveStep.working");
}

/**
 * Rows for a `subagent_invocation` message: the live run when the session still
 * carries it, otherwise the plan the message recorded, so an old invocation
 * still reads as "what was delegated".
 */
function invocationRuns(
  invocation: { planned: Array<{ agent: string; task: string }>; completed?: boolean } | undefined,
  runs: PickySubagentRun[],
): PickySubagentRun[] {
  if (!invocation) return [];
  return invocation.planned.map((planned, index) => {
    const live = runs.find((run) => run.agent === planned.agent && run.task === planned.task);
    if (live) return live;
    return {
      runId: -(index + 1),
      agent: planned.agent,
      task: planned.task,
      status: invocation.completed ? "done" : "running",
    } satisfies PickySubagentRun;
  });
}

/** Re-exported so the room view can render a bare markdown block (empty states). */
export { Markdown };
