import { execFileSync } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import { Readable } from "node:stream";
import { MsEdgeTTS } from "msedge-tts";
import { describe, expect, it } from "vitest";
import { EDGE_TTS_MAX_INPUT_CHARACTERS, EdgeTTSService, EdgeTTSServiceError, escapeSSMLText, type EdgeTTSClient } from "./edge-tts-service.js";

function client(overrides: Partial<EdgeTTSClient> = {}): EdgeTTSClient {
  return {
    getVoices: async () => [],
    setMetadata: async () => {},
    toStream: () => ({ audioStream: Readable.from([Buffer.from("mp3")]) }),
    close: () => {},
    ...overrides,
  };
}

describe("patched msedge-tts", () => {
  it("ignores late WebSocket frames after a canceled request removes its streams", () => {
    const tts = new MsEdgeTTS() as unknown as {
      _pushAudioData: (data: Buffer, requestId: string) => void;
      _pushMetadata: (data: Buffer, requestId: string) => void;
    };

    expect(() => tts._pushAudioData(Buffer.from("late audio"), "canceled-request")).not.toThrow();
    expect(() => tts._pushMetadata(Buffer.from("late metadata"), "canceled-request")).not.toThrow();
  });

  it("rejects synchronous and callback WebSocket send failures", async () => {
    const tts = new MsEdgeTTS() as unknown as {
      _ws: { readyState: number; OPEN: number; send: (message: string, callback: (error?: Error) => void) => void };
      _send: (request: string) => Promise<void>;
    };

    const callbackError = new Error("callback send failed");
    tts._ws = {
      readyState: 1,
      OPEN: 1,
      send: (_message, callback) => callback(callbackError),
    };
    await expect(tts._send("speech.config")).rejects.toBe(callbackError);

    const synchronousError = new Error("synchronous send failed");
    tts._ws = {
      readyState: 1,
      OPEN: 1,
      send: () => { throw synchronousError; },
    };
    await expect(tts._send("speech.config")).rejects.toBe(synchronousError);
  });

  it("rejects initial speech.config send failure without terminating a strict-rejection process", () => {
    const agentdDirectory = fileURLToPath(new URL(".", import.meta.url));
    const script = String.raw`
      const assert = require("node:assert/strict");
      const path = require("node:path");
      const packageEntry = require.resolve("msedge-tts");
      const websocketEntry = require.resolve("isomorphic-ws", { paths: [path.dirname(packageEntry)] });
      class FailingWebSocket {
        static OPEN = 1;
        constructor() {
          this.OPEN = 1;
          this.readyState = 1;
          queueMicrotask(() => this.onopen());
        }
        send(_message, callback) { callback(new Error("initial speech.config send failed")); }
      }
      require(websocketEntry);
      require.cache[websocketEntry].exports = FailingWebSocket;
      const { MsEdgeTTS } = require("msedge-tts");
      MsEdgeTTS.getSynthUrl = async () => "ws://127.0.0.1/edge-tts-test";
      (async () => {
        const tts = new MsEdgeTTS();
        await assert.rejects(tts._initClient(), /initial speech.config send failed/);
        process.stdout.write("initial-config-rejection-contained\\n");
      })().catch((error) => { console.error(error); process.exitCode = 1; });
    `;

    const output = execFileSync(process.execPath, ["--unhandled-rejections=strict", "-e", script], {
      cwd: agentdDirectory,
      encoding: "utf8",
    });
    expect(output).toContain("initial-config-rejection-contained");
  });

  it("turns a raw SSML send rejection into an audio stream error without an unhandled rejection", async () => {
    const tts = new MsEdgeTTS() as unknown as {
      _ws: object;
      _voice: string;
      _metadataOptions: { voiceLocale: string };
      _send: (request: string) => Promise<void>;
      toStream: (input: string) => { audioStream: Readable };
    };
    const sendError = new Error("send failed");
    const unhandled: unknown[] = [];
    const onUnhandled = (error: unknown) => unhandled.push(error);
    process.on("unhandledRejection", onUnhandled);
    try {
      // Set only the package's already-configured fields; no network client is created.
      tts._ws = {};
      tts._voice = "en-US-AriaNeural";
      tts._metadataOptions.voiceLocale = "en-US";
      tts._send = async () => { throw sendError; };

      const { audioStream } = tts.toStream("hello");
      const [streamError] = await once(audioStream, "error");
      expect(streamError).toBe(sendError);
      await new Promise((resolve) => setTimeout(resolve, 10));
      expect(unhandled).toEqual([]);
    } finally {
      process.removeListener("unhandledRejection", onUnhandled);
    }
  });
});

