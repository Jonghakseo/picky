import type { BuiltPrompt } from "../prompt-builder.js";
import type { RuntimeSessionHandle } from "../runtime/types.js";
import type { MainTaskCompletion } from "./main-task-service.js";

export interface MainTaskCompletionSource {
  nextCompletion(): MainTaskCompletion | undefined;
  markCompletionDelivered(completion: MainTaskCompletion): void;
}

export interface MainTaskCompletionDeliveryDeps {
  source: MainTaskCompletionSource;
  /** A user turn, an open question, a compaction, or a PTT pause owns the main agent right now. */
  isMainBusy(): boolean;
  prepareMainDelivery(prompt: BuiltPrompt): Promise<{ handle: RuntimeSessionHandle; sendAsFollowUp: boolean } | undefined>;
  /** Points the reply of the coming turn at the request the Task came from. */
  beginCompletionTurn(completion: MainTaskCompletion): void;
  /** Undoes `beginCompletionTurn` when the runtime refused the message. */
  abandonCompletionTurn(): void;
  log(message: string, fields: Record<string, string | number | boolean | undefined>): void;
}

/**
 * Hands finished Task results to the main agent one at a time, only while nothing else owns the
 * conversation, so a result never cuts into the user's turn, an open question, or speech. The
 * durable "delivered" mark is set once the runtime accepted the message: the result is then part of
 * the main transcript, and a later failure of that reply is not a reason to deliver it twice.
 */
export class MainTaskCompletionDelivery {
  private inFlight = false;

  constructor(private readonly deps: MainTaskCompletionDeliveryDeps) {}

  schedule(): void {
    queueMicrotask(() => {
      void this.drain().catch((error) => {
        this.deps.log("main task completion delivery failed", { error: error instanceof Error ? error.message : String(error) });
      });
    });
  }

  async drain(): Promise<void> {
    if (this.inFlight || this.deps.isMainBusy()) return;
    const completion = this.deps.source.nextCompletion();
    if (!completion) return;
    this.inFlight = true;
    try {
      const prompt: BuiltPrompt = { text: completion.prompt, imagePaths: [] };
      const delivery = await this.deps.prepareMainDelivery(prompt);
      if (!delivery) {
        this.deps.log("main task completion deferred", { taskId: completion.taskId, reason: "no main handle" });
        return;
      }
      // The handle may have taken a user turn while it was being prepared.
      if (this.deps.isMainBusy()) return;
      this.deps.beginCompletionTurn(completion);
      try {
        if (delivery.sendAsFollowUp) await delivery.handle.followUp(prompt);
      } catch (error) {
        this.deps.abandonCompletionTurn();
        throw error;
      }
      this.deps.source.markCompletionDelivered(completion);
      this.deps.log("main task completion delivered", { taskId: completion.taskId, revision: completion.revision, interruption: completion.interruption });
    } finally {
      this.inFlight = false;
    }
  }
}
