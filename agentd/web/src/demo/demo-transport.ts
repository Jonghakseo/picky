/**
 * `?demo=1`: the whole app without a Mac. Same `Transport` interface as the
 * gateway, same frame shapes (snapshot then transactions with a revision
 * chain), so the store, the reducer and the room UI run their real code paths.
 */
import type {
  PickyAgentSession,
  PickySessionMessage,
  PickySessionProjectionMutation,
} from "../../../src/protocol";
import type {
  RemoteClientMessage,
  RemoteCommand,
  RemoteDictationResponse,
  RemoteFileMetaResponse,
  RemoteMainMessage,
  RemoteMainState,
  RemoteMeResponse,
  RemotePushSubscription,
  RemoteRoom,
  RemoteServerMessage,
  RemoteUploadResponse,
} from "../../../src/remote/protocol";
import { MAIN_ROOM_ID } from "../../../src/remote/constants";
import type { PairOutcome, Transport, TransportHandlers } from "../app/transport";
import { cloneDemoSessions, demoFolders, demoGroups, demoMac, demoMain, demoRooms } from "./fixtures";

const EPOCH = "demo-epoch-1";
const REPLY_DELAY_MS = 1_400;

/** Review knobs; see src/demo/scenario.ts. Defaults are the full happy demo. */
export interface DemoOptions {
  /** false puts the Mac-asleep banner on the room list. */
  macConnected?: boolean;
  /** true keeps only the Picky room, so the empty state shows. */
  noPickles?: boolean;
}

/** Any other code is refused, which is how the pairing error state is reviewed. */
export const DEMO_PAIRING_CODE = "PCKY2345";

export class DemoTransport implements Transport {
  private handlers?: TransportHandlers;
  private readonly sessions = cloneDemoSessions();
  private readonly revisions = new Map<string, number>();
  private rooms: RemoteRoom[];
  private main: RemoteMainState = structuredClone(demoMain);
  private readonly timers = new Set<ReturnType<typeof setTimeout>>();
  private counter = 0;

  constructor(private readonly options: DemoOptions = {}) {
    const rooms = demoRooms();
    this.rooms = options.noPickles ? rooms.filter((room) => room.id === MAIN_ROOM_ID) : rooms;
  }

  start(handlers: TransportHandlers): void {
    this.handlers = handlers;
    handlers.status("connecting");
    this.later(() => {
      handlers.status("open");
      this.emit({
        type: "welcome",
        protocolVersion: 1,
        device: { id: "demo-device", name: "iPhone" },
        mac: { ...demoMac, connected: this.options.macConnected ?? true },
        serverTime: new Date().toISOString(),
        vapidPublicKey: undefined,
      });
      this.emit({ type: "rooms", rooms: this.rooms, groups: demoGroups, folders: demoFolders });
    }, 0);
  }

  stop(): void {
    for (const timer of this.timers) clearTimeout(timer);
    this.timers.clear();
  }

  send(message: RemoteClientMessage): void {
    switch (message.type) {
      case "room.open":
      case "room.resync":
        this.later(() => this.sendRoomState(message.roomId), 0);
        break;
      case "command":
        this.later(() => this.runCommand(message.commandId, message.command), 120);
        break;
      case "query":
        this.later(() => this.emit({ type: "query.result", queryId: message.queryId, ok: false, error: { code: "unsupported", message: "demo" } }), 60);
        break;
      case "ping":
        this.emit({ type: "pong", t: message.t });
        break;
      case "hello":
      case "visibility":
      case "room.close":
        break;
    }
  }

  /* ---- REST ---------------------------------------------------------- */

  async me(): Promise<RemoteMeResponse> {
    return { paired: true, device: { id: "demo-device", name: "iPhone" }, macName: demoMac.name, insecure: false };
  }

  async pair(code: string): Promise<PairOutcome> {
    return code === DEMO_PAIRING_CODE ? { ok: true } : { ok: false, reason: "invalid" };
  }

  async unpair(): Promise<void> {}

  async upload(file: Blob, name: string): Promise<RemoteUploadResponse> {
    return { uploadId: `demo-${(this.counter += 1)}`, name, size: file.size, mime: file.type || "image/png" };
  }

  uploadUrl(uploadId: string): string {
    return `/api/uploads/${uploadId}`;
  }

  async dictate(): Promise<RemoteDictationResponse> {
    return { ok: true, text: "받아쓴 문장이 여기에 들어가요" };
  }

