/**
 * Wire contract between the remote PWA (browser) and the Picky gateway.
 *
 * Browser code imports only types from this file (`import type`) and runtime
 * constants from `./constants.ts`: the schemas below pull in zod and the daemon
 * protocol. The gateway parses every client message with them before acting.
 * Server messages are typed only; the gateway builds them.
 *
 * Architecture and rules: docs/remote-pwa-implementation.md.
 */
import { z } from "zod";
import {
  ThinkingLevelSchema,
  type PickyAgentSession,
  type PickyExtensionUiRequest,
  type PickyMainActivity,
  type PickySessionProjectionMutation,
  type SessionStatus,
} from "../protocol.js";
import type { MainDelegationDecision, MainTaskStatus } from "../features/main-tasks/schema.js";

import { REMOTE_LIMITS } from "./constants.js";

export { MAIN_ROOM_ID, REMOTE_LIMITS, REMOTE_PROTOCOL_VERSION } from "./constants.js";

/* ------------------------------------------------------------------ */
/* Shared value types                                                  */
/* ------------------------------------------------------------------ */

export type RemoteRoomKind = "main" | "pickle";

/** Pickle rooms use the projection status. The main room adds `idle` between turns. */
export type RemoteRoomStatus = SessionStatus | "idle";

export interface RemoteRoom {
  id: string;
  kind: RemoteRoomKind;
  title: string;
  status: RemoteRoomStatus;
  /** One line for the room list (last summary, last reply, or pending question prompt). */
  preview?: string;
  /** ISO timestamp of the last activity; drives "recent activity" ordering. */
  updatedAt?: string;
  unread: boolean;
  pinned: boolean;
  archived: boolean;
  /** Dock groups that contain this room (the HUD allows at most one today). */
  groupIds: string[];
  cwd?: string;
  /** True while an extension UI question waits for the user. */
  pendingQuestion: boolean;
  /** Active background (async) root tasks; drives the stop choice. */
  backgroundTasks: number;
}

export interface RemoteDockGroup {
  id: string;
  name: string;
  /** Dock group color token name from the Mac (`PickyDockGroupColor` raw value). */
  color: string;
}

export interface RemoteFolders {
  pinned: string[];
  recent: string[];
}

export type RemoteDictationUnavailableReason = "macPermission" | "macService" | "macUnavailable";

export type RemoteDictationAvailability =
  | { available: true }
  | { available: false; reason: RemoteDictationUnavailableReason };

export interface RemoteMacState {
  /** True while Picky.app (the hub) is connected to the gateway. */
  connected: boolean;
  name?: string;
  appVersion?: string;
  dictation: RemoteDictationAvailability;
}

export interface RemoteMainMessage {
  /** Stable within one gateway process: `${createdAt}#${index}`. */
  id: string;
  role: "user" | "assistant";
  text: string;
  createdAt: string;
  /**
   * An image the main agent read (`text` is empty). The daemon's transcript is
   * text only, so the gateway records these from finished `read` activity;
   * they last as long as the gateway process.
   */
  image?: { path: string; mimeType?: string; toolName: string };
}

/**
 * One Task of the main agent, trimmed for the phone.
 *
 * The daemon's `MainTask` carries the full instruction list and report; the
 * phone shows what it can act on: the state, the controls that are allowed,
 * and a short result. Sizes are bounded by `REMOTE_LIMITS` like every other
 * remote payload.
 */
export interface RemoteMainTask {
  id: string;
  title: string;
  status: MainTaskStatus;
  cwd?: string;
  /** The Task may only read; shown so a stopped Task's leftovers are easier to judge. */
  readonly: boolean;
  createdAt: string;
  updatedAt: string;
  /** The daemon decides, not the phone: these drive the Stop and Resume buttons. */
  canStop: boolean;
  canResume: boolean;
  /** First instruction line, for the expanded row. */
  instructions?: string;
  report?: { status: "success" | "failed" | "blocked"; summary: string; blockers: string[] };
  error?: string;
  /** A Pickle took this Task over; its own result stays as it was. */
  handoffSessionId?: string;
}

