import { EventEmitter } from "node:events";
import type WebSocket from "ws";
import WebSocketImpl from "ws";
import { buildCodexClientHeaders, loadCodexOAuth, type CodexOAuthLoader } from "./codex-oauth.js";

/**
 * Realtime transcription session over Codex/ChatGPT OAuth.
 *
 * Connects to `wss://api.openai.com/v1/realtime?intent=transcription` with the
 * same client headers the rest of agentd uses (originator: codex_cli_rs +
 * ChatGPT OAuth bearer), configures a transcription-only session
 * (`session.type = "transcription"`), and exposes a small append/commit/close
 * surface that mirrors `BuddyStreamingTranscriptionSession` on the Swift side.
 *
 * The PoC at agentd/scratch/realtime-stt-oauth-probe.ts validated the exact
 * server event shape this module relies on:
 *   session.created -> session.update -> session.updated ->
 *   input_audio_buffer.append* -> input_audio_buffer.commit ->
 *   conversation.item.input_audio_transcription.delta* ->
 *   conversation.item.input_audio_transcription.completed
 *
 * The runtime emits high-level events the supervisor forwards to Picky:
 *  - "started"   : session is ready to accept audio
 *  - "delta"     : partial transcript text
 *  - "completed" : final transcript text
 *  - "failed"    : connection / API error (terminal)
 *  - "closed"    : socket closed (terminal)
 */

export type WebSocketFactory = (url: string, headers: Record<string, string>) => WebSocket;

export interface TranscriptionStreamOptions {
  streamId: string;
  language?: string;
  model?: string;
  /** Override for tests. Defaults to a real ws() connection. */
  webSocketFactory?: WebSocketFactory;
  /** Override for tests. Defaults to loadCodexOAuth() from disk. */
  oauthLoader?: CodexOAuthLoader;
  /** Wire URL override (test fixtures + CodexLB). */
  url?: string;
  /** Audio sample rate (Hz) that the client will append. Defaults to 24 kHz. */
  sampleRateHz?: number;
}

export type TranscriptionStreamEvent =
  | { type: "started" }
  | { type: "delta"; delta: string }
  | { type: "completed"; transcript: string }
  | { type: "failed"; message: string }
  | { type: "closed" };

const DEFAULT_URL = "wss://api.openai.com/v1/realtime?intent=transcription";
const DEFAULT_MODEL = "gpt-4o-transcribe";
const DEFAULT_SAMPLE_RATE_HZ = 24_000;

export class OpenAIRealtimeTranscriptionSession extends EventEmitter {
  readonly streamId: string;
  private readonly language?: string;
  private readonly model: string;
  private readonly url: string;
  private readonly sampleRateHz: number;
  private readonly oauthLoader: CodexOAuthLoader;
  private readonly factory: WebSocketFactory;

  private ws: WebSocket | undefined;
  private state: "idle" | "connecting" | "configuring" | "ready" | "committing" | "closing" | "closed" = "idle";
  private pendingAudio: string[] = [];
  private finalTranscript = "";
  private aggregatedTranscript = "";

  constructor(options: TranscriptionStreamOptions) {
    super();
    this.streamId = options.streamId;
    this.language = options.language;
    this.model = options.model ?? DEFAULT_MODEL;
    this.url = options.url ?? DEFAULT_URL;
    this.sampleRateHz = options.sampleRateHz ?? DEFAULT_SAMPLE_RATE_HZ;
    this.oauthLoader = options.oauthLoader ?? loadCodexOAuth;
    this.factory =
      options.webSocketFactory ?? ((u, headers) => new WebSocketImpl(u, { headers }) as unknown as WebSocket);
  }

  emit(event: "event", payload: TranscriptionStreamEvent): boolean {
    return super.emit(event, payload);
  }

  on(event: "event", listener: (payload: TranscriptionStreamEvent) => void): this {
    return super.on(event, listener);
  }

  async start(): Promise<void> {
    if (this.state !== "idle") {
      throw new Error(`transcription session already started (state=${this.state})`);
    }
    this.state = "connecting";
    let auth;
    try {
      auth = await this.oauthLoader();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.state = "closed";
      this.emit("event", { type: "failed", message });
      this.emit("event", { type: "closed" });
      throw error;
    }

    const headers = buildCodexClientHeaders(auth);
    const ws = this.factory(this.url, headers);
    this.ws = ws;

    ws.on("open", () => this.handleOpen());
    ws.on("message", (raw: WebSocket.RawData) => this.handleMessage(raw.toString()));
    ws.on("error", (error: Error) => this.handleError(error));
    ws.on("close", () => this.handleClose());
  }

