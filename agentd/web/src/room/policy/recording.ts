/**
 * How the phone records dictation so the Mac can decode it.
 *
 * The Mac transcribes with `AVAudioFile` (`PickyRemoteDictationTranscriber`),
 * which reads AAC in MP4 and WAV but neither container that Chromium picks on
 * its own: checked on an Android phone (Chrome 154), the default
 * `audio/webm;codecs=opus` and plain `audio/mp4` (Opus inside MP4) both fail
 * to open, while `audio/mp4;codecs=mp4a.40.2` (AAC) reads fine. WebKit records
 * AAC for plain `audio/mp4` but can refuse a strict codec string on iOS, so it
 * gets plain `audio/mp4` as a second choice. Anything else records PCM through
 * Web Audio and uploads 16 kHz mono WAV.
 */
export const AAC_MIME = "audio/mp4;codecs=mp4a.40.2";
export const WEBKIT_MP4_MIME = "audio/mp4";
export const WAV_SAMPLE_RATE = 16_000;

export type RecordingPlan =
  /** Try each MediaRecorder type in order; fall back to WAV if none constructs. */
  | { kind: "mediaRecorder"; mimeTypes: string[] }
  | { kind: "wav" };

export interface RecordingEnvironment {
  /** `MediaRecorder.isTypeSupported`, or undefined where MediaRecorder is missing. */
  isTypeSupported?: (type: string) => boolean;
  /** WebKit engine (Safari, and every browser on iOS), where MP4 audio is AAC. */
  webKitEngine: boolean;
}

export function planRecording(environment: RecordingEnvironment): RecordingPlan {
  const supported = environment.isTypeSupported;
  if (!supported) return { kind: "wav" };
  const mimeTypes: string[] = [];
  if (safe(() => supported(AAC_MIME))) mimeTypes.push(AAC_MIME);
  if (environment.webKitEngine && safe(() => supported(WEBKIT_MP4_MIME))) mimeTypes.push(WEBKIT_MP4_MIME);
  return mimeTypes.length > 0 ? { kind: "mediaRecorder", mimeTypes } : { kind: "wav" };
}

/** WebKit on macOS/iPadOS/iOS. Chromium and Firefox on iOS also run WebKit, so they count. */
export function isWebKitEngine(userAgent: string): boolean {
  if (/CriOS|FxiOS|EdgiOS/.test(userAgent)) return true;
  return /AppleWebKit/.test(userAgent) && !/Chrome\/|Chromium|Android/.test(userAgent);
}

function safe(check: () => boolean): boolean {
  try {
    return check();
  } catch {
    return false;
  }
}

/** Averages each output sample over its input window. Output length is ceil(n * to / from). */
export function downsample(input: Float32Array, fromRate: number, toRate: number): Float32Array {
  if (toRate >= fromRate) return input.slice();
  const ratio = fromRate / toRate;
  const length = Math.ceil(input.length / ratio);
  const output = new Float32Array(length);
  for (let index = 0; index < length; index += 1) {
    const start = Math.floor(index * ratio);
    const end = Math.min(input.length, Math.floor((index + 1) * ratio));
    let sum = 0;
    for (let cursor = start; cursor < end; cursor += 1) sum += input[cursor];
    output[index] = end > start ? sum / (end - start) : 0;
  }
  return output;
}

/** 16-bit PCM mono WAV (RIFF) for the given samples in [-1, 1]; out-of-range values are clamped. */
export function encodeWav(samples: Float32Array, sampleRate: number): Uint8Array<ArrayBuffer> {
  const dataBytes = samples.length * 2;
  const buffer = new ArrayBuffer(44 + dataBytes);
  const view = new DataView(buffer);
  const ascii = (offset: number, text: string) => {
    for (let index = 0; index < text.length; index += 1) view.setUint8(offset + index, text.charCodeAt(index));
  };
  ascii(0, "RIFF");
  view.setUint32(4, 36 + dataBytes, true);
  ascii(8, "WAVE");
  ascii(12, "fmt ");
  view.setUint32(16, 16, true); // fmt chunk size
  view.setUint16(20, 1, true); // PCM
  view.setUint16(22, 1, true); // mono
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true); // byte rate
  view.setUint16(32, 2, true); // block align
  view.setUint16(34, 16, true); // bits per sample
  ascii(36, "data");
  view.setUint32(40, dataBytes, true);
  for (let index = 0; index < samples.length; index += 1) {
    const clamped = Math.max(-1, Math.min(1, samples[index]));
    view.setInt16(44 + index * 2, clamped < 0 ? Math.round(clamped * 0x8000) : Math.round(clamped * 0x7fff), true);
  }
  return new Uint8Array(buffer);
}
