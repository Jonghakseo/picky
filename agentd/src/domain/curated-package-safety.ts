/**
 * Memory/cron releases before these versions predate the coordinated
 * extension/runtime cutover in docs/extension-safety-cutover.md. The cutover
 * was verified for these versions, so unpinned installs and updates (which
 * resolve to the registry's latest release) are allowed. A spec pinned to an
 * older release stays held: a pinned version is not evidence of the fixes.
 * Removing a package or reconciling an existing installation remains possible.
 */
const minimumVerifiedVersions = new Map<string, string>([
  ["@ryan_nookpi/pi-extension-memory-layer", "0.6.0"],
  ["@ryan_nookpi/pi-extension-cron", "0.4.0"],
]);

export function curatedPackageSafetyError(source: string): string | undefined {
  const match = /^npm:(@[^/]+\/[^@/]+)(?:@([^/]+))?$/.exec(source.trim());
  if (!match) return undefined;
  const name = match[1]!;
  const minimum = minimumVerifiedVersions.get(name);
  const pinned = match[2];
  if (!minimum || pinned === undefined || isAtLeast(pinned, minimum)) return undefined;
  return `Installation and updates of ${name}@${pinned} are held: releases before ${minimum} predate the memory/cron safety cutover. Install the latest version instead; see docs/extension-safety-cutover.md.`;
}

/** True only for an exact `x.y.z` version at or above `minimum`; ranges and tags fail closed. */
function isAtLeast(version: string, minimum: string): boolean {
  const parse = (value: string) => /^(\d+)\.(\d+)\.(\d+)$/.exec(value)?.slice(1).map(Number);
  const actual = parse(version);
  const floor = parse(minimum)!;
  if (!actual) return false;
  for (let index = 0; index < 3; index += 1) {
    if (actual[index] !== floor[index]) return actual[index]! > floor[index]!;
  }
  return true;
}