/** A "hand this to a Pickle?" decision. `pending` means nothing runs until the user answers. */
export interface RemoteMainDelegation {
  id: string;
  state: MainDelegationDecision["state"];
  title: string;
  /** The question the main agent asked, in the user's language. */
  question?: string;
  instructions: string;
  cwd?: string;
  createdAt: string;
  updatedAt: string;
  /** The Task that runs this scope after the user chose Task. */
  taskId?: string;
  pickle?: { state: "creating" | "created" | "failed"; sessionId?: string; error?: string };
}

export interface RemoteMainState {
  messages: RemoteMainMessage[];
  activity?: PickyMainActivity;
  pendingQuestion?: PickyExtensionUiRequest;
  /** A main turn is in progress (between submit and mainTurnSettled). */
  busy: boolean;
  /** Background Tasks of the main conversation, newest-relevant first (bounded). */
  tasks: RemoteMainTask[];
  /** Pickle delegation decisions, pending ones kept first (bounded). */
  decisions: RemoteMainDelegation[];
}

export type RemoteErrorCode =
  | "invalid"
  | "unauthorized"
  | "notFound"
  | "macOffline"
  | "rejected"
  | "timeout"
  | "rateLimited"
  | "unsupported"
  | "tooLarge"
  | "internal";

export interface RemoteError {
  code: RemoteErrorCode;
  message: string;
}

/* ------------------------------------------------------------------ */
/* Server -> client (WebSocket /api/ws)                                */
/* ------------------------------------------------------------------ */

export interface RemoteSessionSnapshotMessage {
  type: "session.snapshot";
  sessionId: string;
  epoch: string;
  revision: number;
  complete: boolean;
  omittedFields: string[];
  projection: PickyAgentSession;
}

export interface RemoteSessionTransactionMessage {
  type: "session.transaction";
  sessionId: string;
  epoch: string;
  baseRevision: number;
  revision: number;
  mutations: PickySessionProjectionMutation[];
}

export type RemoteServerMessage =
  | {
      type: "welcome";
      protocolVersion: number;
      device: { id: string; name: string };
      mac: RemoteMacState;
      serverTime: string;
      /** Base64url VAPID public key, present once push keys exist. */
      vapidPublicKey?: string;
    }
  | { type: "mac"; mac: RemoteMacState }
  | { type: "rooms"; rooms: RemoteRoom[]; groups: RemoteDockGroup[]; folders: RemoteFolders }
  | RemoteSessionSnapshotMessage
  | RemoteSessionTransactionMessage
  | { type: "session.unavailable"; sessionId: string; reason: "notFound" | "macOffline" }
  | { type: "main.state"; state: RemoteMainState }
  | { type: "main.message"; message: RemoteMainMessage }
  | { type: "main.activity"; activity?: PickyMainActivity; busy: boolean }
  | { type: "main.question"; request?: PickyExtensionUiRequest }
  | { type: "main.tasks"; tasks: RemoteMainTask[]; decisions: RemoteMainDelegation[] }
  | { type: "command.result"; commandId: string; ok: true; data?: unknown }
  | { type: "command.result"; commandId: string; ok: false; error: RemoteError }
  | { type: "query.result"; queryId: string; ok: true; data: unknown }
  | { type: "query.result"; queryId: string; ok: false; error: RemoteError }
  | { type: "pong"; t: number }
  | { type: "revoked" }
  | { type: "error"; error: RemoteError };

/* ------------------------------------------------------------------ */
/* Client -> server (WebSocket /api/ws), validated by the gateway      */
/* ------------------------------------------------------------------ */

const IdSchema = z.string().min(1).max(200);
const TextSchema = z.string().min(1).max(REMOTE_LIMITS.textChars);
const UploadIdsSchema = z.array(z.string().regex(/^[A-Za-z0-9_-]{8,64}$/)).max(REMOTE_LIMITS.uploadsPerMessage).optional();

