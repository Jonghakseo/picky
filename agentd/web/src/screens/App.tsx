/**
 * Shell: pairing gate, routes, and the one connection banner. Each screen owns
 * its own scroll area so the list keeps its position when a room is opened.
 */
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { JSX } from "preact";
import { t } from "../app/i18n";
import { currentLocation, navigate, startNavigation } from "../app/navigation";
import { normalizePairingCode } from "../app/pairing";
import type { PlatformFacts } from "../app/platform";
import type { AppStore } from "../app/store";
import { IconSprite, Spinner } from "../ui/icons";
import { FilePreviewScreen } from "./FilePreviewScreen";
import { InstallScreen } from "./InstallScreen";
import { PairScreen } from "./PairScreen";
import { RoomListScreen } from "./RoomListScreen";
import { RoomScreen } from "./RoomScreen";
import { SettingsScreen } from "./SettingsScreen";

export interface AppProps {
  store: AppStore;
  platform: PlatformFacts;
  buildId: string;
  /** Demo mode skips the service worker and starts paired. */
  demo: boolean;
}

export function App({ store, platform, buildId, demo }: AppProps): JSX.Element {
  const forcePair = useSignal(false);

  useEffect(() => startNavigation(), []);

  useEffect(() => {
    if (demo) return;
    // A notification tap in an already-open app arrives as a message.
    const onMessage = (event: MessageEvent) => {
      const data = event.data as { type?: string; roomId?: string } | undefined;
      if (data?.type === "open-room" && data.roomId) navigate({ name: "room", roomId: data.roomId });
    };
    navigator.serviceWorker?.addEventListener("message", onMessage);
    return () => navigator.serviceWorker?.removeEventListener("message", onMessage);
  }, [demo]);

  const location = currentLocation.value;
  const pairing = store.pairing.value;
  const pairCode = location.pairCode ? normalizePairingCode(location.pairCode) : undefined;

  if (pairing === "unknown") {
    return (
      <>
        <IconSprite />
        <div class="app-shell">
          <div class="loading-row">
            <Spinner />
            <span>{t("remote.loading")}</span>
          </div>
        </div>
      </>
    );
  }

  if (pairing !== "paired") {
    const onHomeScreenHint = platform.ios && !platform.standalone && !forcePair.value && !pairCode;
    return (
      <>
        <IconSprite />
        {pairing === "revoked" && <RevokedNotice />}
        {onHomeScreenHint ? (
          <InstallScreen onContinueAnyway={() => (forcePair.value = true)} />
        ) : (
          <PairScreen
            transport={store.transport}
            platform={platform}
            initialCode={pairCode}
            onPaired={() => {
              store.pairing.value = "paired";
              store.start();
              navigate({ name: "rooms" }, { replace: true });
            }}
          />
        )}
      </>
    );
  }

  return (
    <>
      <IconSprite />
      <ConnectionBanner store={store} />
      {renderRoute()}
    </>
  );

  function renderRoute(): JSX.Element {
    switch (location.route.name) {
      case "room":
        return <RoomScreen store={store} roomId={location.route.roomId} />;
      case "settings":
        return <SettingsScreen store={store} platform={platform} buildId={buildId} />;
      case "preview":
        return <FilePreviewScreen store={store} roomId={location.route.roomId} path={location.route.path} />;
      case "pair":
      case "rooms":
        return <RoomListScreen store={store} />;
    }
  }
}

/** One line, above the screen: the socket is down and the app is retrying. */
function ConnectionBanner({ store }: { store: AppStore }): JSX.Element | null {
  if (store.connection.value === "open") return null;
  return (
    <div class="notice info connection-banner">
      <Spinner />
      <span class="notice-text">{t("remote.connection.reconnecting")}</span>
    </div>
  );
}

function RevokedNotice(): JSX.Element {
  return (
    <div class="notice error">
      <span class="notice-text">
        <span class="notice-title">{t("remote.revoked.title")}</span>
        <span class="notice-body">{t("remote.revoked.body")}</span>
      </span>
    </div>
  );
}
