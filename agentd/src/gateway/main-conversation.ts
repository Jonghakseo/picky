/**
 * Main agent ("Picky" room) state, folded from the primary daemon's main
 * events (docs/remote-pwa-implementation.md 2.5).
 *
 * The daemon has no per-message id for the main transcript, so the gateway
 * derives one from the timestamp and the index. It is stable for the life of a
 * gateway process, which is all the PWA needs: the list is replaced wholesale
 * whenever the daemon re-sends a snapshot.
 */
import type { MainDelegationDecision, MainTask } from "../features/main-tasks/schema.js";
import type { PickyExtensionUiRequest, PickyMainActivity, PickyMainAgentMessage } from "../protocol.js";
import type { RemoteMainMessage, RemoteMainState } from "../remote/protocol.js";
import { activeMainTaskCount, hasPendingMainDecision, remoteMainTasksView, type RemoteMainTasksView } from "./main-tasks.js";

export function remoteMainMessages(messages: readonly PickyMainAgentMessage[]): RemoteMainMessage[] {
  return messages.map((message, index) => ({
    id: `${message.createdAt}#${index}`,
    role: message.role,
    text: message.text,
    createdAt: message.createdAt,
  }));
}

/**
 * Whether a daemon `quickReply` ends a main agent turn. The daemon sends
 * `mainTurnSettled` only for turns without a reply; a turn that answers ends
 * with `quickReply` instead (main-agent-coordinator), which is also how the Mac
 * clears its waiting state. A Pickle's own spoken reply uses the same event
 * with `replyKind: "main"` and its `sessionId`; that one says nothing about
 * the main conversation.
 */
export function quickReplyEndsMainTurn(event: { readonly [key: string]: unknown }): boolean {
  return !(event.replyKind === "main" && typeof event.sessionId === "string" && event.sessionId.length > 0);
}

export interface MainConversationListener {
  onMessage: (message: RemoteMainMessage) => void;
  onActivity: (activity: PickyMainActivity | undefined, busy: boolean) => void;
  onQuestion: (request: PickyExtensionUiRequest | undefined) => void;
  onStateReplaced: (state: RemoteMainState) => void;
  /** Tasks or delegation decisions changed; the room list count changes with them. */
  onTasks: (view: RemoteMainTasksView) => void;
}

/** Images kept for the Picky room; older ones drop off like the HUD's 100-message transcript. */
export const MAIN_IMAGE_RETENTION = 50;

/**
 * The daemon transcript and the gateway's image rows in time order. Ties keep
 * the image after the text, which is the order they happened in a turn.
 */
export function mergeMainTranscript(texts: readonly RemoteMainMessage[], images: readonly RemoteMainMessage[]): RemoteMainMessage[] {
  if (images.length === 0) return [...texts];
  const merged: RemoteMainMessage[] = [];
  let next = 0;
  for (const text of texts) {
    while (next < images.length && images[next].createdAt < text.createdAt) merged.push(images[next++]);
    merged.push(text);
  }
  while (next < images.length) merged.push(images[next++]);
  return merged;
}

export class MainConversation {
  private messages: RemoteMainMessage[] = [];
  private images: RemoteMainMessage[] = [];
  private activity?: PickyMainActivity;
  private pendingQuestion?: PickyExtensionUiRequest;
  private turnInFlight = false;
  private tasks: MainTask[] = [];
  private decisions: MainDelegationDecision[] = [];
  private tasksView: RemoteMainTasksView = { tasks: [], decisions: [] };

  constructor(private readonly listener: MainConversationListener) {}

  state(): RemoteMainState {
    return {
      messages: mergeMainTranscript(this.messages, this.images),
      ...(this.activity ? { activity: this.activity } : {}),
      ...(this.pendingQuestion ? { pendingQuestion: this.pendingQuestion } : {}),
      busy: this.busy,
      tasks: this.tasksView.tasks,
      decisions: this.tasksView.decisions,
    };
  }

  get busy(): boolean {
    return this.turnInFlight || this.activity !== undefined;
  }

  get hasPendingQuestion(): boolean {
    return this.pendingQuestion !== undefined;
  }

  /** Counted from the full snapshot, not the trimmed view the phone receives. */
  get activeTaskCount(): number {
    return activeMainTaskCount(this.tasks);
  }

  get hasPendingDecision(): boolean {
    return hasPendingMainDecision(this.decisions);
  }

  lastAssistantText(): string | undefined {
    for (let index = this.messages.length - 1; index >= 0; index -= 1) {
      if (this.messages[index].role === "assistant") return this.messages[index].text;
    }
    return undefined;
  }

