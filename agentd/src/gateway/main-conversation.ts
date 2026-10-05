/**
 * Main agent ("Picky" room) state, folded from the primary daemon's main
 * events (docs/remote-pwa-implementation.md 2.5).
 *
 * The daemon has no per-message id for the main transcript, so the gateway
 * derives one from the timestamp and the index. It is stable for the life of a
 * gateway process, which is all the PWA needs: the list is replaced wholesale
 * whenever the daemon re-sends a snapshot.
 */
import type { PickyExtensionUiRequest, PickyMainActivity, PickyMainAgentMessage } from "../protocol.js";
import type { RemoteMainMessage, RemoteMainState } from "../remote/protocol.js";

export function remoteMainMessages(messages: readonly PickyMainAgentMessage[]): RemoteMainMessage[] {
  return messages.map((message, index) => ({
    id: `${message.createdAt}#${index}`,
    role: message.role,
    text: message.text,
    createdAt: message.createdAt,
  }));
}

export interface MainConversationListener {
  onMessage: (message: RemoteMainMessage) => void;
  onActivity: (activity: PickyMainActivity | undefined, busy: boolean) => void;
  onQuestion: (request: PickyExtensionUiRequest | undefined) => void;
  onStateReplaced: (state: RemoteMainState) => void;
}

export class MainConversation {
  private messages: RemoteMainMessage[] = [];
  private activity?: PickyMainActivity;
  private pendingQuestion?: PickyExtensionUiRequest;
  private turnInFlight = false;

  constructor(private readonly listener: MainConversationListener) {}

  state(): RemoteMainState {
    return {
      messages: this.messages,
      ...(this.activity ? { activity: this.activity } : {}),
      ...(this.pendingQuestion ? { pendingQuestion: this.pendingQuestion } : {}),
      busy: this.busy,
    };
  }

  get busy(): boolean {
    return this.turnInFlight || this.activity !== undefined;
  }

  get hasPendingQuestion(): boolean {
    return this.pendingQuestion !== undefined;
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

  replaceMessages(messages: readonly PickyMainAgentMessage[]): void {
    this.messages = remoteMainMessages(messages);
    this.listener.onStateReplaced(this.state());
  }

  /** The gateway marks the turn busy at submit time; the daemon settles it. */
  markTurnStarted(): void {
    this.turnInFlight = true;
    this.listener.onActivity(this.activity, this.busy);
  }

  reset(): void {
    this.messages = [];
    this.activity = undefined;
    this.pendingQuestion = undefined;
    this.turnInFlight = false;
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
      default:
        return false;
    }
  }
}
