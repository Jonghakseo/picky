/**
 * Runtime error bubble.
 * Source: Picky/HUD/Conversation/Bubbles/PickyErrorBubbleView.swift.
 *
 * The chip resends the request Pi never accepted (a runtime race), or steers a
 * short continuation prompt when the failure was reported for a request that
 * did arrive.
 */
import type { JSX } from "preact";

import type { PickySessionMessage } from "../../../../src/protocol";
import { Refresh, Warning } from "../icons";
import { t } from "../i18n";
import type { ErrorRecovery } from "../policy/message";
import { errorRecoveryLabelKey } from "../policy/message";

export interface ErrorBubbleProps {
  message: PickySessionMessage;
  /** `null` hides the chip: nothing is left to retry. */
  recovery: ErrorRecovery | null;
  onRecover: (recovery: ErrorRecovery) => void;
}

export function ErrorBubble({ message, recovery, onRecover }: ErrorBubbleProps): JSX.Element {
  const title = errorTitle(message.text);
  return (
    <div class="e-bubble">
      <div class="e-header">
        <Warning />
        <span>{t("hud.error.header")}</span>
      </div>
      {title ? <div class="e-title">{title}</div> : null}
      {message.errorMessage ? <div class="e-message">{message.errorMessage}</div> : null}
      {message.errorContext ? <div class="e-context">{message.errorContext}</div> : null}
      {recovery ? (
        <button class="e-chip" type="button" onClick={() => onRecover(recovery)}>
          <Refresh />
          <span>{t(errorRecoveryLabelKey(recovery))}</span>
        </button>
      ) : null}
    </div>
  );
}

/** "Runtime error" is the header's own wording; repeating it as a title says nothing. */
export function errorTitle(text: string | undefined): string | null {
  const trimmed = text?.trim() ?? "";
  if (trimmed.length === 0) return null;
  if (trimmed.toLowerCase() === "runtime error") return null;
  return trimmed;
}
