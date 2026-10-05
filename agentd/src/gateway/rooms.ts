/**
 * Room list projection (docs/remote-pwa-implementation.md 2.6).
 *
 * Pure on purpose: the list is the phone's whole home screen, and it is built
 * from two independent sources (daemon projections and the HUD overlay) that
 * arrive in any order. Keeping it a function of both makes "what should the
 * list look like right now" directly testable.
 */
import type { PickyAgentSession } from "../protocol.js";
import { MAIN_ROOM_ID } from "../remote/constants.js";
import type { RemoteDockGroup, RemoteFolders, RemoteRoom, RemoteRoomStatus } from "../remote/protocol.js";
import type { HubOverlay } from "./hub-link.js";

export const MAIN_ROOM_TITLE = "Picky";
const PREVIEW_MAX_CHARS = 160;

export interface MainRoomInput {
  busy: boolean;
  pendingQuestion: boolean;
  questionPrompt?: string;
  lastAssistantText?: string;
  updatedAt?: string;
  unread: boolean;
}

export interface RoomListInput {
  sessions: ReadonlyMap<string, PickyAgentSession>;
  overlay?: HubOverlay;
  main: MainRoomInput;
}

export interface RoomListResult {
  rooms: RemoteRoom[];
  groups: RemoteDockGroup[];
  folders: RemoteFolders;
}

function groupIndexOf(overlay: HubOverlay | undefined): Map<string, string[]> {
  const index = new Map<string, string[]>();
  for (const group of overlay?.groups ?? []) {
    for (const memberId of group.memberIds) {
      index.set(memberId, [...(index.get(memberId) ?? []), group.id]);
    }
  }
  return index;
}

export function buildRoomList({ sessions, overlay, main }: RoomListInput): RoomListResult {
  const groupIdsBySession = groupIndexOf(overlay);
  const unread = new Set(overlay?.unreadSessionIds ?? []);
  const archived = new Set(overlay?.archivedSessionIds ?? []);
  const visible = overlay
    ? [...overlay.activeSessionIds, ...overlay.archivedSessionIds]
    : [...sessions.keys()];

  const pickleRooms: RemoteRoom[] = [];
  const seen = new Set<string>();
  for (const sessionId of visible) {
    if (seen.has(sessionId)) continue;
    seen.add(sessionId);
    const session = sessions.get(sessionId);
    if (!session) continue;
    pickleRooms.push(pickleRoom(session, {
      unread: unread.has(sessionId),
      archived: overlay ? archived.has(sessionId) : session.archived === true,
      groupIds: groupIdsBySession.get(sessionId) ?? [],
    }));
  }
  pickleRooms.sort(compareRooms);

  return {
    rooms: [mainRoom(main), ...pickleRooms],
    groups: (overlay?.groups ?? []).map((group) => ({ id: group.id, name: group.name, color: group.color })),
    folders: overlay?.folders ?? { pinned: [], recent: [] },
  };
}

/** Pinned first, then most recent activity; the HUD dock orders the same way. */
function compareRooms(left: RemoteRoom, right: RemoteRoom): number {
  if (left.pinned !== right.pinned) return left.pinned ? -1 : 1;
  return (right.updatedAt ?? "").localeCompare(left.updatedAt ?? "");
}

function mainRoom(main: MainRoomInput): RemoteRoom {
  const status: RemoteRoomStatus = main.pendingQuestion ? "waiting_for_input" : main.busy ? "running" : "idle";
  const preview = truncatePreview(main.questionPrompt ?? main.lastAssistantText);
  return {
    id: MAIN_ROOM_ID,
    kind: "main",
    title: MAIN_ROOM_TITLE,
    status,
    ...(preview ? { preview } : {}),
    ...(main.updatedAt ? { updatedAt: main.updatedAt } : {}),
    unread: main.unread,
    pinned: false,
    archived: false,
    groupIds: [],
    pendingQuestion: main.pendingQuestion,
    backgroundTasks: 0,
  };
}

function pickleRoom(
  session: PickyAgentSession,
  overlayState: { unread: boolean; archived: boolean; groupIds: string[] },
): RemoteRoom {
  const question = session.pendingExtensionUiRequest;
  // `lastSummary` is the daemon's status line ("Agent started", "Steering
  // message sent", "Running bash: ..."), not something a person wrote; a
  // messenger list shows the newest message in the conversation instead.
  const preview = truncatePreview(questionPreview(session) ?? latestMessageText(session));
  return {
    id: session.id,
    kind: "pickle",
    title: session.title,
    status: session.status,
    ...(preview ? { preview } : {}),
    updatedAt: session.updatedAt,
    unread: overlayState.unread,
    pinned: session.pinned === true,
    archived: overlayState.archived,
    groupIds: overlayState.groupIds,
    ...(session.cwd ? { cwd: session.cwd } : {}),
    pendingQuestion: question !== undefined && isUserFacingQuestion(question.method),
    backgroundTasks: session.asyncWorkSummary?.activeRootCount ?? 0,
  };
}

/** Methods that actually block on the user; `notify`/`setStatus` do not. */
function isUserFacingQuestion(method: string): boolean {
  return method === "select" || method === "confirm" || method === "input" || method === "editor" || method === "askUserQuestion";
}

function questionPreview(session: PickyAgentSession): string | undefined {
  const request = session.pendingExtensionUiRequest;
  if (!request || !isUserFacingQuestion(request.method)) return undefined;
  return request.prompt ?? request.title ?? request.description;
}

/**
 * The newest thing said in the conversation: the agent's reply, or the user's
 * own message while the agent has not answered it yet. Without a journal
 * (a summary-only projection) the final answer stands in.
 */
function latestMessageText(session: PickyAgentSession): string | undefined {
  const messages = session.messages ?? [];
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if ((message.kind === "agent_text" || message.kind === "user_text") && message.text?.trim()) return message.text;
  }
  return session.finalAnswer;
}

/** Markdown as it reads: link and image text, no emphasis, code ticks, headings or quote and list markers. */
export function plainPreviewText(text: string): string {
  return text
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/(\*\*|__|~~)(.+?)\1/g, "$2")
    .replace(/`+([^`]+)`+/g, "$1")
    .replace(/^\s{0,3}(#{1,6}\s+|>\s?|[-*+]\s+|\d+\.\s+)/gm, "");
}

export function truncatePreview(text: string | undefined): string | undefined {
  if (!text) return undefined;
  const collapsed = plainPreviewText(text).replace(/\s+/g, " ").trim();
  if (!collapsed) return undefined;
  return collapsed.length > PREVIEW_MAX_CHARS ? `${collapsed.slice(0, PREVIEW_MAX_CHARS - 1)}…` : collapsed;
}