  lastUpdatedAt(): string | undefined {
    return this.messages.at(-1)?.createdAt;
  }

  /**
   * What the Picky room mentions, for the file API: link targets in the
   * replies and the images it read. Same rule as a Pickle room: the phone opens
   * a file only because the conversation already points at it.
   */
  fileReferences(): { messages: Array<{ text: string }>; artifacts: Array<{ path: string }> } {
    return {
      messages: this.messages.map((message) => ({ text: message.text })),
      artifacts: this.images.flatMap((message) => (message.image ? [{ path: message.image.path }] : [])),
    };
  }

  replaceMessages(messages: readonly PickyMainAgentMessage[]): void {
    this.messages = remoteMainMessages(messages);
    this.listener.onStateReplaced(this.state());
  }

  /** The gateway marks the turn busy at submit time; the daemon settles it. */
  markTurnStarted(): void {
    this.turnInFlight = true;
    this.listener.onActivity(this.activity, this.busy);
  }

  /**
   * The turn is over without a daemon event saying so: the user aborted it
   * (agentd's abort has no settle event) or the submit itself failed.
   */
  markTurnSettled(): void {
    if (!this.turnInFlight && this.activity === undefined) return;
    this.turnInFlight = false;
    this.activity = undefined;
    this.listener.onActivity(undefined, this.busy);
  }

  reset(): void {
    this.messages = [];
    this.images = [];
    this.activity = undefined;
    this.pendingQuestion = undefined;
    this.turnInFlight = false;
    this.tasks = [];
    this.decisions = [];
    this.tasksView = { tasks: [], decisions: [] };
    this.listener.onStateReplaced(this.state());
  }

  handleEvent(event: { type: string; [key: string]: unknown }): boolean {
    switch (event.type) {
      case "mainMessagesSnapshot":
        this.replaceMessages((event.messages ?? []) as PickyMainAgentMessage[]);
        return true;
      case "mainMessageAppended": {
        const message = event.message as PickyMainAgentMessage | undefined;
        if (!message) return true;
        const remote: RemoteMainMessage = {
          id: `${message.createdAt}#${this.messages.length}`,
          role: message.role,
          text: message.text,
          createdAt: message.createdAt,
        };
        this.messages = [...this.messages, remote];
        this.listener.onMessage(remote);
        return true;
      }
      case "mainActivityUpdated":
        this.activity = event.activity as PickyMainActivity | undefined;
        this.recordImage(this.activity);
        this.listener.onActivity(this.activity, this.busy);
        return true;
      case "mainExtensionUiRequested":
        this.pendingQuestion = event.request as PickyExtensionUiRequest;
        this.listener.onQuestion(this.pendingQuestion);
        return true;
      case "mainExtensionUiCancelled":
        if (this.pendingQuestion?.id !== event.requestId) return true;
        this.pendingQuestion = undefined;
        this.listener.onQuestion(undefined);
        return true;
      case "mainTurnSettled":
        this.turnInFlight = false;
        this.activity = undefined;
        this.listener.onActivity(undefined, this.busy);
        return true;
      case "mainTasksUpdated":
        // The daemon re-sends the whole set on every change, including right
        // after the gateway connects, so replacing is the fold.
        this.tasks = Array.isArray(event.tasks) ? (event.tasks as MainTask[]) : [];
        this.decisions = Array.isArray(event.decisions) ? (event.decisions as MainDelegationDecision[]) : [];
        this.tasksView = remoteMainTasksView(this.tasks, this.decisions);
        this.listener.onTasks(this.tasksView);
        return true;
      case "quickReply":
        if (quickReplyEndsMainTurn(event)) this.markTurnSettled();
        return true;
      default:
        return false;
    }
  }

  /** A finished `read` that returned an image becomes a row, as `toolImage` does in a Pickle. */
  private recordImage(activity: PickyMainActivity | undefined): void {
    if (activity?.kind !== "tool" || activity.status !== "succeeded" || !activity.imagePath) return;
    const id = `image:${activity.toolCallId ?? activity.imagePath}`;
    if (this.images.some((held) => held.id === id)) return;
    const message: RemoteMainMessage = {
      id,
      role: "assistant",
      text: "",
      createdAt: new Date().toISOString(),
      image: {
        path: activity.imagePath,
        toolName: activity.toolName ?? "read",
        ...(activity.imageMimeType ? { mimeType: activity.imageMimeType } : {}),
      },
    };
    this.images = [...this.images, message].slice(-MAIN_IMAGE_RETENTION);
    this.listener.onMessage(message);
  }
}
