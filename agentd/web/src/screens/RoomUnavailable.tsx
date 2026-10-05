/**
 * Stand-in for `src/room/RoomView.tsx` (the conversation UI) while that file
 * does not exist. `web/build.mjs` resolves `picky:room` to the real view as
 * soon as it lands, so the shell never ships this in a complete build.
 */
import type { JSX } from "preact";
import type { RoomViewProps } from "../room/contract";
import { t } from "../app/i18n";
import { ChevronLeftIcon } from "../ui/icons";

export function RoomView({ vm, actions }: RoomViewProps): JSX.Element {
  return (
    <div class="app-shell">
      <div class="app-topbar bordered app-side-inset">
        <button class="icon-button" type="button" aria-label={t("remote.room.back")} onClick={() => actions.back()}>
          <ChevronLeftIcon size={17} />
        </button>
        <h1 class="app-topbar-title">{vm.room.title}</h1>
      </div>
      <div class="app-scroll app-side-inset">
        <div class="app-empty">
          <span class="app-empty-title">{t("remote.room.unavailable")}</span>
        </div>
      </div>
    </div>
  );
}
