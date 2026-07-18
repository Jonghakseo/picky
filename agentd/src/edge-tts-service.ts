import { MsEdgeTTS, OUTPUT_FORMAT, type Voice } from "msedge-tts";
import type { Readable } from "node:stream";

export const EDGE_TTS_MAX_INPUT_CHARACTERS = 5_000;
export const EDGE_TTS_TIMEOUT_MS = 30_000;

export interface EdgeTTSVoice {
  shortName: string;
  locale: string;
  gender: string;
  friendlyName: string;
}

interface EdgeTTSStreamResult {
  audioStream: Readable;
}

interface PooledClient {
  client: EdgeTTSClient;
  voice: string;
  busy: boolean;
  configured: boolean;
}

export interface EdgeTTSClient {
  getVoices(): Promise<Voice[]>;
  setMetadata(voiceName: string, outputFormat: OUTPUT_FORMAT): Promise<void>;
  toStream(input: string): EdgeTTSStreamResult;
  close(): void;
}

export class EdgeTTSServiceError extends Error {
  constructor(
    message: string,
    readonly statusCode = 502,
  ) {
    super(message);
    this.name = "EdgeTTSServiceError";
  }
}

/**
 * Isolates the unofficial Microsoft Edge Read Aloud client from HTTP routing.
 * Text is escaped before passing it to msedge-tts because that package injects
 * its input into an SSML template verbatim.
 */
export class EdgeTTSService {
  // Warm connections reused across requests. Each Edge synth otherwise pays a
  // ~200ms WS handshake + metadata round-trip (measured), which dominates the
  // ~330ms total for short sentences.
  private readonly pool: PooledClient[] = [];

  constructor(
    private readonly createClient: () => EdgeTTSClient = () => new MsEdgeTTS(),
    private readonly timeoutMs = EDGE_TTS_TIMEOUT_MS,
    private readonly maxPoolSize = 4,
  ) {}

  async listVoices(): Promise<EdgeTTSVoice[]> {
    const client = this.createClient();
    try {
      const voices = await withClientTimeout(client.getVoices(), client, this.timeoutMs);
      return voices
        .map((voice) => ({
          shortName: voice.ShortName,
          locale: voice.Locale,
          gender: voice.Gender,
          friendlyName: voice.FriendlyName,
        }))
        .filter((voice) => voice.shortName && voice.locale)
        .sort((left, right) => left.locale.localeCompare(right.locale) || left.friendlyName.localeCompare(right.friendlyName));
    } catch (error) {
      throw serviceError("Unable to list Microsoft Edge voices.", error);
    } finally {
      client.close();
    }
  }

  async synthesize(input: string, voice: string, signal?: AbortSignal): Promise<Buffer> {
    const text = validatedInput(input);
    const voiceName = validatedVoice(voice);
    const pooled = this.acquire(voiceName);

    try {
      // Configure (and open the WS) only once per pooled client. msedge-tts'
      // setMetadata throws if called again without its 3rd options arg, and a
      // reused OPEN socket needs no reconfiguration, so we skip it on reuse —
      // which also drops the metadata round-trip from every subsequent request.
      if (!pooled.configured) {
        await withClientTimeout(
          pooled.client.setMetadata(voiceName, OUTPUT_FORMAT.AUDIO_24KHZ_48KBITRATE_MONO_MP3),
          pooled.client,
          this.timeoutMs,
          signal,
        );
        pooled.configured = true;
      }
      const { audioStream } = pooled.client.toStream(escapeSSMLText(text));
      const audio = await collectAudio(audioStream, pooled.client, this.timeoutMs, signal, { closeClientOnError: false });
      this.release(pooled);
      return audio;
    } catch (error) {
      // A failed/aborted request may have left the socket in a bad state, so
      // evict this client instead of returning it to the pool.
      this.discard(pooled);
      if (error instanceof EdgeTTSServiceError) throw error;
      throw serviceError("Microsoft Edge speech synthesis failed.", error);
    }
  }

  /** Close every pooled connection. Call on daemon shutdown. */
  dispose(): void {
    for (const pooled of this.pool.splice(0)) {
      try { pooled.client.close(); } catch { /* best effort */ }
    }
  }

  private acquire(voice: string): PooledClient {
    const idle = this.pool.find((entry) => !entry.busy && entry.voice === voice);
    if (idle) {
      idle.busy = true;
      return idle;
    }
    const pooled: PooledClient = { client: this.createClient(), voice, busy: true, configured: false };
    this.pool.push(pooled);
    return pooled;
  }