export const RemoteCommandSchema = z.discriminatedUnion("type", [
  // Session commands. The gateway sends the same daemon command the HUD sends
  // to the daemon that owns the session (docs/remote-pwa-implementation.md 4.2).
  z.object({ type: z.literal("session.send"), sessionId: IdSchema, text: TextSchema, kind: z.enum(["steer", "followUp"]), uploadIds: UploadIdsSchema }),
  z.object({ type: z.literal("session.schedule"), sessionId: IdSchema, text: TextSchema, delayMs: z.number().int().positive().max(REMOTE_LIMITS.scheduleMaxDelayMs), uploadIds: UploadIdsSchema }),
  z.object({ type: z.literal("session.abort"), sessionId: IdSchema, scope: z.enum(["response", "all"]) }),
  z.object({ type: z.literal("session.answer"), sessionId: IdSchema, requestId: IdSchema, value: z.unknown() }),
  z.object({ type: z.literal("session.queue.remove"), sessionId: IdSchema, itemId: IdSchema }),
  z.object({ type: z.literal("session.queue.edit"), sessionId: IdSchema, itemId: IdSchema, text: TextSchema }),
  z.object({ type: z.literal("session.queue.sendNow"), sessionId: IdSchema, itemId: IdSchema }),
  z.object({ type: z.literal("session.queue.clear"), sessionId: IdSchema, kind: z.enum(["steering", "followUp", "all"]) }),
  z.object({ type: z.literal("session.scheduled.cancel"), sessionId: IdSchema, scheduledId: IdSchema }),
  z.object({ type: z.literal("session.scheduled.sendNow"), sessionId: IdSchema, scheduledId: IdSchema }),
  z.object({ type: z.literal("session.scheduled.edit"), sessionId: IdSchema, scheduledId: IdSchema, text: TextSchema }),
  z.object({ type: z.literal("session.setModel"), sessionId: IdSchema, provider: IdSchema, modelId: IdSchema }),
  z.object({ type: z.literal("session.setThinking"), sessionId: IdSchema, thinkingLevel: ThinkingLevelSchema }),
  z.object({ type: z.literal("session.setFast"), sessionId: IdSchema, enabled: z.boolean() }),
  z.object({ type: z.literal("session.setNotify"), sessionId: IdSchema, target: z.enum(["main", "macos"]), enabled: z.boolean() }),
  // App-owned actions. The gateway forwards these to the hub inside Picky.app.
  z.object({ type: z.literal("session.markRead"), sessionId: IdSchema }),
  z.object({ type: z.literal("session.archive"), sessionId: IdSchema, archived: z.boolean() }),
  z.object({ type: z.literal("pickle.create"), cwd: z.string().min(1).max(4096), text: TextSchema.optional(), uploadIds: UploadIdsSchema }),
  z.object({ type: z.literal("main.send"), text: TextSchema, uploadIds: UploadIdsSchema }),
  z.object({ type: z.literal("main.abort") }),
  z.object({ type: z.literal("main.answer"), requestId: IdSchema, value: z.unknown() }),
  // Main Tasks. These go to the primary daemon, which owns Task state; the
  // phone never starts a Task itself, it only stops, resumes, or answers a
  // delegation decision the main agent already raised.
  z.object({ type: z.literal("main.task.control"), taskId: IdSchema, action: z.enum(["stop", "resume"]) }),
  z.object({ type: z.literal("main.delegation.resolve"), decisionId: IdSchema, choice: z.enum(["pickle", "task", "cancel"]) }),
]);
export type RemoteCommand = z.infer<typeof RemoteCommandSchema>;

