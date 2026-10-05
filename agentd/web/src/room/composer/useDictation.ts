/**
 * Phone dictation: record here, transcribe on the Mac, append to the draft.
 *
 * The Mac records and transcribes locally (`PickyComposerDictationController`).
 * The phone keeps the same contract the user sees: a second press stops and
 * sends the audio, the result is appended to the draft, and nothing is ever
 * sent on its own. The recording format is chosen so the Mac's `AVAudioFile`
 * can open it (../policy/recording.ts): AAC through MediaRecorder where the
 * browser offers it, 16 kHz WAV through Web Audio everywhere else.
 */
import { useCallback, useEffect, useRef, useState } from "preact/hooks";

import { REMOTE_LIMITS } from "../../../../src/remote/constants";
import type { RemoteDictationAvailability, RemoteDictationResponse } from "../../../../src/remote/protocol";
import { isWebKitEngine, planRecording, type RecordingPlan } from "../policy/recording";
import { WavRecorder } from "./wav-recorder";

export type DictationState =
  | { kind: "idle" }
  | { kind: "preparing" }
  | { kind: "listening"; startedAt: number }
  | { kind: "transcribing" }
  | { kind: "failed" }
  /** The browser denied the microphone. */
  | { kind: "permission" }
  /** The Mac cannot transcribe: permission or an unconfigured service. */
  | { kind: "macUnavailable"; reason: "macPermission" | "macService" | "macUnavailable" };

export interface Dictation {
  state: DictationState;
  /** Toggles: start recording, or stop and transcribe. */
  toggle: () => void;
  /** Drops the recording without touching the draft. */
  cancel: () => void;
}

export interface DictationOptions {
  availability: RemoteDictationAvailability;
  send: (audio: Blob) => Promise<RemoteDictationResponse>;
  onTranscript: (text: string) => void;
}

/** One running recording, whichever API produces it. */
interface Capture {
  /** Stops and hands the audio to `finish`. */
  stop(): void;
  /** Stops and throws the audio away. */
  discard(): void;
}

/** The cap the daemon enforces anyway; stopping here avoids a wasted upload. */
const MAX_SECONDS = REMOTE_LIMITS.dictationSeconds;

function currentPlan(): RecordingPlan {
  const recorder = typeof MediaRecorder === "undefined" ? undefined : MediaRecorder;
  return planRecording({
    isTypeSupported: recorder ? (type) => recorder.isTypeSupported(type) : undefined,
    webKitEngine: isWebKitEngine(navigator.userAgent),
  });
}

function createWavRecorder(): WavRecorder | undefined {
  try {
    return new WavRecorder();
  } catch {
    return undefined;
  }
}

/** Starts the first MediaRecorder type this browser constructs; undefined when none does. */
function startMediaRecorder(stream: MediaStream, mimeTypes: string[], finish: (audio: Blob) => void): Capture | undefined {
  for (const mimeType of mimeTypes) {
    let recorder: MediaRecorder;
    try {
      recorder = new MediaRecorder(stream, { mimeType });
    } catch {
      continue;
    }
    const chunks: Blob[] = [];
    let discarded = false;
    recorder.ondataavailable = (event: BlobEvent) => {
      if (event.data.size > 0) chunks.push(event.data);
    };
    recorder.onstop = () => {
      if (!discarded) finish(new Blob(chunks, { type: recorder.mimeType || mimeType }));
    };
    recorder.start();
    return {
      stop: () => {
        if (recorder.state === "recording") recorder.stop();
      },
      discard: () => {
        discarded = true;
        if (recorder.state === "recording") recorder.stop();
      },
    };
  }
  return undefined;
}

function startWav(wav: WavRecorder, stream: MediaStream, finish: (audio: Blob) => void): Capture | undefined {
  try {
    wav.start(stream);
  } catch {
    wav.discard();
    return undefined;
  }
  return { stop: () => finish(wav.stop()), discard: () => wav.discard() };
}

export function useDictation({ availability, send, onTranscript }: DictationOptions): Dictation {
  const [state, setState] = useState<DictationState>({ kind: "idle" });
  const captureRef = useRef<Capture | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const timerRef = useRef<number | null>(null);

  const release = useCallback(() => {
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
    captureRef.current = null;
    if (timerRef.current !== null) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  useEffect(() => () => {
    captureRef.current?.discard();
    release();
  }, [release]);

  const finish = useCallback((audio: Blob) => {
    release();
    if (audio.size === 0 || audio.size > REMOTE_LIMITS.dictationBytes) {
      setState({ kind: "failed" });
      return;
    }
    setState({ kind: "transcribing" });
    void send(audio).then((response) => {
      if (response.ok) {
        onTranscript(response.text);
        setState({ kind: "idle" });
        return;
      }
      if (response.reason === "macPermission" || response.reason === "macService" || response.reason === "macUnavailable") {
        setState({ kind: "macUnavailable", reason: response.reason });
        return;
      }
      setState({ kind: "failed" });
    });
  }, [onTranscript, release, send]);

  const start = useCallback(async () => {
    // Checking the Mac first means a refused recording never costs the user audio.
    if (!availability.available) {
      setState({ kind: "macUnavailable", reason: availability.reason });
      return;
    }
    setState({ kind: "preparing" });
    const plan = currentPlan();
    // Created before the await so Safari treats it as part of the tap.
    let wav = plan.kind === "wav" ? createWavRecorder() : undefined;
    let stream: MediaStream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch {
      wav?.discard();
      setState({ kind: "permission" });
      return;
    }
    streamRef.current = stream;
    let capture = plan.kind === "mediaRecorder" ? startMediaRecorder(stream, plan.mimeTypes, finish) : undefined;
    if (!capture) {
      wav ??= createWavRecorder();
      capture = wav ? startWav(wav, stream, finish) : undefined;
    }
    if (!capture) {
      release();
      setState({ kind: "failed" });
      return;
    }
    captureRef.current = capture;
    setState({ kind: "listening", startedAt: Date.now() });
    timerRef.current = window.setTimeout(() => captureRef.current?.stop(), MAX_SECONDS * 1000);
  }, [availability, finish, release]);

  const toggle = useCallback(() => {
    if (state.kind === "listening") {
      captureRef.current?.stop();
      return;
    }
    if (state.kind === "preparing" || state.kind === "transcribing") return;
    void start();
  }, [start, state.kind]);

  const cancel = useCallback(() => {
    captureRef.current?.discard();
    release();
    setState({ kind: "idle" });
  }, [release]);

  return { state, toggle, cancel };
}
