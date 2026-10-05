/**
 * Icons traced from the SF Symbols the HUD uses, copied from the reviewed
 * prototypes so a capture of each screen matches. `data-sf-symbol` records the
 * symbol a glyph stands for, which is how the prototypes stayed reviewable.
 */
import type { JSX } from "preact";

interface IconProps {
  size?: number;
  class?: string;
}

function svgProps(symbol: string, size: number, className: string | undefined): JSX.SVGAttributes<SVGSVGElement> {
  return {
    width: size,
    height: size,
    "aria-hidden": "true",
    focusable: "false",
    // The SF Symbol each glyph traces, kept for review against the Mac icons.
    ...({ "data-sf-symbol": symbol } as Record<string, string>),
    class: className,
  };
}

export function ChevronLeft({ size = 13, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("chevron.left", size, className)} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width={2} stroke-linecap="round" stroke-linejoin="round">
      <path d="M10 2.5L4.5 8l5.5 5.5" />
    </svg>
  );
}

export function ChevronRight({ size = 9, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("chevron.right", size, className)} viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width={1.5} stroke-linecap="round" stroke-linejoin="round">
      <path d="M3.5 2.2 6.3 5 3.5 7.8" />
    </svg>
  );
}

export function ChevronDown({ size = 9, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("chevron.down", size, className)} viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width={1.7} stroke-linecap="round" stroke-linejoin="round">
      <path d="M2.2 3.8 5 6.5 7.8 3.8" />
    </svg>
  );
}

export function ChevronUp({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("chevron.up", size, className)} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width={1.6} stroke-linecap="round" stroke-linejoin="round">
      <path d="M3.5 10l4.5-4.5L12.5 10" />
    </svg>
  );
}

export function ChevronDownSmall({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("chevron.down", size, className)} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width={1.6} stroke-linecap="round" stroke-linejoin="round">
      <path d="M3.5 6l4.5 4.5L12.5 6" />
    </svg>
  );
}

export function PickleGlyph({ size = 15, class: className }: IconProps): JSX.Element {
  // PickleLogoGlyph (PickyConversationHeaderView.swift:825): 24-point rosette
  // plus two eye holes, even-odd filled.
  return (
    <svg {...svgProps("pickle", size, className)} viewBox="0 0 512 512">
      <path
        fill="currentColor"
        fill-rule="evenodd"
        d="M481 195.71L435.32 152.47L420.72 91.29L359.54 76.69L316.3 31.01L256.01 48.95L195.72 31.01L152.48 76.69L91.3 91.29L76.7 152.47L31.02 195.71L48.96 256L31.02 316.29L76.7 359.53L91.3 420.71L152.48 435.31L195.72 480.99L256.01 463.05L316.3 480.99L359.54 435.31L420.72 420.71L435.32 359.53L481 316.29L463.06 256L481 195.71Z M179.1 291.39C158.16 291.39 141.19 270.17 141.19 244C141.19 217.83 158.16 196.61 179.1 196.61C200.04 196.61 217.01 217.83 217.01 244C217.01 270.17 200.04 291.39 179.1 291.39Z M332.9 291.39C311.96 291.39 294.99 270.17 294.99 244C294.99 217.83 311.96 196.61 332.9 196.61C353.84 196.61 370.81 217.83 370.81 244C370.81 270.17 353.84 291.39 332.9 291.39Z"
      />
    </svg>
  );
}

export function ArchiveBox({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("archivebox", size, className)} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width={1.4} stroke-linecap="round" stroke-linejoin="round">
      <path d="M1.8 4.6h12.4v8.1a1 1 0 0 1-1 1H2.8a1 1 0 0 1-1-1z" />
      <path d="M1.2 2.3h13.6v2.3H1.2z" />
      <path d="M6.4 7.6h3.2" />
    </svg>
  );
}

export function Ellipsis({ size = 12, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("ellipsis", size, className)} viewBox="0 0 16 16" fill="currentColor">
      <circle cx="3.2" cy="8" r="1.5" />
      <circle cx="8" cy="8" r="1.5" />
      <circle cx="12.8" cy="8" r="1.5" />
    </svg>
  );
}

