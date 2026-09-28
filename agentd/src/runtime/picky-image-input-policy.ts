import type { SettingsManager } from "@earendil-works/pi-coding-agent";

/**
 * Picky sends screenshots and image tool results as required turn context.
 * Pi's `images.blockImages` setting is a local CLI preference; when it leaks
 * into Picky sessions, Pi replaces every image with "Image reading is
 * disabled." before the model call. Override only the in-memory getter Pi
 * consults at request time so the user's settings file stays untouched and
 * the override survives settings reloads.
 */
export function keepPickyImageInputEnabled(settingsManager: SettingsManager | undefined): void {
  if (!settingsManager) return;
  settingsManager.getBlockImages = () => false;
}
