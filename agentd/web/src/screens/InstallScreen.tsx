/**
 * Shown on iOS Safari before the app is on the Home Screen. Pairing here would
 * work and then be lost: an iOS Home Screen app has its own cookie store
 * (WWDC23 session 10120), so the login would not carry over.
 */
import type { JSX } from "preact";
import { t } from "../app/i18n";
import { PickleGlyph, ShareIcon } from "../ui/icons";

export function InstallScreen({ onContinueAnyway }: { onContinueAnyway: () => void }): JSX.Element {
  return (
    <div class="app-shell">
      <div class="app-topbar app-side-inset" />
      <div class="app-scroll app-side-inset">
        <div class="page">
          <span class="page-brand">
            <PickleGlyph class="avatar-glyph" />
          </span>
          <h1 class="page-title">{t("remote.install.title")}</h1>
          <p class="page-body">{t("remote.install.body")}</p>

          <div class="steps">
            <div class="step">
              <span class="step-index">1</span>
              <span class="step-text">
                {t("remote.install.step1")}
                <ShareIcon size={14} class="share-glyph" />
              </span>
            </div>
            <div class="step">
              <span class="step-index">2</span>
              <span class="step-text">{t("remote.install.step2")}</span>
            </div>
            <div class="step">
              <span class="step-index">3</span>
              <span class="step-text">{t("remote.install.step3")}</span>
            </div>
          </div>

          <p class="page-hint">{t("remote.install.why")}</p>

          <button class="secondary-button" type="button" onClick={onContinueAnyway}>
            {t("remote.install.continueAnyway")}
          </button>
        </div>
      </div>
    </div>
  );
}