export function Clock({ size = 10, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("clock", size, className)} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width={1.3}>
      <circle cx="8" cy="8" r="6.2" />
      <path d="M8 4.6V8l2.4 1.6" stroke-linecap="round" />
    </svg>
  );
}

export function OpenReport({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("arrow.up.right.square", size, className)} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width={1.4}>
      <rect x="2.2" y="2.2" width="11.6" height="11.6" rx="3" />
      <path d="M6.2 9.8l3.6-3.6M6.6 6.2h3.2v3.2" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  );
}

export function ListBullet({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("list.bullet", size, className)} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width={1.4}>
      <path d="M5.5 4h8.5M5.5 8h8.5M5.5 12h8.5M2.2 4h.01M2.2 8h.01M2.2 12h.01" stroke-linecap="round" />
    </svg>
  );
}

export function Photo({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("photo", size, className)} viewBox="0 0 12 12">
      <rect x="1.2" y="2.4" width="9.6" height="7.2" rx="1.2" fill="none" stroke="currentColor" stroke-width={1.1} />
      <circle cx="4.1" cy="5" r="0.8" fill="currentColor" />
      <path d="M2 8.6 4.6 6.4 7 8.2 8.8 6.9l1.6 1.4" fill="none" stroke="currentColor" stroke-width={1.1} stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  );
}

export function PhotoMissing({ size = 15, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("photo.badge.exclamationmark", size, className)} viewBox="0 0 16 16">
      <rect x="1.2" y="3" width="11" height="8.4" rx="1.6" fill="none" stroke="currentColor" stroke-width={1.2} />
      <circle cx="4.6" cy="6" r="0.9" fill="currentColor" />
      <path d="M2.2 10.4 5.2 7.8 7.6 9.6" fill="none" stroke="currentColor" stroke-width={1.2} stroke-linecap="round" stroke-linejoin="round" />
      <circle cx="12.2" cy="11.6" r="3.2" fill="currentColor" />
      <path d="M12.2 9.9v1.9" stroke="var(--tool-image-badge-mark)" stroke-width={1.2} stroke-linecap="round" />
      <circle cx="12.2" cy="13.1" r="0.6" fill="var(--tool-image-badge-mark)" />
    </svg>
  );
}

export function Warning({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("exclamationmark.triangle", size, className)} viewBox="0 0 12 12">
      <path d="M6 1.4 L11 10.2 H1 Z" fill="none" stroke="currentColor" stroke-width={1.2} stroke-linejoin="round" />
      <path d="M6 4.6 V7.2" fill="none" stroke="currentColor" stroke-width={1.2} stroke-linecap="round" />
      <circle cx="6" cy="8.8" r="0.6" fill="currentColor" />
    </svg>
  );
}

export function Refresh({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("arrow.clockwise", size, className)} viewBox="0 0 12 12">
      <path d="M10 6a4 4 0 1 1-1.3-2.9" fill="none" stroke="currentColor" stroke-width={1.3} stroke-linecap="round" />
      <path d="M9.9 1.6 V4.2 H7.3" fill="none" stroke="currentColor" stroke-width={1.3} stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  );
}

export function Paperclip({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("paperclip", size, className)} viewBox="0 0 12 12">
      <path d="M8.6 3.1 4.3 7.4a1.4 1.4 0 0 0 2 2l4.3-4.3a2.6 2.6 0 0 0-3.7-3.7L2.3 5.9a3.8 3.8 0 0 0 5.4 5.4l3.5-3.5" fill="none" stroke="currentColor" stroke-width={1.1} stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  );
}

