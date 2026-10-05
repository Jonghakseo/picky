/**
 * Pairing. The Mac shows a QR (`<publicUrl>/#pair=<code>`) and the same code as
 * `XXXX-XXXX`; this screen takes either. On success the gateway sets the device
 * cookie and the app connects.
 */
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { JSX } from "preact";
import { t } from "../app/i18n";
import { formatPairingCode, isCompletePairingCode, normalizePairingCode } from "../app/pairing";
import type { PlatformFacts } from "../app/platform";
import type { ScannerHandle } from "../app/qr-scanner";
import type { Transport } from "../app/transport";
import { CameraIcon, PickleGlyph } from "../ui/icons";

/** Written out so the build's key scanner sees every string the screen can show. */
const PAIR_ERROR_KEY = {
  invalid: "remote.pair.error.invalid",
  expired: "remote.pair.error.expired",
  locked: "remote.pair.error.locked",
  macOffline: "remote.pair.error.macOffline",
  failed: "remote.pair.error.failed",
} as const;

export interface PairScreenProps {
  transport: Transport;
  platform: PlatformFacts;
  /** Code from `#pair=…`, already normalized. */
  initialCode?: string;
  onPaired(): void;
}

export function PairScreen({ transport, platform, initialCode, onPaired }: PairScreenProps): JSX.Element {
  const code = useSignal(initialCode ?? "");
  const deviceName = useSignal(platform.deviceName);
  const error = useSignal<string | undefined>(undefined);
  const busy = useSignal(false);
  const scanning = useSignal(false);
  const video = useRef<HTMLVideoElement>(null);
  const handle = useRef<ScannerHandle | undefined>(undefined);

  useEffect(() => () => handle.current?.stop(), []);

  async function submit(value: string): Promise<void> {
    if (busy.value || !isCompletePairingCode(value)) return;
    busy.value = true;
    error.value = undefined;
    const result = await transport.pair(normalizePairingCode(value), deviceName.value.trim() || platform.deviceName);
    busy.value = false;
    if (result.ok) {
      onPaired();
      return;
    }
    error.value = t(PAIR_ERROR_KEY[result.reason]);
  }

  async function toggleScanner(): Promise<void> {
    if (scanning.value) {
      handle.current?.stop();
      handle.current = undefined;
      scanning.value = false;
      return;
    }
    scanning.value = true;
    error.value = undefined;
    const element = video.current;
    if (!element) return;
    // jsQR is about two thirds of the bundle and only pairing needs it, so the
    // decoder arrives in its own chunk the first time someone opens the camera.
    const { startScanner } = await import("../app/qr-scanner");
    if (!scanning.value) return;
    handle.current = await startScanner(element, {
      onCode: (scanned) => {
        scanning.value = false;
        code.value = scanned;
        void submit(scanned);
      },
      onFailure: (failure) => {
        scanning.value = false;
        error.value = t(failure === "denied" ? "remote.pair.camera.denied" : "remote.pair.camera.unavailable");
      },
    });
  }

  return (
    <div class="app-shell">
      <div class="app-topbar app-side-inset" />
      <div class="app-scroll app-side-inset">
        <div class="page">
          <span class="page-brand">
            <PickleGlyph class="avatar-glyph" />
          </span>
          <h1 class="page-title">{t("remote.pair.title")}</h1>
          <p class="page-body">{t("remote.pair.body")}</p>

          <div class="scanner">
            <video ref={video} playsInline muted style={scanning.value ? undefined : "display:none"} />
            {scanning.value ? (
              <div class="scanner-frame" />
            ) : (
              <div class="scanner-placeholder">
                <CameraIcon size={28} />
                <span>{t("remote.pair.scan.idle")}</span>
              </div>
            )}
          </div>

          <button class="secondary-button" type="button" onClick={() => void toggleScanner()}>
            {t(scanning.value ? "remote.pair.scan.stop" : "remote.pair.scan.start")}
          </button>

          <div class="field-group">
            <label class="field-label" for="pair-code">
              {t("remote.pair.code.label")}
            </label>
            <input
              id="pair-code"
              class="text-field code-field"
              type="text"
              inputMode="text"
              autoComplete="one-time-code"
              autoCapitalize="characters"
              autoCorrect="off"
              spellcheck={false}
              placeholder="XXXX-XXXX"
              value={formatPairingCode(code.value)}
              onInput={(event) => {
                code.value = normalizePairingCode((event.target as HTMLInputElement).value);
              }}
            />
          </div>

          <div class="field-group">
            <label class="field-label" for="pair-name">
              {t("remote.pair.deviceName.label")}
            </label>
            <input
              id="pair-name"
              class="text-field"
              type="text"
              maxLength={60}
              value={deviceName.value}
              onInput={(event) => {
                deviceName.value = (event.target as HTMLInputElement).value;
              }}
            />
          </div>

          {error.value && <div class="notice error">{error.value}</div>}

          <button class="primary-button" type="button" disabled={busy.value || !isCompletePairingCode(code.value)} onClick={() => void submit(code.value)}>
            {t(busy.value ? "remote.pair.connecting" : "remote.pair.submit")}
          </button>
        </div>
      </div>
    </div>
  );
}