  private release(pooled: PooledClient): void {
    pooled.busy = false;
    // Bound the pool: close and drop the oldest idle clients beyond the cap so
    // bursts of concurrent requests do not leak connections.
    const idle = this.pool.filter((entry) => !entry.busy);
    while (idle.length > this.maxPoolSize) {
      const victim = idle.shift()!;
      this.discard(victim);
    }
  }

  private discard(pooled: PooledClient): void {
    const index = this.pool.indexOf(pooled);
    if (index >= 0) this.pool.splice(index, 1);
    try { pooled.client.close(); } catch { /* best effort */ }
  }
}

export function escapeSSMLText(input: string): string {
  return input
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;")
    .replaceAll("'", "&apos;");
}

function validatedInput(input: string): string {
  const text = input.trim();
  if (!text) throw new EdgeTTSServiceError("Speech input must not be empty.", 400);
  if (text.length > EDGE_TTS_MAX_INPUT_CHARACTERS) {
    throw new EdgeTTSServiceError(`Speech input must not exceed ${EDGE_TTS_MAX_INPUT_CHARACTERS} characters.`, 413);
  }
  return text;
}

function validatedVoice(voice: string): string {
  const value = voice.trim();
  if (!/^[A-Za-z0-9-]{1,128}$/.test(value)) {
    throw new EdgeTTSServiceError("Voice must be a valid Microsoft Edge voice name.", 400);
  }
  return value;
}

function withClientTimeout<T>(operation: Promise<T>, client: EdgeTTSClient, timeoutMs: number, signal?: AbortSignal): Promise<T> {
  return new Promise((resolve, reject) => {
    let settled = false;
    const settle = (result: { value?: T; error?: EdgeTTSServiceError }) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      if (result.error) reject(result.error);
      else resolve(result.value!);
    };
    const onAbort = () => {
      client.close();
      settle({ error: new EdgeTTSServiceError("Microsoft Edge speech synthesis was cancelled.", 499) });
    };
    const timer = setTimeout(() => {
      client.close();
      settle({ error: new EdgeTTSServiceError("Microsoft Edge speech synthesis timed out.", 504) });
    }, timeoutMs);
    if (signal?.aborted) {
      onAbort();
      return;
    }
    signal?.addEventListener("abort", onAbort, { once: true });
    operation.then(
      (value) => settle({ value }),
      () => settle({ error: new EdgeTTSServiceError("Microsoft Edge speech synthesis failed.") }),
    );
  });
}

function collectAudio(
  stream: Readable,
  client: EdgeTTSClient,
  timeoutMs: number,
  signal?: AbortSignal,
  options: { closeClientOnError?: boolean } = {},
): Promise<Buffer> {
  const closeClientOnError = options.closeClientOnError ?? true;
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let settled = false;
    let ended = false;

    const settle = (result: { audio?: Buffer; error?: EdgeTTSServiceError }) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      stream.removeAllListeners("data");
      stream.removeAllListeners("end");
      stream.removeAllListeners("error");
      stream.removeAllListeners("close");
      if (result.error) reject(result.error);
      else resolve(result.audio!);
    };

    const abort = (message: string, statusCode = 502) => {
      // When pooled, the caller (synthesize) decides whether to evict the
      // client; closing it here would kill a connection we want to reuse.
      if (closeClientOnError) client.close();
      stream.destroy();
      settle({ error: new EdgeTTSServiceError(message, statusCode) });
    };
    const onAbort = () => abort("Microsoft Edge speech synthesis was cancelled.", 499);
    const timer = setTimeout(() => abort("Microsoft Edge speech synthesis timed out.", 504), timeoutMs);

    if (signal?.aborted) {
      onAbort();
      return;
    }
    signal?.addEventListener("abort", onAbort, { once: true });
    stream.on("data", (chunk: Buffer | Uint8Array | string) => chunks.push(Buffer.from(chunk)));
    stream.once("error", () => settle({ error: new EdgeTTSServiceError("Microsoft Edge speech synthesis failed.") }));
    stream.once("end", () => {
      ended = true;
      const audio = Buffer.concat(chunks);
      if (audio.length === 0) {
        settle({ error: new EdgeTTSServiceError("Microsoft Edge returned empty audio.") });
      } else {
        settle({ audio });
      }
    });
    stream.once("close", () => {
      if (!ended) settle({ error: new EdgeTTSServiceError("Microsoft Edge returned truncated audio.") });
    });
  });
}

function serviceError(message: string, error: unknown): EdgeTTSServiceError {
  if (error instanceof EdgeTTSServiceError) return error;
  return new EdgeTTSServiceError(message);
}
