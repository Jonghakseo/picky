/**
 * A Node stand-in for the Mac hub, used by `pnpm --dir agentd run dev:remote`
 * (docs/remote-pwa-implementation.md 5).
 *
 * It speaks the real `hub-protocol.ts` contract against a mock-runtime agentd,
 * so the gateway and the PWA can be exercised end to end without Picky.app and
 * without touching the user's running daemon.
 */
import WebSocket from "ws";
import { HUB_PROTOCOL_VERSION, type GatewayToHubMessage, type HubRequest } from "../../remote/hub-protocol.js";
import { DaemonLink } from "../daemon-link.js";
import { randomId } from "../storage.js";

export interface StandInHubOptions {
  gatewayUrl: string;
  hubToken: string;
  daemonUrl: string;
  daemonToken: string;
  publicUrl?: string;
  cwd: string;
  print: (line: string) => void;
}

const DICTATION_DEMO_TEXT = "받아쓰기 데모 문장이에요";

export class StandInHub {
  private socket?: WebSocket;
  private readonly sessionIds = new Set<string>();
  private readonly archived = new Set<string>();
  private readonly unread = new Set<string>();
  private readonly daemon: DaemonLink;
  private overlayTimer?: NodeJS.Timeout;

  constructor(private readonly options: StandInHubOptions) {
    this.daemon = new DaemonLink(options.daemonUrl, options.daemonToken, {
      onSnapshot: (frame) => {
        if (!this.sessionIds.has(frame.sessionId)) {
          this.sessionIds.add(frame.sessionId);
          this.unread.add(frame.sessionId);
        }
        this.scheduleOverlay();
      },
      onTransaction: () => this.scheduleOverlay(),
      onEvent: () => {},
      onConnectionChange: (connected) => {
        if (connected) this.options.print("stand-in hub: daemon link ready");
      },
    }, "dev-primary");
  }

  start(): void {
    this.daemon.start();
    this.connect();
  }

  stop(): void {
    if (this.overlayTimer) clearTimeout(this.overlayTimer);
    this.daemon.stop();
    this.socket?.close();
  }

  /** Asks the gateway for a pairing code, like the Mac's "connect a phone" sheet. */
  startPairing(): void {
    this.send({ type: "hub.pairing.start" });
  }

  /** Creates demo Pickles so the room list and a conversation are not empty. */
  async seed(prompts: readonly string[]): Promise<void> {
    for (const prompt of prompts) {
      const sessionId = await this.createPickle(this.options.cwd);
      await this.daemon.send({ type: "followUp", sessionId, text: prompt });
      this.options.print(`stand-in hub: seeded ${sessionId}`);
    }
  }

  private connect(): void {
    const socket = new WebSocket(`${this.options.gatewayUrl}/hub`, {
      headers: { Authorization: `Bearer ${this.options.hubToken}` },
    });
    this.socket = socket;
    socket.on("open", () => this.announce());
    socket.on("message", (data) => void this.handle(data.toString()));
    socket.on("error", (error) => this.options.print(`stand-in hub: socket error ${String(error)}`));
    socket.on("close", () => this.options.print("stand-in hub: disconnected"));
  }

  private send(message: Record<string, unknown>): void {
    this.socket?.send(JSON.stringify(message));
  }

  private announce(): void {
    this.send({ type: "hub.hello", protocolVersion: HUB_PROTOCOL_VERSION, appVersion: "dev", macName: "Dev Mac" });
    this.send({ type: "hub.daemons", token: this.options.daemonToken, primary: { url: this.options.daemonUrl }, children: [] });
    this.send({
      type: "hub.config",
      ...(this.options.publicUrl ? { publicUrl: this.options.publicUrl } : {}),
      dictation: { available: true },
    });
    this.sendOverlay();
  }

  private scheduleOverlay(): void {
    if (this.overlayTimer) return;
    this.overlayTimer = setTimeout(() => {
      this.overlayTimer = undefined;
      this.sendOverlay();
    }, 300);
    this.overlayTimer.unref?.();
  }

  private sendOverlay(): void {
    const active = [...this.sessionIds].filter((id) => !this.archived.has(id));
    this.send({
      type: "hub.overlay",
      activeSessionIds: active,
      archivedSessionIds: [...this.archived],
      unreadSessionIds: [...this.unread].filter((id) => this.sessionIds.has(id)),
      groups: active.length > 0 ? [{ id: "group-dev", name: "데모", color: "blue", memberIds: active.slice(0, 1) }] : [],
      folders: { pinned: [this.options.cwd], recent: [this.options.cwd] },
    });
  }

  private async handle(raw: string): Promise<void> {
    let message: GatewayToHubMessage;
    try {
      message = JSON.parse(raw) as GatewayToHubMessage;
    } catch {
      return;
    }
    if (message.type === "gateway.pairing") {
      // One line only: the startup summary in dev-stack.ts owns the readable
      // block, and this fires again whenever a new code is issued.
      this.options.print(`stand-in hub: pairing code ${message.code}${message.url ? ` (${message.url})` : ""}`);
      return;
    }
    if (message.type === "gateway.pairing.ended") {
      this.options.print(`stand-in hub: pairing ended (${message.reason}${message.deviceName ? `, ${message.deviceName}` : ""})`);
      return;
    }
    if (message.type === "gateway.devices") {
      this.options.print(`stand-in hub: ${message.devices.length} paired device(s)`);
      return;
    }
    if (message.type !== "gateway.request") return;
    await this.answer(message.requestId, message.request);
  }

  private async answer(requestId: string, request: HubRequest): Promise<void> {
    try {
      const data = await this.run(request);
      this.send({ type: "hub.response", requestId, ok: true, ...(data !== undefined ? { data } : {}) });
    } catch (error) {
      this.send({
        type: "hub.response",
        requestId,
        ok: false,
        error: { code: "failed", message: error instanceof Error ? error.message : String(error) },
      });
    }
  }

  private async run(request: HubRequest): Promise<unknown> {
    switch (request.type) {
      case "pickle.create":
        return { sessionId: await this.createPickle(request.cwd) };
      case "main.send":
        // The mock runtime has no main agent, so this is the daemon's plain
        // submit path with a context that carries no screen capture.
        await this.daemon.send({ type: "routeTask", context: this.context(request.text) });
        return undefined;
      case "main.abort":
        await this.daemon.send({ type: "abortMainAgent" });
        return undefined;
      case "main.answer":
        await this.daemon.send({ type: "answerMainExtensionUi", requestId: request.requestId, value: request.value });
        return undefined;
      case "session.markRead":
        this.unread.delete(request.sessionId);
        this.sendOverlay();
        return undefined;
      case "session.archive":
        if (request.archived) this.archived.add(request.sessionId);
        else this.archived.delete(request.sessionId);
        this.sendOverlay();
        return undefined;
      case "dictation.transcribe":
        return { text: DICTATION_DEMO_TEXT };
    }
  }

  private async createPickle(cwd: string): Promise<string> {
    const before = new Set(this.sessionIds);
    await this.daemon.send({ type: "createEmptyPickleSession", context: this.context(undefined, cwd) });
    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline) {
      const created = [...this.sessionIds].find((id) => !before.has(id));
      if (created) return created;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error("the mock daemon did not project a new Pickle");
  }

  private context(transcript: string | undefined, cwd = this.options.cwd): Record<string, unknown> {
    return {
      id: `dev-${randomId(6)}`,
      source: "text",
      capturedAt: new Date().toISOString(),
      ...(transcript ? { transcript } : {}),
      cwd,
      screenshots: [],
      inkMarks: [],
      warnings: [],
    };
  }
}
