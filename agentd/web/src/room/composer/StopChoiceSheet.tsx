/**
 * Stop choice sheet.
 * Source: PickyStopChoiceAlert.swift. The HUD asks through a native alert when
 * background tasks run; a web app cannot show one with custom buttons, so the
 * phone draws it. The options and the copy are the HUD's.
 */
import type { JSX } from "preact";

import { t } from "../i18n";
import type { AbortScope, StopChoice } from "../policy/stop";
import { stopAlertActions, stopAlertMessageKey } from "../policy/stop";

export interface StopChoiceSheetProps {
  choice: Exclude<StopChoice, "immediate">;
  onStop: (scope: AbortScope) => void;
  onDismiss: () => void;
}

export function StopChoiceSheet({ choice, onStop, onDismiss }: StopChoiceSheetProps): JSX.Element {
  return (
    <div class="sheet-backdrop is-centered" onClick={onDismiss}>
      <div class="stop-alert" role="alertdialog" onClick={(event: MouseEvent) => event.stopPropagation()}>
        <div class="stop-alert-body">
          <p class="stop-alert-title">{t("hud.stopChoice.title")}</p>
          <p class="stop-alert-message">{t(stopAlertMessageKey(choice))}</p>
        </div>
        {stopAlertActions(choice).map((action) => (
          <button
            key={action.titleKey}
            class={`stop-alert-action${action.role === "destructive" ? " is-destructive" : ""}${action.role === "cancel" ? " is-cancel" : ""}`}
            type="button"
            onClick={() => (action.scope ? onStop(action.scope) : onDismiss())}
          >
            <span>{t(action.titleKey)}</span>
          </button>
        ))}
      </div>
    </div>
  );
}
