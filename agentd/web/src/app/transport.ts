/**
 * What the store needs from the outside world. Two implementations: the real
 * gateway (`gateway-transport.ts`) and the in-browser fixtures used by
 * `?demo=1` (`../demo/demo-transport.ts`).
 */
import type {
  RemoteClientMessage,
  RemoteDictationResponse,
  RemoteFileMetaResponse,
  RemoteMeResponse,
  RemotePushSubscription,
  RemoteServerMessage,
  RemoteUploadResponse,
} from "../../../src/remote/protocol";

export type ConnectionStatus = "connecting" | "open" | "offline";

export interface TransportHandlers {
  message(message: RemoteServerMessage): void;
  status(status: ConnectionStatus): void;
}

export type PairOutcome =
  | { ok: true }
  | { ok: false; reason: "invalid" | "expired" | "locked" | "macOffline" | "failed" };

export interface Transport {
  /** Opens the socket and keeps it open (reconnecting) until `stop`. */
  start(handlers: TransportHandlers): void;
  stop(): void;
  /** Dropped silently while the socket is down; the store replays what matters on reconnect. */
  send(message: RemoteClientMessage): void;

  me(): Promise<RemoteMeResponse>;
  pair(code: string, deviceName: string): Promise<PairOutcome>;
  unpair(): Promise<void>;

  upload(file: Blob, name: string): Promise<RemoteUploadResponse>;
  uploadUrl(uploadId: string): string;
  dictate(audio: Blob): Promise<RemoteDictationResponse>;

  fileMeta(roomId: string, path: string): Promise<RemoteFileMetaResponse>;
  fileUrl(roomId: string, path: string): string;

  pushSubscribe(subscription: RemotePushSubscription): Promise<void>;
  pushUnsubscribe(): Promise<void>;
  pushTest(): Promise<void>;
}

export class TransportError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
    this.name = "TransportError";
  }
}
