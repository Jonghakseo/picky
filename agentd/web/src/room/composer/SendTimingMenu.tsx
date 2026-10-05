/**
 * "보낼 시점" menu behind the split send button.
 * Source: PickySendTimingMenuView / PickySendTimingPolicy. On the phone it sits
 * above the composer, where the Mac popover opens with `arrowEdge .top`.
 */
import { useEffect, useState } from "preact/hooks";
import type { JSX } from "preact";

import { ChevronRight } from "../icons";
import { useDialog } from "../../ui/use-dialog";
import { t } from "../i18n";
import type { SendTiming, SendTimingOption } from "../policy/schedule";
import { delayMilliseconds, isWithinScheduleLimit } from "../policy/schedule";

export interface SendTimingMenuProps {
  options: SendTimingOption[];
  onAfterCurrentReply: () => void;
  onSchedule: (delayMs: number) => void;
  onDismiss: () => void;
}

export function SendTimingMenu(props: SendTimingMenuProps): JSX.Element {
  const [custom, setCustom] = useState<string | null>(null);
  // Focus, Tab, Esc and focus return; Esc on the custom time goes back to the list.
  const menu = useDialog<HTMLDivElement>({ onDismiss: () => (custom === null ? props.onDismiss() : setCustom(null)) });
  useEffect(() => {
    if (custom === null) return;
    menu.current?.querySelector<HTMLElement>("input")?.focus({ preventScroll: true });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [custom === null]);

  function onKeyDown(event: KeyboardEvent): void {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    const rows = [...(menu.current?.querySelectorAll<HTMLElement>("button:not(:disabled)") ?? [])];
    if (rows.length === 0) return;
    event.preventDefault();
    const at = rows.indexOf(document.activeElement as HTMLElement);
    const step = event.key === "ArrowDown" ? 1 : -1;
    rows[(at + step + rows.length) % rows.length]?.focus();
  }
  // The Mac shows why an option is off as hover help; a phone has no hover,
  // so the reason is written under the title instead.
  const disabledReason = props.options.find((option) => !option.enabled && option.disabledReason)?.disabledReason;

  function pick(timing: SendTiming): void {
    if (timing.kind === "afterCurrentReply") {
      props.onAfterCurrentReply();
      return;
    }
    if (timing.kind === "custom") {
      setCustom(defaultCustomValue());
      return;
    }
    const delayMs = delayMilliseconds(timing, Date.now());
    if (delayMs !== null && isWithinScheduleLimit(delayMs)) props.onSchedule(delayMs);
  }

  return (
    <div class="sheet-backdrop" onClick={props.onDismiss}>
      <div class="sheet-anchor is-trailing" ref={menu} onKeyDown={onKeyDown} onClick={(event: MouseEvent) => event.stopPropagation()}>
        {custom === null ? (
          <div class="send-timing-menu" role="menu" aria-labelledby="send-timing-title">
            <div class="send-timing-title" id="send-timing-title">{t("hud.composer.sendTiming.title")}</div>
            {disabledReason ? <div class="send-timing-note">{disabledReason}</div> : null}
            {props.options.map((option, index) => (
              <>
                {index === 1 || option.timing.kind === "custom" ? (
                  <div class="send-timing-divider" role="separator" />
                ) : null}
                <button
                  key={option.id}
                  class="send-timing-row"
                  type="button"
                  role="menuitem"
                  disabled={!option.enabled}
                  title={option.disabledReason}
                  onClick={() => pick(option.timing)}
                >
                  <span class="send-timing-row-title">{option.title}</span>
                  {option.detail ? <span class="send-timing-row-detail">{option.detail}</span> : null}
                  {option.timing.kind === "custom" ? (
                    <span class="send-timing-row-chevron">
                      <ChevronRight />
                    </span>
                  ) : null}
                </button>
              </>
            ))}
          </div>
        ) : (
          <div class="send-timing-menu" role="dialog" aria-labelledby="send-timing-custom-title">
            <div class="send-timing-title" id="send-timing-custom-title">{t("remote.room.schedule.sheet.title")}</div>
            <div class="send-timing-row">
              <input
                class="q-field"
                type="datetime-local"
                aria-labelledby="send-timing-custom-title"
                value={custom}
                onInput={(event: JSX.TargetedEvent<HTMLInputElement>) => setCustom(event.currentTarget.value)}
              />
            </div>
            <button
              class="send-timing-row"
              type="button"
              onClick={() => {
                const at = Date.parse(custom);
                if (Number.isNaN(at)) return;
                const delayMs = delayMilliseconds({ kind: "at", at }, Date.now());
                if (delayMs !== null && isWithinScheduleLimit(delayMs)) props.onSchedule(delayMs);
              }}
            >
              <span class="send-timing-row-title">{t("remote.room.schedule.custom.send")}</span>
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

/** `datetime-local` wants a local `YYYY-MM-DDTHH:mm`, not an ISO instant. */
function defaultCustomValue(): string {
  const date = new Date(Date.now() + 60 * 60 * 1000);
  const pad = (value: number): string => String(value).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}