  async fileMeta(_roomId: string, path: string): Promise<RemoteFileMetaResponse> {
    const name = path.split("/").pop() ?? path;
    if (/\.(png|jpe?g|gif|webp)$/i.test(name)) {
      return { kind: "image", name, path, size: 184_320 };
    }
    if (/\.md$/i.test(name)) {
      return { kind: "markdown", name, path, size: 2_140, text: `# ${name}\n\n데모 모드에서는 맥의 파일 대신 이 글을 보여 줘요.\n\n- 첫째 줄\n- 둘째 줄\n` };
    }
    return {
      kind: "text",
      name,
      path,
      size: 1_280,
      text: `// ${name}\n// 데모 모드에서는 맥의 파일 대신 이 글을 보여 줘요.\nfunc archive(_ sessionID: String) {\n    store.archive(sessionID, at: .now)\n}\n`,
      truncated: true,
    };
  }

  fileUrl(_roomId: string, path: string): string {
    return `/api/files/raw?path=${encodeURIComponent(path)}`;
  }

  async pushSubscribe(_subscription: RemotePushSubscription): Promise<void> {}
  async pushUnsubscribe(): Promise<void> {}
  async pushTest(): Promise<void> {}

  /* ---- internals ------------------------------------------------------ */

  private later(run: () => void, delay: number): void {
    const timer = setTimeout(() => {
      this.timers.delete(timer);
      run();
    }, delay);
    this.timers.add(timer);
  }

  private emit(message: RemoteServerMessage): void {
    this.handlers?.message(message);
  }

  private sendRoomState(roomId: string): void {
    if (roomId === MAIN_ROOM_ID) {
      this.emit({ type: "main.state", state: this.main });
      return;
    }
    const session = this.sessions.get(roomId);
    if (!session) {
      this.emit({ type: "session.unavailable", sessionId: roomId, reason: "notFound" });
      return;
    }
    const revision = this.revisions.get(roomId) ?? session.revision ?? 1;
    this.revisions.set(roomId, revision);
    this.emit({
      type: "session.snapshot",
      sessionId: roomId,
      epoch: EPOCH,
      revision,
      complete: true,
      omittedFields: [],
      projection: { ...session, revision },
    });
  }

  private transact(sessionId: string, mutations: PickySessionProjectionMutation[]): void {
    const baseRevision = this.revisions.get(sessionId) ?? 1;
    const revision = baseRevision + 1;
    this.revisions.set(sessionId, revision);
    this.emit({ type: "session.transaction", sessionId, epoch: EPOCH, baseRevision, revision, mutations });
  }

  private refreshRooms(): void {
    this.emit({ type: "rooms", rooms: this.rooms, groups: demoGroups, folders: demoFolders });
  }

  private patchRoom(roomId: string, patch: Partial<RemoteRoom>): void {
    this.rooms = this.rooms.map((room) => (room.id === roomId ? { ...room, ...patch } : room));
    this.refreshRooms();
  }

