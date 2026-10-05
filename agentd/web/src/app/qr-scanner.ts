/**
 * In-app QR scanning for pairing. iOS only allows the camera inside the Home
 * Screen app over https, which is exactly where pairing has to happen anyway
 * (the Home Screen app keeps its own cookies, WWDC23 10120).
 */
import jsQR from "jsqr";
import { parsePairingPayload } from "./pairing";

export type ScannerFailure = "denied" | "unavailable";

export interface ScannerHandle {
  stop(): void;
}

export interface ScannerCallbacks {
  onCode(code: string): void;
  onFailure(failure: ScannerFailure): void;
}

/** Scans about five frames a second: enough for a code on a screen, cheap on battery. */
const SCAN_INTERVAL_MS = 200;

export async function startScanner(video: HTMLVideoElement, callbacks: ScannerCallbacks): Promise<ScannerHandle> {
  if (!navigator.mediaDevices?.getUserMedia) {
    callbacks.onFailure("unavailable");
    return { stop: () => {} };
  }
  let stream: MediaStream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: "environment" } }, audio: false });
  } catch (error) {
    const name = (error as { name?: string }).name;
    callbacks.onFailure(name === "NotAllowedError" || name === "SecurityError" ? "denied" : "unavailable");
    return { stop: () => {} };
  }

  video.srcObject = stream;
  video.setAttribute("playsinline", "");
  video.muted = true;
  try {
    await video.play();
  } catch {
    // Autoplay can be refused while the tab is backgrounded; the frame loop below just idles.
  }

  const canvas = document.createElement("canvas");
  const context = canvas.getContext("2d", { willReadFrequently: true });
  let timer: ReturnType<typeof setInterval> | undefined;
  let stopped = false;

  const stop = () => {
    if (stopped) return;
    stopped = true;
    if (timer) clearInterval(timer);
    for (const track of stream.getTracks()) track.stop();
    video.srcObject = null;
  };

  if (!context) {
    stop();
    callbacks.onFailure("unavailable");
    return { stop: () => {} };
  }

  timer = setInterval(() => {
    if (stopped || video.readyState < video.HAVE_CURRENT_DATA) return;
    const width = video.videoWidth;
    const height = video.videoHeight;
    if (width === 0 || height === 0) return;
    // Downscale: a QR fills a good part of the frame, and jsQR on a 640px wide
    // image keeps each scan well under a frame budget.
    const scale = Math.min(1, 640 / width);
    canvas.width = Math.round(width * scale);
    canvas.height = Math.round(height * scale);
    context.drawImage(video, 0, 0, canvas.width, canvas.height);
    const image = context.getImageData(0, 0, canvas.width, canvas.height);
    const found = jsQR(image.data, image.width, image.height, { inversionAttempts: "dontInvert" });
    if (!found) return;
    const code = parsePairingPayload(found.data);
    if (!code) return;
    stop();
    callbacks.onCode(code);
  }, SCAN_INTERVAL_MS);

  return { stop };
}
