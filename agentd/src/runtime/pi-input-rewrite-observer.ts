import { AsyncLocalStorage } from "node:async_hooks";
import type { InlineExtension, InputEvent } from "@earendil-works/pi-coding-agent";

/**
 * Observes the final text after discovered Pi input extensions have transformed
 * a Picky RPC prompt. AsyncLocalStorage scopes the observation to the specific
 * session.prompt() call, so unrelated extension-originated input cannot claim a
 * pending Picky delivery.
 */
export class PiInputRewriteObserver {
  private readonly deliveryContext = new AsyncLocalStorage<string>();

  constructor(private readonly onAlias: (deliveryID: string, finalText: string) => void) {}

  readonly inlineExtension: InlineExtension = {
    name: "picky-input-rewrite-observer",
    hidden: true,
    factory: (pi) => {
      pi.on("input", (event: InputEvent) => {
        const deliveryID = this.deliveryContext.getStore();
        if (deliveryID && event.source === "rpc") this.onAlias(deliveryID, event.text);
        return { action: "continue" };
      });
    },
  };

  runWithDelivery<T>(deliveryID: string, operation: () => T): T {
    return this.deliveryContext.run(deliveryID, operation);
  }
}

export interface MatchableInputDelivery {
  text: string;
  aliases?: ReadonlySet<string>;
}

export function expectedInputDeliveryIndex(
  deliveries: readonly MatchableInputDelivery[],
  incomingText: string,
  reverseKnownExpansion: (text: string) => string,
): number {
  const exactIndex = deliveries.findIndex((delivery) => delivery.text === incomingText);
  if (exactIndex >= 0) return exactIndex;

  const normalizedIncoming = incomingText.trim();
  const aliasIndex = deliveries.findIndex((delivery) => delivery.aliases?.has(normalizedIncoming) === true);
  if (aliasIndex >= 0) return aliasIndex;

  const reversed = reverseKnownExpansion(incomingText).trim();
  if (reversed === normalizedIncoming) return -1;
  return deliveries.findIndex((delivery) => delivery.text.trim() === reversed);
}
