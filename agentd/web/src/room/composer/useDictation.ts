/**
 * Phone dictation: record here, transcribe on the Mac, append to the draft.
 *
 * The Mac records and transcribes locally (`PickyComposerDictationController`).
 * The phone keeps the same contract the user sees, with the recording moved to
 * MediaRecorder: a second press stops and sends the audio, the result is
 * appended to the draft, and nothing is ever sent on its own.
 */
import { useCallback, useEffect, useRef, useState } from "preact/hooks";

import { REMOTE_LIMITS } from "../../../../src/remote/constants";
import type { RemoteDictationAvailability, RemoteDictationResponse } from "../../../../src/remote/protocol";

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

/** The cap the daemon enforces anyway; stopping here avoids a wasted upload. */
const MAX_SECONDS = REMOTE_LIMITS.dictationSeconds;

export function useDictation({ availability, send, onTranscript }: DictationOptions): Dictation {
  const [state, setState] = useState<DictationState>({ kind: "idle" });
  const recorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const cancelledRef = useRef(false);
  const timerRef = useRef<number | null>(null);

  const stopTracks = useCallback(() => {
    const recorder = recorderRef.current;
    recorder?.stream.getTracks().forEach((track) => track.stop());
    recorderRef.current = null;
    if (timerRef.current !== null) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  useEffect(() => stopTracks, [stopTracks]);

  const start = useCallback(async () => {
    // Checking the Mac first means a refused recording never costs the user audio.
    if (!availability.available) {
      setState({ kind: "macUnavailable", reason: availability.reason });
      return;
    }
    setState({ kind: "preparing" });
    let stream: MediaStream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch {
      setState({ kind: "permission" });
      return;
    }
    let recorder: MediaRecorder;
    try {
      recorder = new MediaRecorder(stream);
    } catch {
      stream.getTracks().forEach((track) => track.stop());
      setState({ kind: "failed" });
      return;
    }
    chunksRef.current = [];
    cancelledRef.current = false;
    recorder.ondataavailable = (event: BlobEvent) => {
      if (event.data.size > 0) chunksRef.current.push(event.data);
    };
    recorder.onstop = () => {
      const chunks = chunksRef.current;
      chunksRef.current = [];
      stopTracks();
      if (cancelledRef.current) {
        setState({ kind: "idle" });
        return;
      }
      const audio = new Blob(chunks, { type: recorder.mimeType || "audio/webm" });
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
    };
    recorderRef.current = recorder;
    recorder.start();
    setState({ kind: "listening", startedAt: Date.now() });
    timerRef.current = window.setTimeout(() => {
      if (recorderRef.current?.state === "recording") recorderRef.current.stop();
    }, MAX_SECONDS * 1000);
  }, [availability, onTranscript, send, stopTracks]);

  const toggle = useCallback(() => {
    if (state.kind === "listening") {
      recorderRef.current?.stop();
      return;
    }
    if (state.kind === "preparing" || state.kind === "transcribing") return;
    void start();
  }, [start, state.kind]);

  const cancel = useCallback(() => {
    cancelledRef.current = true;
    if (recorderRef.current?.state === "recording") {
      recorderRef.current.stop();
      return;
    }
    stopTracks();
    setState({ kind: "idle" });
  }, [stopTracks]);

  return { state, toggle, cancel };
}
