import { basename, delimiter, dirname, join } from "node:path";

export interface NpmCommandResolutionOptions {
  configured: string[] | undefined;
  execPath: string;
  fileExists: (path: string) => boolean;
  runnerPath?: string;
  timeoutMs?: number;
}

export function bundledNpmCliPath(execPath: string): string {
  return join(dirname(execPath), "..", "lib", "node_modules", "npm", "bin", "npm-cli.js");
}

/**
 * Uses an explicit user command when configured, otherwise runs the npm CLI
 * bundled alongside Picky's Node runtime when it is available. Production can
 * wrap the resolved command in a process-tree timeout runner so a stuck npm
 * lifecycle script cannot hold the package-operation queue forever.
 */
export function resolveNpmCommand({
  configured,
  execPath,
  fileExists,
  runnerPath,
  timeoutMs,
}: NpmCommandResolutionOptions): string[] | undefined {
  const bundledNpmCli = bundledNpmCliPath(execPath);
  const baseCommand = configured && configured.length > 0
    ? configured
    : fileExists(bundledNpmCli)
      ? [execPath, bundledNpmCli]
      : undefined;
  if (!runnerPath || timeoutMs === undefined) return baseCommand;

  const resolvedCommand = baseCommand ?? ["npm"];
  return [
    execPath,
    runnerPath,
    "--timeout-ms",
    String(timeoutMs),
    "--command-json",
    JSON.stringify(resolvedCommand),
    // Pi inspects the configured command to select npm/bun/pnpm-specific args.
    // Keep that identity visible while the real argv stays in the JSON payload.
    "--",
    configured && configured.length > 0 ? packageManagerIdentity(configured) : "npm",
  ];
}

function packageManagerIdentity(command: string[]): string {
  const separatorIndex = command.lastIndexOf("--");
  const executable = separatorIndex >= 0 ? command[separatorIndex + 1] : command[0];
  return executable ? basename(executable).replace(/\.(cmd|exe)$/i, "") : "npm";
}

/** Ensures npm lifecycle scripts resolve the daemon's Node binary first. */
export function prependNodeBinToPath(pathValue: string | undefined, execPath: string): string {
  const nodeBin = dirname(execPath);
  const entries = (pathValue ?? "").split(delimiter).filter(Boolean);
  if (entries.includes(nodeBin)) return pathValue ?? nodeBin;
  return [nodeBin, ...entries].join(delimiter);
}