  appendAudio(audioBase64: string): void {
    if (!audioBase64) return;
    if (this.state === "configuring" || this.state === "connecting") {
      // Buffer until session.updated arrives.
      this.pendingAudio.push(audioBase64);
      return;
    }
    if (this.state !== "ready") return;
    this.send({ type: "input_audio_buffer.append", audio: audioBase64 });
  }

  /**
   * Commit the buffered audio and request the final transcript. The session
   * will close itself after the transcription.completed event arrives (or on
   * a failure). Calling this is idempotent: subsequent calls are ignored.
   */
  commit(): void {
    if (this.state !== "ready") {
      if (this.state === "configuring" || this.state === "connecting") {
        // Defer; we'll commit as soon as we hit ready.
        this.state = "committing";
      }
      return;
    }
    this.state = "committing";
    this.flushPendingAudio();
    this.send({ type: "input_audio_buffer.commit" });
  }

  cancel(): void {
    if (this.state === "closed" || this.state === "closing") return;
    this.state = "closing";
    try {
      this.send({ type: "input_audio_buffer.clear" });
    } catch {
      // ignore
    }
    this.closeSocket();
  }

  private handleOpen(): void {
    this.state = "configuring";
    const sessionUpdate: Record<string, unknown> = {
      type: "transcription",
      audio: {
        input: {
          format: { type: "audio/pcm", rate: this.sampleRateHz },
          transcription: {
            model: this.model,
            ...(this.language ? { language: this.language } : {}),
          },
          // Manual turn detection: Picky drives commit when PTT releases.
          turn_detection: null,
        },
      },
    };
    this.send({ type: "session.update", session: sessionUpdate });
  }

  private handleMessage(raw: string): void {
    let parsed: any;
    try {
      parsed = JSON.parse(raw);
    } catch {
      return;
    }
    const type = parsed?.type;
    if (typeof type !== "string") return;

    switch (type) {
      case "session.created":
      case "transcription_session.created":
        return; // session.update issued from handleOpen()

      case "session.updated":
      case "transcription_session.updated": {
        this.flushPendingAudio();
        const pendingCommit = this.state === "committing";
        this.state = "ready";
        this.emit("event", { type: "started" });
        if (pendingCommit) this.commit();
        return;
      }

      case "conversation.item.input_audio_transcription.delta": {
        const delta = typeof parsed.delta === "string" ? parsed.delta : "";
        if (!delta) return;
        this.aggregatedTranscript += delta;
        this.emit("event", { type: "delta", delta });
        return;
      }

      case "conversation.item.input_audio_transcription.completed": {
        const transcript = typeof parsed.transcript === "string"
          ? parsed.transcript
          : this.aggregatedTranscript;
        this.finalTranscript = transcript;
        this.emit("event", { type: "completed", transcript });
        // Server keeps the socket open for further commits; we close because
        // BuddyDictationManager spins up a new session per PTT cycle.
        this.closeSocket();
        return;
      }

      case "conversation.item.input_audio_transcription.failed":
      case "error": {
        const message = extractErrorMessage(parsed);
        this.emit("event", { type: "failed", message });
        this.closeSocket();
        return;
      }

      default:
        return;
    }
  }

  private handleError(error: Error): void {
    if (this.state === "closed") return;
    this.emit("event", { type: "failed", message: error.message });
    this.closeSocket();
  }

  private handleClose(): void {
    if (this.state === "closed") return;
    this.state = "closed";
    this.emit("event", { type: "closed" });
  }

  private flushPendingAudio(): void {
    if (this.pendingAudio.length === 0) return;
    for (const chunk of this.pendingAudio) {
      this.send({ type: "input_audio_buffer.append", audio: chunk });
    }
    this.pendingAudio = [];
  }

  private send(payload: Record<string, unknown>): void {
    const ws = this.ws;
    if (!ws) return;
    if (ws.readyState !== ws.OPEN) return;
    ws.send(JSON.stringify(payload));
  }

  private closeSocket(): void {
    if (!this.ws) {
      this.state = "closed";
      this.emit("event", { type: "closed" });
      return;
    }
    try {
      this.ws.close();
    } catch {
      // ignore
    }
  }
}

function extractErrorMessage(payload: any): string {
  const error = payload?.error;
  if (error && typeof error.message === "string") return error.message;
  if (typeof payload?.message === "string") return payload.message;
  return "Transcription session failed.";
}
