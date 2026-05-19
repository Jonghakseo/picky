import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { AuthStorage } from "@earendil-works/pi-coding-agent";

const PI_PROVIDER_ID = process.env.PI_AUTH_PROVIDER || "openai-codex";
const CODEX_HOME = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const AUTH_PATH = process.env.CODEX_AUTH_FILE || path.join(CODEX_HOME, "auth.json");

export interface ResolvedCodexOAuth {
  accessToken: string;
  accountId: string;
  isFedramp: boolean;
  source: "pi" | "codex-cli";
}

export type CodexOAuthLoader = () => Promise<ResolvedCodexOAuth>;

/**
 * Resolve a Codex/ChatGPT OAuth access token for use against the OpenAI Realtime
 * WebSocket endpoint. Tries pi AuthStorage (provider `openai-codex`) first because
 * pi handles refresh + file locking; falls back to `~/.codex/auth.json` written
 * by the Codex CLI. Throws when neither source has a usable token so the caller
 * can surface a "please sign in" message to the user.
 */
export const loadCodexOAuth: CodexOAuthLoader = async () => {
  const piAuth = await loadPiAuth();
  if (piAuth) return piAuth;

  const codexAuth = await loadCodexCliAuth();
  if (codexAuth) return codexAuth;

  throw new Error(
    `No Codex OAuth token found. Run \`pi /login\` (provider: ${PI_PROVIDER_ID}) or \`codex login\` (writes ${AUTH_PATH}).`,
  );
};

async function loadPiAuth(): Promise<ResolvedCodexOAuth | undefined> {
  try {
    const storage = AuthStorage.create();
    if (!storage.hasAuth(PI_PROVIDER_ID)) return undefined;
    const accessToken = await storage.getApiKey(PI_PROVIDER_ID, { includeFallback: false });
    if (!accessToken) return undefined;
    const credential = (storage.get(PI_PROVIDER_ID) || {}) as Record<string, unknown>;
    const claims = parseJwt(accessToken)?.["https://api.openai.com/auth"] || {};
    return {
      accessToken,
      accountId: (credential.accountId as string) || (claims.chatgpt_account_id as string) || "",
      isFedramp: Boolean(claims.is_fedramp_account),
      source: "pi",
    };
  } catch {
    return undefined;
  }
}

async function loadCodexCliAuth(): Promise<ResolvedCodexOAuth | undefined> {
  if (!existsSync(AUTH_PATH)) return undefined;
  try {
    const raw = JSON.parse(await readFile(AUTH_PATH, "utf8")) as Record<string, any>;
    const tokens = (raw.tokens || {}) as Record<string, any>;
    const accessToken: string | undefined = tokens.access_token || raw.access_token;
    if (!accessToken) return undefined;
    const accessClaims = parseJwt(accessToken)?.["https://api.openai.com/auth"] || {};
    const idClaims = parseJwt(tokens.id_token)?.["https://api.openai.com/auth"] || {};
    return {
      accessToken,
      accountId: tokens.account_id || raw.account_id || accessClaims.chatgpt_account_id || "",
      isFedramp: Boolean(idClaims.is_fedramp_account),
      source: "codex-cli",
    };
  } catch {
    return undefined;
  }
}

function parseJwt(token: string | undefined): Record<string, any> | null {
  if (!token || typeof token !== "string") return null;
  const parts = token.split(".");
  if (parts.length < 2) return null;
  try {
    const payload = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = payload.padEnd(payload.length + ((4 - (payload.length % 4)) % 4), "=");
    return JSON.parse(Buffer.from(padded, "base64").toString("utf8"));
  } catch {
    return null;
  }
}

/**
 * Codex CLI-shaped headers attached to every Realtime request. Sending these
 * with a ChatGPT OAuth bearer is what makes the Realtime endpoint bill against
 * a ChatGPT/Codex subscription instead of a Platform billing account.
 *
 * Caveat: spoofing the Codex CLI user-agent against api.openai.com is in a
 * grey ToS area and may stop working without notice if OpenAI changes the
 * accepted client list.
 */
export function buildCodexClientHeaders(auth: ResolvedCodexOAuth, codexVersion = "0.120.0"): Record<string, string> {
  return {
    Authorization: `Bearer ${auth.accessToken}`,
    ...(auth.accountId ? { "ChatGPT-Account-ID": auth.accountId } : {}),
    originator: "codex_cli_rs",
    "user-agent": `codex_cli_rs/picky-agentd (${process.platform}; ${process.arch}) Node/${process.versions.node}`,
    version: codexVersion,
    ...(auth.isFedramp ? { "X-OpenAI-Fedramp": "true" } : {}),
  };
}
