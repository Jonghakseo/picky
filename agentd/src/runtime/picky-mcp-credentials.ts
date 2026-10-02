/**
 * MCP OAuth credentials that Picky shares with the user's Pi CLI in `<agent-dir>/mcp-auth.json`.
 *
 * Pi before 1.0 keys a server's state by URL. Pi 1.0 keys it by `mcp__<server>|<url>` and, on
 * first load, moves a URL entry to the new key and deletes the old one. Picky runs Pi 1.0 but
 * shares the agent directory with whatever Pi CLI the user has installed, so the 1.0 default would
 * sign an older CLI out of every OAuth server Picky touches. This store writes state back to the
 * entry it was read from and never moves or deletes a URL entry on load, so:
 *
 * - an older CLI keeps its sign-in and sees tokens Picky refreshed (refresh tokens may rotate);
 * - once a Pi 1.0 CLI has moved a sign-in to its per-server key, Picky follows that entry;
 * - a save goes to this server's per-server entry when it has one, else to the URL entry when one
 *   exists, and for a first sign-in to a per-server entry only when another server already holds
 *   one for this URL, otherwise to the URL entry.
 *
 * Refreshes take the refresh locks of both versions, URL lock first, so neither CLI refreshes a
 * token Picky is refreshing.
 *
 * Remove when Picky stops sharing the Pi CLI's agent directory.
 */
import { createHash } from "node:crypto";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import type { McpExtensionOptions } from "@earendil-works/pi-coding-agent";
import lockfile from "proper-lockfile";
import type { PiMcpInternals } from "./picky-mcp.js";

/** The SDK's store type. It is a class with private members, so this structural store is cast to it. */
export type PickyMcpCredentials = NonNullable<McpExtensionOptions["credentials"]>;
type McpOAuthState = Parameters<ReturnType<PickyMcpCredentials["forServer"]>["save"]>[0];
type States = Record<string, McpOAuthState>;

// The SDK's refresh lock timing, so a Picky refresh waits for a CLI refresh like another CLI would.
const REFRESH_LOCK_STALE_MS = 20_000;
const REFRESH_LOCK_WAIT_MS = 25_000;
const REFRESH_LOCK_RETRY_MS = 100;

export function createPickyMcpCredentials(agentDir: string, internals: Pick<PiMcpInternals, "FileAuthStorageBackend" | "mcpNamespace">): PickyMcpCredentials {
  const { FileAuthStorageBackend, mcpNamespace } = internals;
  const backend = new FileAuthStorageBackend(join(agentDir, "mcp-auth.json"));
  const read = (): States => backend.withLock((current) => ({ result: parseStates(current) }));
  const update = <T>(fn: (states: States) => T): T => backend.withLock((current) => {
    const states = parseStates(current);
    const result = fn(states);
    return { result, next: `${JSON.stringify(states, null, 2)}\n` };
  });

  const keys = (name: string, serverUrl: string) => {
    const legacy = String(new URL(serverUrl));
    return { legacy, perServer: `${mcpNamespace(name)}|${legacy}` };
  };
  const stateFor = (states: States, name: string, serverUrl: string) => {
    const { legacy, perServer } = keys(name, serverUrl);
    return states[perServer] ?? states[legacy];
  };
  /** The entry a save goes to: the one Picky read from, or for a first sign-in the URL entry older CLIs read. */
  const saveKey = (states: States, name: string, serverUrl: string) => {
    const { legacy, perServer } = keys(name, serverUrl);
    if (states[perServer]) return perServer;
    // `load` returned the URL entry, so a refreshed token has to go back there or the older CLI loses it.
    if (states[legacy]) return legacy;
    // Pi 1.0 already keeps separate accounts for this URL; a URL entry would hand ours to the others.
    const perServerPrefix = mcpNamespace("");
    const anotherServerSignedIn = Object.keys(states)
      .some((key) => key !== perServer && key.startsWith(perServerPrefix) && key.endsWith(`|${legacy}`));
    return anotherServerSignedIn ? perServer : legacy;
  };

  const lockPath = (key: string) => join(agentDir, `mcp-auth-refresh-${createHash("sha256").update(key).digest("hex").slice(0, 16)}`);
  const withLock = async <T>(key: string, fn: () => Promise<T>): Promise<T> => {
    mkdirSync(agentDir, { recursive: true, mode: 0o700 });
    const release = await lockfile.lock(lockPath(key), {
      realpath: false,
      stale: REFRESH_LOCK_STALE_MS,
      retries: { retries: REFRESH_LOCK_WAIT_MS / REFRESH_LOCK_RETRY_MS, factor: 1, minTimeout: REFRESH_LOCK_RETRY_MS, maxTimeout: REFRESH_LOCK_RETRY_MS },
      // Like the SDK: a lost lock at worst lets two refreshes overlap.
      onCompromised: () => {},
    });
    try {
      return await fn();
    } finally {
      await release().catch(() => undefined);
    }
  };

  const store = {
    forServer(name: string, serverUrl: string) {
      const { legacy, perServer } = keys(name, serverUrl);
      return {
        load: () => stateFor(read(), name, serverUrl),
        save: (state: McpOAuthState) => update((states) => { states[saveKey(states, name, serverUrl)] = state; }),
        withRefreshLock: <T>(fn: () => Promise<T>) => withLock(legacy, () => withLock(perServer, fn)),
      };
    },
    tokens(name: string, serverUrl: string) {
      return stateFor(read(), name, serverUrl)?.tokens;
    },
    /** Signs out for both CLI versions. */
    remove(name: string, serverUrl: string): boolean {
      const { legacy, perServer } = keys(name, serverUrl);
      return update((states) => {
        const signedIn = legacy in states || perServer in states;
        delete states[legacy];
        delete states[perServer];
        return signedIn;
      });
    },
  };
  return store as unknown as PickyMcpCredentials;
}

function parseStates(content: string | undefined): States {
  if (!content?.trim()) return {};
  const parsed = JSON.parse(content) as unknown;
  return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed) ? parsed as States : {};
}
