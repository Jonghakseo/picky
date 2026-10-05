import { describe, expect, it } from "vitest";
import { AAC_MIME, WEBKIT_MP4_MIME, downsample, encodeWav, isWebKitEngine, planRecording } from "./recording";

const supports = (...types: string[]) => (type: string) => types.includes(type);

describe("planRecording picks a format the Mac can decode", () => {
  it("records AAC when Chromium offers it, never its Opus default", () => {
    const chrome = supports("audio/webm;codecs=opus", "audio/mp4", AAC_MIME);
    expect(planRecording({ isTypeSupported: chrome, webKitEngine: false })).toEqual({ kind: "mediaRecorder", mimeTypes: [AAC_MIME] });
  });

  it("does not trust plain audio/mp4 outside WebKit, because Chromium puts Opus in it", () => {
    const opusOnlyMp4 = supports("audio/webm;codecs=opus", "audio/mp4");
    expect(planRecording({ isTypeSupported: opusOnlyMp4, webKitEngine: false })).toEqual({ kind: "wav" });
  });

  it("falls back to plain audio/mp4 on WebKit, where it is AAC", () => {
    expect(planRecording({ isTypeSupported: supports(WEBKIT_MP4_MIME), webKitEngine: true }))
      .toEqual({ kind: "mediaRecorder", mimeTypes: [WEBKIT_MP4_MIME] });
    expect(planRecording({ isTypeSupported: supports(AAC_MIME, WEBKIT_MP4_MIME), webKitEngine: true }))
      .toEqual({ kind: "mediaRecorder", mimeTypes: [AAC_MIME, WEBKIT_MP4_MIME] });
  });

  it("records WAV where only WebM/Ogg exist or MediaRecorder is missing", () => {
    expect(planRecording({ isTypeSupported: supports("audio/webm", "audio/ogg;codecs=opus"), webKitEngine: false })).toEqual({ kind: "wav" });
    expect(planRecording({ webKitEngine: false })).toEqual({ kind: "wav" });
    expect(planRecording({ isTypeSupported: () => { throw new Error("broken"); }, webKitEngine: true })).toEqual({ kind: "wav" });
  });
});

describe("isWebKitEngine", () => {
  it("tells WebKit from Chromium", () => {
    expect(isWebKitEngine("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1")).toBe(true);
    expect(isWebKitEngine("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/130.0 Mobile/15E148 Safari/604.1")).toBe(true);
    expect(isWebKitEngine("Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Mobile Safari/537.36")).toBe(false);
    expect(isWebKitEngine("Mozilla/5.0 (Android 15; Mobile; rv:140.0) Gecko/140.0 Firefox/140.0")).toBe(false);
  });
});

describe("encodeWav", () => {
  it("writes a 16-bit mono PCM RIFF header and clamps samples", () => {
    const bytes = encodeWav(new Float32Array([0, 1.5, -1.5, 0.5]), 16_000);
    const view = new DataView(bytes.buffer);
    const ascii = (offset: number) => String.fromCharCode(...bytes.slice(offset, offset + 4));
    expect([ascii(0), ascii(8), ascii(12), ascii(36)]).toEqual(["RIFF", "WAVE", "fmt ", "data"]);
    expect(view.getUint32(4, true)).toBe(36 + 8);
    expect(view.getUint16(20, true)).toBe(1);
    expect(view.getUint16(22, true)).toBe(1);
    expect(view.getUint32(24, true)).toBe(16_000);
    expect(view.getUint32(28, true)).toBe(32_000);
    expect(view.getUint16(34, true)).toBe(16);
    expect(view.getUint32(40, true)).toBe(8);
    expect([view.getInt16(44, true), view.getInt16(46, true), view.getInt16(48, true)]).toEqual([0, 32767, -32768]);
    expect(bytes.length).toBe(44 + 8);
  });
});

describe("downsample", () => {
  it("shrinks 48 kHz to 16 kHz and keeps a constant level", () => {
    const output = downsample(new Float32Array(48_000).fill(0.25), 48_000, 16_000);
    expect(output.length).toBe(16_000);
    expect(Math.abs(output[100] - 0.25)).toBeLessThan(1e-6);
  });

  it("handles 44.1 kHz and leaves lower rates alone", () => {
    expect(downsample(new Float32Array(44_100), 44_100, 16_000).length).toBe(16_000);
    expect(downsample(new Float32Array(10), 8_000, 16_000).length).toBe(10);
  });
});
