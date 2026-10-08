/**
 * The seam between the app shell (web foundation: store, transport, routing)
 * and the conversation UI (web room: everything under `src/room/`).
 *
 * The shell builds a `RoomViewModel` from its store and passes `RoomActions`
 * bound to the gateway. The room UI renders from these alone, so it can be
 * driven by fixtures in the gallery and by the real store in the app.
 *
 * Changing this file changes both sides: keep it small and additive.
 */
import type { PickyAgentSession } from "../../../src/protocol";
import type {
  RemoteCommand,
  RemoteDictationAvailability,
  RemoteDictationResponse,
  RemoteError,
  RemoteFileMetaResponse,
  RemoteMainState,
  RemoteQuery,
  RemoteRoom,
  RemoteUploadResponse,
} from "../../../src/remote/protocol";

export type RoomCommandResult = { ok: true; data?: unknown } | { ok: false; error: RemoteError };

export interface RoomViewModel {
  /** The room list entry: title, status, unread, pending question, background task count. */
  room: RemoteRoom;
  /** Pickle rooms: the session folded from snapshot + transactions. Undefined until the first snapshot. */
  session?: PickyAgentSession;
  /** The main ("Picky") room only. */
  main?: RemoteMainState;
  /** True while the first snapshot (or main state) for this room has not arrived. */
  loading: boolean;
  /** False when Picky.app is not connected to the gateway: commands will fail with `macOffline`. */
  macConnected: boolean;
  /**
   * The phone's own socket to the gateway is open. While it is down the shell
   * shows a reconnecting banner and commands could only wait, so sending is
   * paused instead of queueing silently (seen on a real device: a tap did
   * nothing visible until the connection came back).
   */
  online: boolean;
  dictation: RemoteDictationAvailability;
  /** Locale used for copy and dates ("ko" | "en"). */
  locale: "ko" | "en";
  /**
   * "wide" when the room is the right pane next to the room list (768px and
   * up): no back button, a centred reading column, menus kept inside the pane.
   * Missing means "phone".
   */
  layout?: "phone" | "wide";
}

export interface RoomActions {
  /** Sends one command; the shell adds the command id, retries over reconnects, and dedupes. */
  command(command: RemoteCommand): Promise<RoomCommandResult>;
  query(query: RemoteQuery): Promise<{ ok: true; data: unknown } | { ok: false; error: RemoteError }>;
  /** Uploads one image for the composer. */
  upload(file: Blob, name: string): Promise<RemoteUploadResponse>;
  /** URL that shows an uploaded image (composer chip thumbnail). */
  uploadUrl(uploadId: string): string;
  /** Sends a finished recording to the Mac for transcription. */
  dictate(audio: Blob): Promise<RemoteDictationResponse>;
  /** Metadata + text preview for a path referenced in this room (`/api/files/meta`). */
  fileMeta(path: string): Promise<RemoteFileMetaResponse>;
  /** URL of the raw bytes of a referenced image/PDF/HTML/SVG (`/api/files/raw`). */
  fileUrl(path: string): string;
  /** Opens the shell's full-screen file preview for a path referenced in this room. */
  openFile(path: string): void;
  /** Opens an http(s) link outside the app. */
  openExternal(url: string): void;
  /** Navigates back to the room list. */
  back(): void;
  /** Opens another room, such as the Pickle a delegation question created. */
  openRoom(roomId: string): void;
  /** Per-room draft that survives navigation and reloads. */
  loadDraft(): string;
  saveDraft(text: string): void;
  /** Haptic-like feedback hook (no-op where unsupported). */
  feedback?(kind: "success" | "warning" | "error"): void;
}

export interface RoomViewProps {
  vm: RoomViewModel;
  actions: RoomActions;
}

/**
 * Props of the markdown renderer at `src/room/markdown/Markdown.tsx`. The shell's
 * file preview renders markdown files with the same component, so a `.md` link
 * looks the same in the conversation and in the preview.
 */
export interface MarkdownProps {
  text: string;
}
