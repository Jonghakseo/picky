/**
 * `pnpm --dir agentd run dev:remote` (docs/remote-pwa-implementation.md 5).
 *
 * Starts a throwaway stack: a mock-runtime agentd on its own port and temp app
 * support dir, the gateway on 17741 with its own temp data dir, and a stand-in
 * hub. It never reads or writes `~/Library/Application Support/Picky` and never
 * connects to 17631 or 17640, so the user's running Picky is untouched.
 *
 * Flags: `--web-root <dir>`, `--no-seed`, `--agentd-port <n>`, `--gateway-port <n>`.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { access, mkdtemp, rm } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseGatewayConfig } from "../config.js";
import { GatewayServer } from "../server.js";
import { StandInHub } from "./stand-in-hub.js";

const DEFAULT_DAEMON_PORT = 17732;
const DEFAULT_GATEWAY_PORT = 17741;
const SEED_PROMPTS = [
  "원격 PWA 데모용 첫 번째 Pickle이에요. 진행 상황을 보여 주세요.",
  "두 번째 Pickle: 방 목록 정렬과 미리보기를 확인하려고 만들었어요.",
];

function print(line: string): void {
  process.stdout.write(`${line}\n`);
}

interface DevOptions {
  webRoot?: string;
  seed: boolean;
  daemonPort: number;
  gatewayPort: number;
}

function parseArgs(argv: readonly string[]): DevOptions {
  const options: DevOptions = { seed: true, daemonPort: DEFAULT_DAEMON_PORT, gatewayPort: DEFAULT_GATEWAY_PORT };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--no-seed") options.seed = false;
    if (argv[index] === "--web-root") {
      const value = argv[index + 1];
      if (!value) throw new Error("--web-root needs a directory");
      options.webRoot = resolve(value);
      index += 1;
    }
    if (argv[index] === "--agentd-port" || argv[index] === "--gateway-port") {
      const flag = argv[index];
      const port = Number(argv[index + 1]);
      // 0 binds an ephemeral port, which is how two stacks run side by side.
      if (!Number.isInteger(port) || port < 0 || port > 65_535) throw new Error(`${flag} needs a port number`);
      if (flag === "--agentd-port") options.daemonPort = port;
      else options.gatewayPort = port;
      index += 1;
    }
  }
  return options;
}

const options = parseArgs(process.argv.slice(2));
const daemonPort = options.daemonPort;
const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const daemonSupportDir = await mkdtemp(join(tmpdir(), "picky-dev-agentd-"));
const gatewaySupportDir = await mkdtemp(join(tmpdir(), "picky-dev-gateway-"));
const daemonToken = randomBytes(24).toString("base64url");
const hubToken = randomBytes(24).toString("base64url");

const daemon = spawnMockDaemon();
await waitForDaemon(daemon);

const gatewayConfig = parseGatewayConfig({
  env: {
    PICKY_GATEWAY_PORT: String(options.gatewayPort),
    PICKY_GATEWAY_HUB_TOKEN: hubToken,
    PICKY_APP_SUPPORT_DIR: gatewaySupportDir,
    ...(options.webRoot ? { PICKY_GATEWAY_WEB_ROOT: options.webRoot } : {}),
  },
  entryDir: join(packageRoot, "dist", "gateway"),
});
const gateway = new GatewayServer({ config: gatewayConfig });
const boundPort = await gateway.start();
const publicUrl = `http://127.0.0.1:${boundPort}`;
print(`picky-gateway listening on 127.0.0.1:${boundPort}`);

const hub = new StandInHub({
  gatewayUrl: `ws://127.0.0.1:${boundPort}`,
  hubToken,
  daemonUrl: `ws://127.0.0.1:${daemonPort}`,
  daemonToken,
  publicUrl,
  cwd: packageRoot,
  print,
});
hub.start();
await waitFor(() => gateway.core.hub.connected, 10_000, "the stand-in hub did not connect");

if (options.seed) {
  await hub.seed(SEED_PROMPTS).catch((error: unknown) => print(`seed failed: ${String(error)}`));
}

// Pairing is hub-driven in production too: the gateway only issues a code while
// the user has "connect a phone" open on the Mac, so the stand-in asks for it
// the same way and prints whatever the gateway answers.
hub.startPairing();
await waitFor(() => gateway.core.pairing.current() !== undefined, 5_000, "the gateway did not issue a pairing code")
  .catch((error: unknown) => print(String(error)));

print("");
print("  ready");
print(`    open:         ${publicUrl}`);
print(`    pairing code: ${gateway.core.pairing.current()?.display ?? "(none; the stand-in hub will print a new one)"}`);
print(`    agentd:       127.0.0.1:${daemonPort} (mock runtime)`);
if (!(await exists(gatewayConfig.webRoot))) {
  // The gateway answers 503 for `/` until the PWA is built, which looks like a
  // broken harness unless it says what to run.
  print(`    no PWA at ${gatewayConfig.webRoot}`);
  print("    build it with: pnpm --dir agentd run build:web");
}
print(`    gateway data: ${gatewaySupportDir}`);
print(`    daemon data:  ${daemonSupportDir}`);
print("    press Ctrl-C to stop everything");

let stopping = false;
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => void shutdown());
}

function spawnMockDaemon(): ChildProcess {
  const child = spawn("node", ["--import", "tsx", join(packageRoot, "src", "index.ts")], {
    cwd: packageRoot,
    env: {
      ...process.env,
      PICKY_AGENTD_RUNTIME: "mock",
      PICKY_AGENTD_PORT: String(daemonPort),
      PICKY_AGENTD_TOKEN: daemonToken,
      PICKY_APP_SUPPORT_DIR: daemonSupportDir,
      PICKY_DEFAULT_CWD: packageRoot,
      PICKY_AGENTD_PARENT_PID: String(process.pid),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout?.on("data", (chunk: Buffer) => print(`[agentd] ${chunk.toString().trimEnd()}`));
  child.stderr?.on("data", (chunk: Buffer) => print(`[agentd!] ${chunk.toString().trimEnd()}`));
  return child;
}

async function waitForDaemon(child: ChildProcess): Promise<void> {
  await new Promise<void>((resolveReady, rejectReady) => {
    const timer = setTimeout(() => rejectReady(new Error("the mock daemon did not start in time")), 60_000);
    child.stdout?.on("data", (chunk: Buffer) => {
      if (!chunk.toString().includes("picky-agentd listening on")) return;
      clearTimeout(timer);
      resolveReady();
    });
    child.once("exit", (code) => {
      clearTimeout(timer);
      rejectReady(new Error(`the mock daemon exited with code ${String(code)}`));
    });
  });
}

async function exists(path: string): Promise<boolean> {
  return access(path).then(() => true, () => false);
}

async function waitFor(condition: () => boolean, timeoutMs: number, message: string): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (condition()) return;
    await new Promise((done) => setTimeout(done, 50));
  }
  throw new Error(message);
}

async function shutdown(): Promise<void> {
  if (stopping) return;
  stopping = true;
  print("\nstopping the dev stack...");
  hub.stop();
  await gateway.stop();
  daemon.kill("SIGTERM");
  await rm(daemonSupportDir, { recursive: true, force: true });
  await rm(gatewaySupportDir, { recursive: true, force: true });
  process.exit(0);
}