export function Terminal({ size = 13, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("terminal.fill", size, className)} viewBox="0 0 16 16">
      <path fill="currentColor" fill-rule="evenodd" d="M3.5 2.5h9A2.5 2.5 0 0 1 15 5v6a2.5 2.5 0 0 1-2.5 2.5h-9A2.5 2.5 0 0 1 1 11V5a2.5 2.5 0 0 1 2.5-2.5ZM4 5.3 6.7 8 4 10.7l1.1 1.1L8.9 8 5.1 4.2ZM8.6 10.2v1.4h3.6v-1.4Z" />
    </svg>
  );
}

export function Mic({ size = 12, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("mic", size, className)} viewBox="0 0 16 16">
      <rect x="5.9" y="1.6" width="4.2" height="7.8" rx="2.1" fill="none" stroke="currentColor" stroke-width={1.3} />
      <path d="M3.6 7.6a4.4 4.4 0 0 0 8.8 0M8 12v2.3" fill="none" stroke="currentColor" stroke-width={1.3} stroke-linecap="round" />
    </svg>
  );
}

export function Waveform({ size = 12, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("waveform", size, className)} viewBox="0 0 16 16">
      <path d="M2 6.5v3M4.4 4.5v7M6.8 2.5v11M9.2 5v6M11.6 3.5v9M14 6.5v3" fill="none" stroke="currentColor" stroke-width={1.4} stroke-linecap="round" />
    </svg>
  );
}

export function TextBubble({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("text.bubble", size, className)} viewBox="0 0 16 16">
      <path d="M3.2 2.2h9.6a1.6 1.6 0 0 1 1.6 1.6v5.8a1.6 1.6 0 0 1-1.6 1.6H7.4l-3.2 2.6v-2.6h-1a1.6 1.6 0 0 1-1.6-1.6V3.8a1.6 1.6 0 0 1 1.6-1.6Z" fill="none" stroke="currentColor" stroke-width={1.3} stroke-linejoin="round" />
      <path d="M4.8 5.4h6.4M4.8 7.8h4.2" fill="none" stroke="currentColor" stroke-width={1.3} stroke-linecap="round" />
    </svg>
  );
}

export function VoiceWarning({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("exclamationmark.triangle", size, className)} viewBox="0 0 16 16">
      <path d="M8 1.9 14.6 13.4H1.4Z" fill="none" stroke="currentColor" stroke-width={1.4} stroke-linejoin="round" />
      <path d="M8 6.2v3.4" fill="none" stroke="currentColor" stroke-width={1.5} stroke-linecap="round" />
      <circle cx="8" cy="11.5" r="0.9" fill="currentColor" />
    </svg>
  );
}

export function ArrowUp({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("arrow.up", size, className)} viewBox="0 0 12 12">
      <path d="M6 10V2.4" fill="none" stroke="currentColor" stroke-width={1.6} stroke-linecap="round" />
      <path d="M2.8 5.6 6 2.3l3.2 3.3" fill="none" stroke="currentColor" stroke-width={1.6} stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  );
}

export function ArrowTurnDownRight({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("arrow.turn.down.right", size, className)} viewBox="0 0 12 12">
      <path d="M2 2.4v3.1a1.6 1.6 0 0 0 1.6 1.6H9.6" fill="none" stroke="currentColor" stroke-width={1.4} stroke-linecap="round" stroke-linejoin="round" />
      <path d="M7.6 5.1 9.9 7.1 7.6 9.1" fill="none" stroke="currentColor" stroke-width={1.4} stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  );
}

export function PlayFill({ size = 10, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("play.fill", size, className)} viewBox="0 0 12 12">
      <path d="M3.4 2.2v7.6a.6.6 0 0 0 .9.5l6-3.8a.6.6 0 0 0 0-1L4.3 1.7a.6.6 0 0 0-.9.5Z" fill="currentColor" />
    </svg>
  );
}

export function StopFill({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("stop.fill", size, className)} viewBox="0 0 12 12">
      <rect x="2.2" y="2.2" width="7.6" height="7.6" rx="1.1" fill="currentColor" />
    </svg>
  );
}

export function Xmark({ size = 8, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("xmark", size, className)} viewBox="0 0 10 10">
      <path d="M2.4 2.4 7.6 7.6M7.6 2.4 2.4 7.6" fill="none" stroke="currentColor" stroke-width={1.6} stroke-linecap="round" />
    </svg>
  );
}

