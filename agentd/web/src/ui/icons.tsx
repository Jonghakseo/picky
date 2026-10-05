/**
 * Icons. The Pickle glyph and the status marks are traced from the Swift shapes
 * the HUD uses (`PickleLogoGlyph` in PickyConversationHeaderView.swift:825,
 * dock status fills in PickyHUDDockIconView.swift), so the phone shows the same
 * identity. The rest are SF Symbols equivalents drawn as paths, because the app
 * may not load anything from outside its own origin.
 */
import type { JSX } from "preact";
import type { RemoteRoomStatus } from "../../../src/remote/protocol";

/** One hidden sprite per page; rows reference the symbols with `<use>`. */
export function IconSprite(): JSX.Element {
  return (
    <svg width={0} height={0} aria-hidden="true" focusable="false" style="position:absolute">
      <symbol id="pickle-glyph" viewBox="0 0 512 512">
        <path
          fill="currentColor"
          fill-rule="evenodd"
          d="M481 195.71L435.32 152.47L420.72 91.29L359.54 76.69L316.3 31.01L256.01 48.95L195.72 31.01L152.48 76.69L91.3 91.29L76.7 152.47L31.02 195.71L48.96 256L31.02 316.29L76.7 359.53L91.3 420.71L152.48 435.31L195.72 480.99L256.01 463.05L316.3 480.99L359.54 435.31L420.72 420.71L435.32 359.53L481 316.29L463.06 256L481 195.71Z M179.1 291.39C158.16 291.39 141.19 270.17 141.19 244C141.19 217.83 158.16 196.61 179.1 196.61C200.04 196.61 217.01 217.83 217.01 244C217.01 270.17 200.04 291.39 179.1 291.39Z M332.9 291.39C311.96 291.39 294.99 270.17 294.99 244C294.99 217.83 311.96 196.61 332.9 196.61C353.84 196.61 370.81 217.83 370.81 244C370.81 270.17 353.84 291.39 332.9 291.39Z"
        />
      </symbol>
      <symbol id="st-running" viewBox="0 0 16 16">
        <circle cx="8" cy="8" r="4" fill="currentColor" />
      </symbol>
      <symbol id="st-waiting" viewBox="0 0 16 16">
        <circle cx="8" cy="8" r="7" fill="currentColor" />
        <path d="M8 4v5" stroke="var(--ds-color-surface1)" stroke-width="2" stroke-linecap="round" />
        <circle cx="8" cy="11.6" r="1.1" fill="var(--ds-color-surface1)" />
      </symbol>
      <symbol id="st-completed" viewBox="0 0 16 16">
        <circle cx="8" cy="8" r="7" fill="currentColor" />
        <path d="M4.8 8.3l2.2 2.2 4.2-4.6" fill="none" stroke="var(--ds-color-surface1)" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" />
      </symbol>
      <symbol id="st-failed" viewBox="0 0 16 16">
        <circle cx="8" cy="8" r="7" fill="currentColor" />
        <path d="M5.6 5.6l4.8 4.8M10.4 5.6l-4.8 4.8" fill="none" stroke="var(--ds-color-surface1)" stroke-width="1.8" stroke-linecap="round" />
      </symbol>
      <symbol id="st-cancelled" viewBox="0 0 16 16">
        <circle cx="8" cy="8" r="7" fill="currentColor" />
        <path d="M5.2 8h5.6" fill="none" stroke="var(--ds-color-surface1)" stroke-width="1.8" stroke-linecap="round" />
      </symbol>
      <symbol id="st-queued" viewBox="0 0 16 16">
        <circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" stroke-width="1.6" />
        <path d="M8 4.6V8l2.2 1.6" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" />
      </symbol>
    </svg>
  );
}

const STATUS_SYMBOL: Record<RemoteRoomStatus, string> = {
  running: "st-running",
  waiting_for_input: "st-waiting",
  blocked: "st-waiting",
  completed: "st-completed",
  failed: "st-failed",
  cancelled: "st-cancelled",
  queued: "st-queued",
  idle: "st-queued",
};

/** `hud.conversation.status.*` for every session status; `idle` is phone-only. */
const STATUS_LABEL_KEY: Record<RemoteRoomStatus, string> = {
  running: "hud.conversation.status.running",
  waiting_for_input: "hud.conversation.status.waiting",
  blocked: "hud.conversation.status.blocked",
  completed: "hud.conversation.status.completed",
  failed: "hud.conversation.status.failed",
  cancelled: "hud.conversation.status.cancelled",
  queued: "hud.conversation.status.queued",
  idle: "remote.room.status.idle",
};

/** Tone classes mirror PickyConversationStatusTone (see room-list.css). */
const STATUS_CLASS: Record<RemoteRoomStatus, string> = {
  running: "is-running",
  waiting_for_input: "is-waiting",
  blocked: "is-blocked",
  completed: "is-completed",
  failed: "is-failed",
  cancelled: "is-cancelled",
  queued: "is-queued",
  idle: "is-idle",
};

export function statusSymbol(status: RemoteRoomStatus): string {
  return STATUS_SYMBOL[status] ?? "st-queued";
}