  private runCommand(commandId: string, command: RemoteCommand): void {
    switch (command.type) {
      case "session.send":
        this.appendUserMessage(command.sessionId, command.text);
        this.ok(commandId);
        return;
      case "main.send":
        this.appendMainMessage(command.text);
        this.ok(commandId);
        return;
      case "main.abort":
        this.main = { ...this.main, busy: false, activity: undefined };
        this.emit({ type: "main.activity", activity: undefined, busy: false });
        this.ok(commandId);
        return;
      case "main.answer":
        this.main = { ...this.main, pendingQuestion: undefined };
        this.emit({ type: "main.question", request: undefined });
        this.ok(commandId);
        return;
      case "session.answer": {
        const session = this.sessions.get(command.sessionId);
        if (session) {
          session.pendingExtensionUiRequest = undefined;
          session.status = "running";
          this.transact(command.sessionId, [
            { type: "extensionUiRequestSet", request: null },
            { type: "metaPatch", patch: { status: "running", lastSummary: "답을 받고 이어서 진행하는 중" } },
          ]);
          this.patchRoom(command.sessionId, { status: "running", pendingQuestion: false, unread: false, preview: "답을 받고 이어서 진행하는 중" });
        }
        this.ok(commandId);
        return;
      }
      case "session.abort": {
        const session = this.sessions.get(command.sessionId);
        if (session) {
          session.status = "cancelled";
          this.transact(command.sessionId, [{ type: "metaPatch", patch: { status: "cancelled", lastSummary: "사용자가 중지했어요" } }]);
          this.patchRoom(command.sessionId, { status: "cancelled", preview: "사용자가 중지했어요" });
        }
        this.ok(commandId);
        return;
      }
      case "session.markRead":
        this.patchRoom(command.sessionId, { unread: false });
        this.ok(commandId);
        return;
      case "session.archive":
        this.patchRoom(command.sessionId, { archived: command.archived });
        this.ok(commandId);
        return;
      case "pickle.create": {
        const sessionId = `s-demo-${(this.counter += 1)}`;
        const now = new Date().toISOString();
        const created: PickyAgentSession = {
          id: sessionId,
          title: command.cwd.split("/").pop() ?? "새 Pickle",
          status: "queued",
          cwd: command.cwd,
          createdAt: now,
          updatedAt: now,
          logs: [],
          tools: [],
          artifacts: [],
          changedFiles: [],
          messages: [],
          revision: 1,
        };
        this.sessions.set(sessionId, created);
        this.revisions.set(sessionId, 1);
        this.rooms = [
          this.rooms[0] as RemoteRoom,
          {
            id: sessionId,
            kind: "pickle",
            title: created.title,
            status: "queued",
            updatedAt: now,
            unread: false,
            pinned: false,
            archived: false,
            groupIds: [],
            cwd: command.cwd,
            pendingQuestion: false,
            backgroundTasks: 0,
          },
          ...this.rooms.slice(1),
        ];
        this.refreshRooms();
        this.emit({ type: "command.result", commandId, ok: true, data: { sessionId } });
        return;
      }
      default:
        this.ok(commandId);
    }
  }

  private ok(commandId: string): void {
    this.emit({ type: "command.result", commandId, ok: true });
  }

  private appendUserMessage(sessionId: string, text: string): void {
    const session = this.sessions.get(sessionId);
    if (!session) return;
    const user: PickySessionMessage = {
      id: `demo-u-${(this.counter += 1)}`,
      kind: "user_text",
      text,
      createdAt: new Date().toISOString(),
      originatedBy: "user",
    };
    session.messages = [...(session.messages ?? []), user];
    session.status = "running";
    this.transact(sessionId, [
      { type: "messageAppend", message: user },
      { type: "metaPatch", patch: { status: "running", updatedAt: user.createdAt, lastSummary: "방금 보낸 지시를 처리하는 중" } },
    ]);
    this.patchRoom(sessionId, { status: "running", updatedAt: user.createdAt, preview: "방금 보낸 지시를 처리하는 중" });

    this.later(() => {
      const reply: PickySessionMessage = {
        id: `demo-a-${(this.counter += 1)}`,
        kind: "agent_text",
        text: `"${text.slice(0, 40)}" 요청을 데모 모드에서 받았어요. 실제 Pickle은 맥에서 돌아요.`,
        createdAt: new Date().toISOString(),
      };
      const held = this.sessions.get(sessionId);
      if (!held) return;
      held.messages = [...(held.messages ?? []), reply];
      held.status = "completed";
      this.transact(sessionId, [
        { type: "messageAppend", message: reply },
        { type: "metaPatch", patch: { status: "completed", updatedAt: reply.createdAt, lastSummary: "데모 응답을 보냈어요" } },
      ]);
      this.patchRoom(sessionId, { status: "completed", updatedAt: reply.createdAt, preview: "데모 응답을 보냈어요" });
    }, REPLY_DELAY_MS);
  }

  private appendMainMessage(text: string): void {
    const user: RemoteMainMessage = { id: `demo-m-${(this.counter += 1)}`, role: "user", text, createdAt: new Date().toISOString() };
    this.main = { ...this.main, messages: [...this.main.messages, user], busy: true };
    this.emit({ type: "main.message", message: user });
    this.emit({ type: "main.activity", activity: { kind: "thinking", thinkingPreview: "무엇을 해야 할지 정하는 중" }, busy: true });

    this.later(() => {
      const reply: RemoteMainMessage = {
        id: `demo-m-${(this.counter += 1)}`,
        role: "assistant",
        text: "데모 모드라 실제로 실행하지는 않았어요. 맥에 연결하면 같은 요청이 그대로 돌아가요.",
        createdAt: new Date().toISOString(),
      };
      this.main = { ...this.main, messages: [...this.main.messages, reply], busy: false, activity: undefined };
      this.emit({ type: "main.message", message: reply });
      this.emit({ type: "main.activity", activity: undefined, busy: false });
    }, REPLY_DELAY_MS);
  }
}