export const RemoteQuerySchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("session.runtimeOptions"), sessionId: IdSchema }),
  z.object({ type: z.literal("session.diff"), sessionId: IdSchema, view: z.enum(["unstaged", "staged"]) }),
  /** Repository, branch, line counts and ahead/behind for the work panel (the HUD context line). */
  z.object({ type: z.literal("session.gitSummary"), sessionId: IdSchema }),
  /** The Pickle's slash commands (extensions, prompts, skills, built-ins), for composer autocomplete. */
  z.object({ type: z.literal("session.slashCommands"), sessionId: IdSchema }),
]);
export type RemoteQuery = z.infer<typeof RemoteQuerySchema>;

export const RemoteClientMessageSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("hello"), protocolVersion: z.number().int(), locale: z.string().max(35).optional(), visible: z.boolean() }),
  z.object({ type: z.literal("visibility"), visible: z.boolean() }),
  /** Subscribe to a room. `MAIN_ROOM_ID` opens the main conversation. Also marks the room as viewed for push suppression. */
  z.object({ type: z.literal("room.open"), roomId: IdSchema }),
  z.object({ type: z.literal("room.close"), roomId: IdSchema }),
  /** Ask for a fresh snapshot after a revision gap or epoch change. */
  z.object({ type: z.literal("room.resync"), roomId: IdSchema }),
  z.object({ type: z.literal("command"), commandId: z.string().min(8).max(100), command: RemoteCommandSchema }),
  z.object({ type: z.literal("query"), queryId: z.string().min(1).max(100), query: RemoteQuerySchema }),
  z.object({ type: z.literal("ping"), t: z.number() }),
]);
export type RemoteClientMessage = z.infer<typeof RemoteClientMessageSchema>;

/* ------------------------------------------------------------------ */
/* REST (same origin, JSON unless noted)                               */
/* ------------------------------------------------------------------ */

/** GET /api/me */
export interface RemoteMeResponse {
  paired: boolean;
  device?: { id: string; name: string };
  macName?: string;
  /** True when the request did not arrive over https (local testing). */
  insecure: boolean;
}

/** POST /api/pair */
export const RemotePairRequestSchema = z.object({
  code: z.string().min(4).max(32),
  deviceName: z.string().min(1).max(60),
});
export type RemotePairRequest = z.infer<typeof RemotePairRequestSchema>;

/** POST /api/uploads (raw image body, `Content-Type: image/*`, header `X-File-Name`) */
export interface RemoteUploadResponse {
  uploadId: string;
  name: string;
  size: number;
  mime: string;
}

export type RemoteFileKind = "text" | "markdown" | "image" | "pdf" | "html" | "svg" | "binary" | "directory";

/** GET /api/files/meta?sessionId=&path= (path as written in the conversation) */
export interface RemoteFileMetaResponse {
  kind: RemoteFileKind;
  name: string;
  /** Absolute real path on the Mac after normalization. */
  path: string;
  size: number;
  modifiedAt?: string;
  /** Text and markdown only: the first `REMOTE_LIMITS.previewTextBytes` bytes. */
  text?: string;
  truncated?: boolean;
}

/** POST /api/dictation (raw audio body, `Content-Type: audio/*`) */
export type RemoteDictationResponse =
  | { ok: true; text: string }
  | { ok: false; reason: RemoteDictationUnavailableReason | "noSpeech" | "failed" | "tooLarge" };

/** POST /api/push/subscription (body: PushSubscription.toJSON()) */
export const RemotePushSubscriptionSchema = z.object({
  endpoint: z.string().url().max(2048),
  expirationTime: z.number().nullable().optional(),
  keys: z.object({ p256dh: z.string().min(1).max(200), auth: z.string().min(1).max(100) }),
});
export type RemotePushSubscription = z.infer<typeof RemotePushSubscriptionSchema>;

/** Payload the service worker receives in a push event (JSON). */
export interface RemotePushPayload {
  title: string;
  body: string;
  /** Room to open on click; also the notification tag so one room keeps one notification. */
  roomId: string;
  kind: "question" | "completed" | "failed" | "reply";
  /** Rooms waiting for the user, for the home screen badge. */
  badge: number;
}
