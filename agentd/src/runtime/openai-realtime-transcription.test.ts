import { describe, expect, it } from "vitest";
import { OpenAIRealtimeTranscriptionSession, type TranscriptionStreamEvent } from "./openai-realtime-transcription.js";

class FakeTranscriptionSocket {
  readyState = 1;
  OPEN = 1;
  sent: Array<Record<string, any>> = [];
  private listeners = new Map<string, Array<(...args: any[]) => void>>();

  constructor() {
    queueMicrotask(() => this.emit("open"));
  }

  send(data: string): void {
    try {
      this.sent.push(JSON.parse(data));
    } catch {
      this.sent.push({ raw: data });
    }
  }

  close(): void {
    if (this.readyState === 3) return;
    this.readyState = 3;
    queueMicrotask(() => this.emit("close", 1000, Buffer.from("")));
  }

  serverEvent(event: Record<string, unknown>): void {
    this.emit("message", Buffer.from(JSON.stringify(event)));
  }

  on(event: string, listener: (...args: any[]) => void): this {
    const listeners = this.listeners.get(event) ?? [];
    listeners.push(listener);
    this.listeners.set(event, listeners);
    if (event === "open" && this.readyState === 1) queueMicrotask(listener);
    return this;
  }

  private emit(event: string, ...args: any[]): void {
    for (const listener of this.listeners.get(event) ?? []) listener(...args);
  }
}

async function settle(): Promise<void> {
  // Flush microtasks twice to let queued open/close events propagate.
  await Promise.resolve();
  await Promise.resolve();
}

function fakeAuthLoader() {
  return async () => ({ accessToken: "test-token", accountId: "test-account", isFedramp: false, source: "pi" as const });
}

describe("OpenAIRealtimeTranscriptionSession", () => {
  it("configures the session for transcription via session.update on open", async () => {
    const socket = new FakeTranscriptionSocket();
    const session = new OpenAIRealtimeTranscriptionSession({
      streamId: "stream-1",
      language: "ko",
      model: "gpt-4o-transcribe",
      oauthLoader: fakeAuthLoader(),
      webSocketFactory: () => socket as any,
    });
    await session.start();
    await settle();

    expect(socket.sent[0]).toEqual({
      type: "session.update",
      session: {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription: { model: "gpt-4o-transcribe", language: "ko" },
            turn_detection: null,
          },
        },
      },
    });
  });

  it("emits started after session.updated and forwards subsequent audio appends", async () => {
    const socket = new FakeTranscriptionSocket();
    const events: TranscriptionStreamEvent[] = [];
    const session = new OpenAIRealtimeTranscriptionSession({
      streamId: "stream-1",
      oauthLoader: fakeAuthLoader(),
      webSocketFactory: () => socket as any,
    });
    session.on("event", (event) => events.push(event));
    await session.start();
    await settle();

    socket.serverEvent({ type: "session.updated" });
    await settle();

    expect(events).toContainEqual({ type: "started" });

    session.appendAudio("AAAA");
    expect(socket.sent[1]).toEqual({ type: "input_audio_buffer.append", audio: "AAAA" });
  });

  it("queues audio appended before session.updated and flushes on ready", async () => {
    const socket = new FakeTranscriptionSocket();
    const session = new OpenAIRealtimeTranscriptionSession({
      streamId: "stream-1",
      oauthLoader: fakeAuthLoader(),
      webSocketFactory: () => socket as any,
    });
    await session.start();
    await settle();

    session.appendAudio("EARLY1");
    session.appendAudio("EARLY2");

    // session.update sent but no appends yet.
    expect(socket.sent.filter((m) => m.type === "input_audio_buffer.append")).toHaveLength(0);

    socket.serverEvent({ type: "session.updated" });
    await settle();

    const appends = socket.sent.filter((m) => m.type === "input_audio_buffer.append");
    expect(appends.map((a) => a.audio)).toEqual(["EARLY1", "EARLY2"]);
  });

  it("commits the buffer and emits delta + completed", async () => {
    const socket = new FakeTranscriptionSocket();
    const events: TranscriptionStreamEvent[] = [];
    const session = new OpenAIRealtimeTranscriptionSession({
      streamId: "stream-1",
      oauthLoader: fakeAuthLoader(),
      webSocketFactory: () => socket as any,
    });
    session.on("event", (event) => events.push(event));
    await session.start();
    await settle();
    socket.serverEvent({ type: "session.updated" });
    await settle();

    session.appendAudio("AAAA");
    session.commit();

    expect(socket.sent.some((m) => m.type === "input_audio_buffer.commit")).toBe(true);

    socket.serverEvent({ type: "conversation.item.input_audio_transcription.delta", delta: "안녕" });
    socket.serverEvent({ type: "conversation.item.input_audio_transcription.delta", delta: "하세요" });
    socket.serverEvent({ type: "conversation.item.input_audio_transcription.completed", transcript: "안녕하세요." });
    await settle();

    expect(events).toContainEqual({ type: "delta", delta: "안녕" });
    expect(events).toContainEqual({ type: "delta", delta: "하세요" });
    expect(events).toContainEqual({ type: "completed", transcript: "안녕하세요." });
  });

  it("deferred commit fires once session.updated arrives", async () => {
    const socket = new FakeTranscriptionSocket();
    const session = new OpenAIRealtimeTranscriptionSession({
      streamId: "stream-1",
      oauthLoader: fakeAuthLoader(),
      webSocketFactory: () => socket as any,
    });
    await session.start();
    await settle();

    session.appendAudio("EARLY");
    session.commit();

    // Before session.updated: no commit on the wire yet.
    expect(socket.sent.some((m) => m.type === "input_audio_buffer.commit")).toBe(false);

    socket.serverEvent({ type: "session.updated" });
    await settle();

    expect(socket.sent.some((m) => m.type === "input_audio_buffer.commit")).toBe(true);
    // The buffered append should also have flushed.
    expect(socket.sent.some((m) => m.type === "input_audio_buffer.append" && m.audio === "EARLY")).toBe(true);
  });

  it("emits failed + closed on server error and stops accepting input", async () => {
    const socket = new FakeTranscriptionSocket();
    const events: TranscriptionStreamEvent[] = [];
    const session = new OpenAIRealtimeTranscriptionSession({
      streamId: "stream-1",
      oauthLoader: fakeAuthLoader(),
      webSocketFactory: () => socket as any,
    });
    session.on("event", (event) => events.push(event));
    await session.start();
    await settle();
    socket.serverEvent({ type: "session.updated" });
    await settle();

    socket.serverEvent({ type: "error", error: { message: "boom" } });
    await settle();

    expect(events.some((e) => e.type === "failed" && e.message === "boom")).toBe(true);
    expect(events).toContainEqual({ type: "closed" });
  });

  it("emits failed if oauth loader throws", async () => {
    const events: TranscriptionStreamEvent[] = [];
    const session = new OpenAIRealtimeTranscriptionSession({
      streamId: "stream-1",
      oauthLoader: async () => { throw new Error("No Codex OAuth token"); },
      webSocketFactory: () => { throw new Error("should not connect without auth"); },
    });
    session.on("event", (event) => events.push(event));

    await expect(session.start()).rejects.toThrow(/No Codex OAuth token/);
    expect(events.some((e) => e.type === "failed" && e.message.includes("No Codex OAuth token"))).toBe(true);
    expect(events).toContainEqual({ type: "closed" });
  });
});
