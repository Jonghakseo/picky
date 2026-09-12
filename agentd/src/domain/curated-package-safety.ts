/**
 * These releases require a coordinated extension/runtime cutover. Keep their
 * curated install/update paths closed until patched packages are published and
 * the release checklist in docs/extension-safety-cutover.md is verified.
 * Removing a package or reconciling an existing installation remains possible.
 */
const heldPackages = new Set([
  "@ryan_nookpi/pi-extension-memory-layer",
  "@ryan_nookpi/pi-extension-cron",
]);

export function curatedPackageSafetyError(source: string): string | undefined {
  const match = /^npm:(@[^/]+\/[^@/]+)(?:@[^/]+)?$/.exec(source.trim());
  if (!match || !heldPackages.has(match[1]!)) return undefined;
  return `Installation and updates of ${match[1]} are temporarily held for the memory/cron safety cutover. Patched packages and all session runtimes must be verified together; see docs/extension-safety-cutover.md.`;
}
