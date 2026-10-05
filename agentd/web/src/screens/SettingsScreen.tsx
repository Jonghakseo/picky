/**
 * Settings: this device, notifications, the Mac it is paired with, and
 * disconnecting. Everything else about remote access is decided on the Mac.
 */
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { JSX } from "preact";
import { t } from "../app/i18n";
import { goBack } from "../app/navigation";
import type { PlatformFacts } from "../app/platform";
import { disablePush, enablePush, isSubscribed, readPushAvailability } from "../app/push";
import { pushBlockedKey } from "../app/push-policy";
import type { AppStore } from "../app/store";
import { BellIcon, ChevronLeftIcon, Spinner } from "../ui/icons";

export function SettingsScreen({ store, platform, buildId }: { store: AppStore; platform: PlatformFacts; buildId: string }): JSX.Element {
  const subscribed = useSignal(false);
  const busy = useSignal(false);
  const message = useSignal<string | undefined>(undefined);
  const confirming = useSignal(false);

  useEffect(() => {
    void isSubscribed().then((value) => {
      subscribed.value = value;
    });
  }, []);

  const availability = readPushAvailability(platform, store.vapidPublicKey.value);
  const mac = store.mac.value;

  async function toggleNotifications(): Promise<void> {
    if (busy.value || !availability.available) return;
    busy.value = true;
    message.value = undefined;
    if (subscribed.value) {
      await disablePush(store.transport);
      subscribed.value = false;
    } else {
      const result = await enablePush(store.transport, store.vapidPublicKey.value ?? "");
      subscribed.value = result === "enabled";
      if (result === "denied") message.value = t("remote.settings.notifications.unavailable.denied");
      if (result === "failed") message.value = t("remote.settings.notifications.failed");
    }
    busy.value = false;
  }

  async function sendTest(): Promise<void> {
    if (busy.value) return;
    busy.value = true;
    message.value = undefined;
    try {
      await store.transport.pushTest();
      message.value = t("remote.settings.notifications.testSent");
    } catch {
      message.value = t("remote.settings.notifications.failed");
    }
    busy.value = false;
  }

  async function unpair(): Promise<void> {
    await store.transport.unpair();
    store.stop();
    store.markRevoked();
    confirming.value = false;
  }

  return (
    <div class="app-shell">
      <div class="app-topbar bordered app-side-inset">
        <button class="icon-button" type="button" aria-label={t("remote.room.back")} onClick={() => goBack()}>
          <ChevronLeftIcon size={17} />
        </button>
        <span class="app-topbar-title">{t("remote.settings.title")}</span>
      </div>

      <div class="app-scroll app-side-inset">
        <div class="settings-section">
          <div class="settings-section-title">{t("remote.settings.device.section")}</div>
          <div class="settings-row">
            <span class="settings-label">{t("remote.settings.device.name")}</span>
            <span class="settings-value">{store.device.value?.name ?? platform.deviceName}</span>
          </div>
          <div class="settings-row">
            <span class="settings-label">{t("remote.settings.version")}</span>
            <span class="settings-value monospaced">{buildId}</span>
          </div>
        </div>

        <div class="settings-section">
          <div class="settings-section-title">{t("remote.settings.notifications.section")}</div>
          {availability.available ? (
            <>
              <button class="settings-row" type="button" onClick={() => void toggleNotifications()}>
                <span class="settings-label">{t("remote.settings.notifications.label")}</span>
                {busy.value ? <Spinner /> : <span class="settings-action">{t(subscribed.value ? "remote.settings.notifications.turnOff" : "remote.settings.notifications.turnOn")}</span>}
              </button>
              {subscribed.value && (
                <button class="settings-row" type="button" onClick={() => void sendTest()}>
                  <span class="settings-label">{t("remote.settings.notifications.test")}</span>
                  <span class="settings-action">
                    <BellIcon size={15} />
                  </span>
                </button>
              )}
            </>
          ) : (
            <div class="settings-note">{t(pushBlockedKey(availability.reason))}</div>
          )}
          {message.value && <div class="settings-note">{message.value}</div>}
        </div>

        <div class="settings-section">
          <div class="settings-section-title">{t("remote.settings.mac.section")}</div>
          <div class="settings-row">
            <span class="settings-label">{t("remote.settings.mac.name")}</span>
            <span class="settings-value">{mac.name ?? t("remote.settings.mac.unknown")}</span>
          </div>
          <div class="settings-row">
            <span class="settings-label">{t("remote.settings.mac.connection")}</span>
            <span class={`settings-state ${mac.connected ? "is-completed" : "is-failed"}`}>{t(mac.connected ? "remote.settings.mac.connected" : "remote.settings.mac.disconnected")}</span>
          </div>
          {mac.appVersion && (
            <div class="settings-row">
              <span class="settings-label">{t("remote.settings.mac.version")}</span>
              <span class="settings-value monospaced">{mac.appVersion}</span>
            </div>
          )}
        </div>

        <div class="settings-section">
          <button class="settings-row" type="button" onClick={() => (confirming.value = true)}>
            <span class="settings-label">{t("remote.settings.unpair")}</span>
            <span class="settings-action destructive">{t("remote.settings.unpair.action")}</span>
          </button>
          <div class="settings-note">{t("remote.settings.unpair.note")}</div>
        </div>
      </div>

      {confirming.value && (
        <div class="sheet-scrim" onClick={() => (confirming.value = false)}>
          <div class="sheet" onClick={(event) => event.stopPropagation()}>
            <div class="dialog">
              <span class="dialog-title">{t("remote.settings.unpair.confirm.title")}</span>
              <span class="dialog-body">{t("remote.settings.unpair.confirm.body")}</span>
              <div class="dialog-actions">
                <button class="secondary-button destructive" type="button" onClick={() => void unpair()}>
                  {t("remote.settings.unpair.action")}
                </button>
                <button class="secondary-button" type="button" onClick={() => (confirming.value = false)}>
                  {t("common.cancel")}
                </button>
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
