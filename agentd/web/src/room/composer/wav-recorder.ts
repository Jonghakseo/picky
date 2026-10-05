/**
 * Web Audio fallback for browsers whose MediaRecorder cannot produce AAC
 * (see ../policy/recording.ts). Captures mono PCM with a ScriptProcessorNode,
 * which every target browser still runs, and returns 16 kHz WAV on stop.
 *
 * Create it synchronously inside the tap handler, before any await: Safari
 * only lets an AudioContext run when it is created during a user gesture.
 */
import { WAV_SAMPLE_RATE, downsample, encodeWav } from "../policy/recording";

export class WavRecorder {
  private readonly context: AudioContext;
  private chunks: Float32Array[] = [];
  private source?: MediaStreamAudioSourceNode;
  private processor?: ScriptProcessorNode;

  constructor() {
    const AudioContextClass = window.AudioContext ?? (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    this.context = new AudioContextClass();
    void this.context.resume();
  }

  start(stream: MediaStream): void {
    this.source = this.context.createMediaStreamSource(stream);
    this.processor = this.context.createScriptProcessor(4096, 1, 1);
    this.processor.onaudioprocess = (event) => {
      this.chunks.push(new Float32Array(event.inputBuffer.getChannelData(0)));
    };
    this.source.connect(this.processor);
    // A processor that is not connected to the destination never runs in Chromium.
    this.processor.connect(this.context.destination);
  }

  /** Stops capturing and returns the recording, or an empty blob when nothing was captured. */
  stop(): Blob {
    this.processor?.disconnect();
    this.source?.disconnect();
    if (this.processor) this.processor.onaudioprocess = null;
    const sampleRate = this.context.sampleRate;
    void this.context.close();
    const total = this.chunks.reduce((sum, chunk) => sum + chunk.length, 0);
    if (total === 0) return new Blob([], { type: "audio/wav" });
    const samples = new Float32Array(total);
    let offset = 0;
    for (const chunk of this.chunks) {
      samples.set(chunk, offset);
      offset += chunk.length;
    }
    this.chunks = [];
    const bytes = encodeWav(downsample(samples, sampleRate, WAV_SAMPLE_RATE), Math.min(sampleRate, WAV_SAMPLE_RATE));
    return new Blob([bytes], { type: "audio/wav" });
  }

  /** Drops the recording. */
  discard(): void {
    this.chunks = [];
    this.processor?.disconnect();
    this.source?.disconnect();
    void this.context.close();
  }
}
