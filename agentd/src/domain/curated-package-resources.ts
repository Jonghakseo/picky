/**
 * Resources that curated Pi packages register. Pi loads every discovered
 * extension and keeps the first skill with a given name, so installing one of
 * these packages next to another source of the same tool or skill would load
 * two copies or silently shadow one of them. Picky blocks that install and
 * reports the other owner instead of guessing which copy should win.
 */
export interface CuratedPackageResources {
  tools: readonly string[];
  skills: readonly string[];
}

const resourcesByPackage: Readonly<Record<string, CuratedPackageResources>> = {
  "@ryan_nookpi/pi-extension-web-access": { tools: ["web_search", "fetch_content", "get_search_content"], skills: [] },
  "@ryan_nookpi/pi-extension-vcc-ko": { tools: ["vcc_recall"], skills: [] },
  "@ryan_nookpi/pi-extension-bash-async": { tools: ["bash_async"], skills: [] },
  "@ryan_nookpi/pi-skill-skill-creator": { tools: [], skills: ["skill-creator"] },
  "@ryan_nookpi/pi-skill-excalidraw": { tools: [], skills: ["excalidraw"] },
  "@ryan_nookpi/pi-skill-tmux-terminal": { tools: [], skills: ["tmux-terminal"] },
  "@ryan_nookpi/pi-skill-chrome-cdp": { tools: [], skills: ["chrome-cdp"] },
  "@ryan_nookpi/pi-skill-a4": { tools: [], skills: ["a4"] },
};

/**
 * How the other copy can be removed without guessing:
 * - `package`: another user-scope Pi package; remove it through Pi's package manager.
 * - `trash`: an auto-discovered local skill/extension folder (or single file) directly
 *   under a Pi resource root; the app moves `path` to the Trash so it stays recoverable.
 * - `manual`: anything else (project packages, explicit settings paths); the user decides.
 */
export type CuratedConflictRemoval =
  | { kind: "package"; source: string }
  | { kind: "trash"; path: string }
  | { kind: "manual" };

export interface CuratedPackageConflict {
  source: string;
  kind: "tool" | "skill";
  name: string;
  /** Absolute path of the resource that already provides `name`. */
  ownerPath: string;
  removal: CuratedConflictRemoval;
}

/** `npm:@scope/name@1.2.3` and `npm:@scope/name` identify the same package. */
export function npmPackageName(source: string): string | undefined {
  const match = /^npm:((?:@[^/@\s]+\/)?[^/@\s]+)(?:@[^/\s]+)?$/.exec(source.trim());
  return match?.[1];
}

export function curatedPackageResources(source: string): CuratedPackageResources | undefined {
  const name = npmPackageName(source);
  return name === undefined ? undefined : resourcesByPackage[name];
}

export function curatedPackageConflictError(conflicts: readonly CuratedPackageConflict[]): string | undefined {
  if (conflicts.length === 0) return undefined;
  const owners = conflicts.map((conflict) => `${conflict.kind} "${conflict.name}" from ${conflict.ownerPath}`);
  return `Another installed resource already provides the same ${conflicts.length === 1 ? "name" : "names"}: ${owners.join("; ")}. Remove it before installing this package so Pi does not load two copies.`;
}
