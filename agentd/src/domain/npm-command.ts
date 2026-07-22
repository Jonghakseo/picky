import { delimiter, dirname, join } from "node:path";

export interface NpmCommandResolutionOptions {
  configured: string[] | undefined;
  execPath: string;
  fileExists: (path: string) => boolean;
}

export function bundledNpmCliPath(execPath: string): string {
  return join(dirname(execPath), "..", "lib", "node_modules", "npm", "bin", "npm-cli.js");
}

/**
 * Uses an explicit user command when configured, otherwise runs the npm CLI
 * bundled alongside Picky's Node runtime when it is available.
 */
export function resolveNpmCommand({ configured, execPath, fileExists }: NpmCommandResolutionOptions): string[] | undefined {
  if (configured && configured.length > 0) return configured;

  const bundledNpmCli = bundledNpmCliPath(execPath);
  return fileExists(bundledNpmCli) ? [execPath, bundledNpmCli] : configured;
}

/** Ensures npm lifecycle scripts resolve the daemon's Node binary first. */
export function prependNodeBinToPath(pathValue: string | undefined, execPath: string): string {
  const nodeBin = dirname(execPath);
  const entries = (pathValue ?? "").split(delimiter).filter(Boolean);
  if (entries.includes(nodeBin)) return pathValue ?? nodeBin;
  return [nodeBin, ...entries].join(delimiter);
}