describe("EdgeTTSService", () => {
  it("escapes text before giving it to the package SSML template", async () => {
    let streamedInput: string | undefined;
    const service = new EdgeTTSService(() => client({
      toStream: (input) => {
        streamedInput = input;
        return { audioStream: Readable.from([Buffer.from("audio")]) };
      },
    }));

    await expect(service.synthesize("A < B & C's \"quote\"", "ko-KR-SunHiNeural")).resolves.toEqual(Buffer.from("audio"));
    expect(streamedInput).toBe("A &lt; B &amp; C&apos;s &quot;quote&quot;");
  });

  it("uses the required MP3 output format and aggregates stream chunks", async () => {
    let selectedFormat: unknown;
    const service = new EdgeTTSService(() => client({
      setMetadata: async (_voice, outputFormat) => { selectedFormat = outputFormat; },
      toStream: () => ({ audioStream: Readable.from([Buffer.from("first"), Buffer.from("-second")]) }),
    }));

    await expect(service.synthesize("hello", "en-US-AriaNeural")).resolves.toEqual(Buffer.from("first-second"));
    expect(selectedFormat).toBe("audio-24khz-48kbitrate-mono-mp3");
  });

  it("sorts voice catalog by locale then friendly name", async () => {
    const service = new EdgeTTSService(() => client({
      getVoices: async () => [
        { ShortName: "en-US-ZoeNeural", Locale: "en-US", Gender: "Female", FriendlyName: "Zoe", Name: "", SuggestedCodec: "", Status: "" },
        { ShortName: "ko-KR-SunHiNeural", Locale: "ko-KR", Gender: "Female", FriendlyName: "SunHi", Name: "", SuggestedCodec: "", Status: "" },
        { ShortName: "en-US-AriaNeural", Locale: "en-US", Gender: "Female", FriendlyName: "Aria", Name: "", SuggestedCodec: "", Status: "" },
      ],
    }));

    await expect(service.listVoices()).resolves.toMatchObject([
      { shortName: "en-US-AriaNeural" },
      { shortName: "en-US-ZoeNeural" },
      { shortName: "ko-KR-SunHiNeural" },
    ]);
  });

  it("rejects empty, oversized, and invalid voice input without opening a client", async () => {
    let created = 0;
    const service = new EdgeTTSService(() => {
      created += 1;
      return client();
    });

    await expect(service.synthesize(" ", "ko-KR-SunHiNeural")).rejects.toMatchObject({ statusCode: 400 });
    await expect(service.synthesize("a".repeat(EDGE_TTS_MAX_INPUT_CHARACTERS + 1), "ko-KR-SunHiNeural")).rejects.toMatchObject({ statusCode: 413 });
    await expect(service.synthesize("hello", "<invalid>")).rejects.toMatchObject({ statusCode: 400 });
    expect(created).toBe(0);
  });

  it("rejects empty and truncated audio while closing the client", async () => {
    let closed = 0;
    const empty = new EdgeTTSService(() => client({
      toStream: () => ({ audioStream: Readable.from([]) }),
      close: () => { closed += 1; },
    }));
    await expect(empty.synthesize("hello", "en-US-AriaNeural")).rejects.toBeInstanceOf(EdgeTTSServiceError);

    const truncated = new EdgeTTSService(() => client({
      toStream: () => {
        const stream = new Readable({ read() {} });
        queueMicrotask(() => stream.destroy());
        return { audioStream: stream };
      },
      close: () => { closed += 1; },
    }));
    await expect(truncated.synthesize("hello", "en-US-AriaNeural")).rejects.toMatchObject({ message: "Microsoft Edge returned truncated audio." });
    expect(closed).toBe(2);
  });

  it("bounds stalled Edge client setup and closes it", async () => {
    let closed = 0;
    const service = new EdgeTTSService(() => client({
      setMetadata: async () => await new Promise<void>(() => {}),
      close: () => { closed += 1; },
    }), 5);

    await expect(service.synthesize("hello", "en-US-AriaNeural")).rejects.toMatchObject({ statusCode: 504 });
    expect(closed).toBeGreaterThanOrEqual(1);
  });

  it("reuses one warm client across sequential requests and closes them on dispose", async () => {
    let created = 0;
    let closed = 0;
    let metadataCalls = 0;
    const service = new EdgeTTSService(() => {
      created += 1;
      return client({
        setMetadata: async () => { metadataCalls += 1; },
        toStream: () => ({ audioStream: Readable.from([Buffer.from("mp3")]) }),
        close: () => { closed += 1; },
      });
    });

    await service.synthesize("one", "ko-KR-SunHiNeural");
    await service.synthesize("two", "ko-KR-SunHiNeural");
    await service.synthesize("three", "ko-KR-SunHiNeural");

    // One connection served all three sequential requests, and setMetadata ran
    // once (real msedge-tts throws on a 2nd metadata call without options).
    expect(created).toBe(1);
    expect(metadataCalls).toBe(1);
    expect(closed).toBe(0);

    service.dispose();
    expect(closed).toBe(1);
  });

  it("opens a second client only for overlapping concurrent requests", async () => {
    let created = 0;
    const release: Array<() => void> = [];
    const service = new EdgeTTSService(() => {
      created += 1;
      return client({
        toStream: () => {
          const stream = new Readable({ read() {} });
          release.push(() => { stream.push(Buffer.from("mp3")); stream.push(null); });
          return { audioStream: stream };
        },
      });
    });

    const first = service.synthesize("a", "ko-KR-SunHiNeural");
    const second = service.synthesize("b", "ko-KR-SunHiNeural");
    // Both are in flight before either stream ends, so they cannot share a client.
    await new Promise((resolve) => setTimeout(resolve, 0));
    release.forEach((fn) => fn());
    await Promise.all([first, second]);

    expect(created).toBe(2);
  });

  it("cancels the underlying stream and client", async () => {
    let closed = 0;
    const controller = new AbortController();
    const service = new EdgeTTSService(() => client({
      toStream: () => ({ audioStream: new Readable({ read() {} }) }),
      close: () => { closed += 1; },
    }));
    const result = service.synthesize("hello", "en-US-AriaNeural", controller.signal);
    controller.abort();

    await expect(result).rejects.toMatchObject({ statusCode: 499 });
    expect(closed).toBeGreaterThanOrEqual(1);
  });
});

describe("escapeSSMLText", () => {
  it("escapes every XML-sensitive character", () => {
    expect(escapeSSMLText("<&>\"'")).toBe("&lt;&amp;&gt;&quot;&apos;");
  });
});