export function statusLabelKey(status: RemoteRoomStatus): string {
  return STATUS_LABEL_KEY[status] ?? "hud.conversation.status.queued";
}

export function statusClass(status: RemoteRoomStatus): string {
  return STATUS_CLASS[status] ?? "is-queued";
}

export function StatusGlyph({ status, size = 10 }: { status: RemoteRoomStatus; size?: number }): JSX.Element {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" aria-hidden="true">
      <use href={`#${statusSymbol(status)}`} />
    </svg>
  );
}

export function PickleGlyph({ class: className }: { class?: string }): JSX.Element {
  return (
    <svg class={className} viewBox="0 0 512 512" aria-hidden="true">
      <use href="#pickle-glyph" />
    </svg>
  );
}

type IconProps = { size?: number; class?: string };

function stroke(path: JSX.Element, { size = 16, class: className }: IconProps, width = 1.6): JSX.Element {
  return (
    <svg
      class={className}
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      stroke-width={width}
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      {path}
    </svg>
  );
}

export const PlusIcon = (props: IconProps): JSX.Element => stroke(<path d="M8 3v10M3 8h10" />, props, 1.8);
export const ChevronRightIcon = (props: IconProps): JSX.Element => stroke(<path d="M6 3.5L10.5 8 6 12.5" />, props);
export const ChevronLeftIcon = (props: IconProps): JSX.Element => stroke(<path d="M10 3.5L5.5 8 10 12.5" />, props, 1.8);
/** SF Symbols `gearshape`: an eight-tooth gear with a hole. A circle with rays read as a theme (sun) toggle. */
export const GearIcon = (props: IconProps): JSX.Element =>
  stroke(
    <g>
      <path d="M6.72 2.86L6.98 1.18L9.02 1.18L9.28 2.86L10.73 3.46L12.10 2.45L13.55 3.90L12.54 5.27L13.14 6.72L14.82 6.98L14.82 9.02L13.14 9.28L12.54 10.73L13.55 12.10L12.10 13.55L10.73 12.54L9.28 13.14L9.02 14.82L6.98 14.82L6.72 13.14L5.27 12.54L3.90 13.55L2.45 12.10L3.46 10.73L2.86 9.28L1.18 9.02L1.18 6.98L2.86 6.72L3.46 5.27L2.45 3.90L3.90 2.45L5.27 3.46Z" />
      <circle cx="8" cy="8" r="2.1" />
    </g>,
    props,
    1.3,
  );
export const ArchiveIcon = (props: IconProps): JSX.Element =>
  stroke(
    <g>
      <path d="M1.8 4.6h12.4v8.1a1 1 0 0 1-1 1H2.8a1 1 0 0 1-1-1z" />
      <path d="M1.2 2.3h13.6v2.3H1.2z" />
      <path d="M6.4 7.6h3.2" />
    </g>,
    props,
    1.4,
  );
export const FolderIcon = (props: IconProps): JSX.Element =>
  stroke(<path d="M1.8 4.2a1 1 0 0 1 1-1h3l1.4 1.6h6a1 1 0 0 1 1 1v6.2a1 1 0 0 1-1 1H2.8a1 1 0 0 1-1-1z" />, props, 1.4);
export const CameraIcon = (props: IconProps): JSX.Element =>
  stroke(
    <g>
      <path d="M1.8 5.4a1 1 0 0 1 1-1h2l1-1.6h4.4l1 1.6h2a1 1 0 0 1 1 1v6.4a1 1 0 0 1-1 1H2.8a1 1 0 0 1-1-1z" />
      <circle cx="8" cy="8.4" r="2.6" />
    </g>,
    props,
    1.4,
  );
export const ShareIcon = (props: IconProps): JSX.Element =>
  stroke(
    <g>
      <path d="M8 10.4V2.2" />
      <path d="M5.4 4.6L8 2l2.6 2.6" />
      <path d="M4.2 7.2H3a1 1 0 0 0-1 1v5a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1v-5a1 1 0 0 0-1-1h-1.2" />
    </g>,
    props,
    1.4,
  );
export const BellIcon = (props: IconProps): JSX.Element =>
  stroke(
    <g>
      <path d="M4.2 7a3.8 3.8 0 0 1 7.6 0c0 3 1.2 4 1.2 4H3s1.2-1 1.2-4z" />
      <path d="M6.6 13.2a1.6 1.6 0 0 0 2.8 0" />
    </g>,
    props,
    1.4,
  );
export const MacOfflineIcon = (props: IconProps): JSX.Element =>
  stroke(
    <g>
      <path d="M2 3.4h12v7H2z" />
      <path d="M5 13h6" />
      <path d="M2.6 2l10.8 12" />
    </g>,
    props,
    1.4,
  );
export const DocumentIcon = (props: IconProps): JSX.Element =>
  stroke(
    <g>
      <path d="M4 1.8h5l3 3v9.4H4z" />
      <path d="M9 1.8v3h3" />
    </g>,
    props,
    1.4,
  );

export function Spinner(): JSX.Element {
  return <span class="spinner" aria-hidden="true" />;
}