export function ArrowDown({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("arrow.down", size, className)} viewBox="0 0 12 12">
      <path d="M6 2v7.6" fill="none" stroke="currentColor" stroke-width={1.6} stroke-linecap="round" />
      <path d="M2.8 6.4 6 9.7l3.2-3.3" fill="none" stroke="currentColor" stroke-width={1.6} stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  );
}

/* Extension notice levels and the compaction mark. The HUD fills these
 * symbols, so the phone does too: at 11px an outline reads as noise. */

export function NotifyInfo({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("info.circle.fill", size, className)} viewBox="0 0 12 12">
      <circle cx="6" cy="6" r="5.2" fill="currentColor" />
      <circle cx="6" cy="3.5" r="0.75" fill="var(--notify-glyph, #fff)" />
      <path d="M6 5.3v3.4" fill="none" stroke="var(--notify-glyph, #fff)" stroke-width={1.5} stroke-linecap="round" />
    </svg>
  );
}

export function NotifyWarning({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("exclamationmark.triangle.fill", size, className)} viewBox="0 0 12 12">
      <path d="M5.1 1.4a1.05 1.05 0 0 1 1.8 0l4.1 7.6a1.05 1.05 0 0 1-.9 1.6H1.9a1.05 1.05 0 0 1-.9-1.6Z" fill="currentColor" />
      <path d="M6 4.2v2.7" fill="none" stroke="var(--notify-glyph, #fff)" stroke-width={1.4} stroke-linecap="round" />
      <circle cx="6" cy="8.5" r="0.7" fill="var(--notify-glyph, #fff)" />
    </svg>
  );
}

export function NotifyError({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("xmark.octagon.fill", size, className)} viewBox="0 0 12 12">
      <path d="M4.05.8h3.9L10.7 3.55v3.9L7.95 10.2h-3.9L1.3 7.45v-3.9Z" fill="currentColor" />
      <path d="M4.4 4.4 7.6 7.6M7.6 4.4 4.4 7.6" fill="none" stroke="var(--notify-glyph, #fff)" stroke-width={1.3} stroke-linecap="round" />
    </svg>
  );
}

export function CheckCircle({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("checkmark.circle", size, className)} viewBox="0 0 12 12">
      <circle cx="6" cy="6" r="5" fill="none" stroke="currentColor" stroke-width={1.1} />
      <path d="M3.7 6.2 5.3 7.8 8.4 4.4" fill="none" stroke="currentColor" stroke-width={1.3} stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  );
}

export function Branch({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("point.3.connected.trianglepath.dotted", size, className)} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width={1.4}>
      <circle cx="4" cy="3.5" r="1.6" />
      <circle cx="4" cy="12.5" r="1.6" />
      <circle cx="12" cy="5.5" r="1.6" />
      <path d="M4 5.1v5.8M12 7.1c0 3-8 1.8-8 3.8" stroke-linecap="round" />
    </svg>
  );
}

export function Folder({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("folder", size, className)} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width={1.4}>
      <path d="M1.8 4.2a1 1 0 0 1 1-1h3.4l1.4 1.6h5.6a1 1 0 0 1 1 1v6.4a1 1 0 0 1-1 1H2.8a1 1 0 0 1-1-1z" stroke-linejoin="round" />
    </svg>
  );
}

export function DocOnDoc({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("doc.on.doc", size, className)} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width={1.4}>
      <rect x="5" y="5" width="8.5" height="9" rx="1.5" />
      <path d="M3 10.5V3.5a1 1 0 0 1 1-1h6" stroke-linecap="round" />
    </svg>
  );
}

export function Checkmark({ size = 11, class: className }: IconProps): JSX.Element {
  return (
    <svg {...svgProps("checkmark", size, className)} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width={1.6}>
      <path d="M3.5 8.5 6.5 11.5 12.5 4.5" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  );
}
