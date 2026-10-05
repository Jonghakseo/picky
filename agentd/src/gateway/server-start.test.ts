/**
 * Starting on a port someone else already holds.
 *
 * The launcher restarts the gateway every 30 s on a plain failure, so a busy
 * port used to loop forever behind "exited with status 1". The Swift side now
 * matches one stderr line, which only works if start() keeps reporting this
 * case as its own error instead of a generic listen failure.
 */
import { mkdtemp, rm } from "node:fs/promises";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { parseGatewayConfig } from "./config.js";
import { GATEWAY_PORT_IN_USE_EXIT_CODE, GatewayPortInUseError, GatewayServer } from "./server.js";

let blocker: Server | undefined;
let dataDir: string | undefined;

afterEach(async () => {
  await new Promise<void>((done) => (blocker ? blocker.close(() => done()) : done()));
  blocker = undefined;
  if (dataDir) await rm(dataDir, { recursive: true, force: true });
  dataDir = undefined;
});

describe("gateway start", () => {
  it("reports a busy port as a port-in-use failure with the launcher's line", async () => {
    blocker = createServer();
    await new Promise<void>((done) => blocker!.listen(0, "127.0.0.1", done));
    const address = blocker.address();
    const port = typeof address === "object" && address ? address.port : 0;

    dataDir = await mkdtemp(join(tmpdir(), "picky-gateway-port-"));
    const server = new GatewayServer({
      config: parseGatewayConfig({
        env: {
          PICKY_GATEWAY_PORT: String(port),
          PICKY_GATEWAY_HUB_TOKEN: "token-for-the-test",
          PICKY_APP_SUPPORT_DIR: dataDir,
          PICKY_GATEWAY_WEB_ROOT: join(dataDir, "web"),
        },
        entryDir: join(dataDir, "dist"),
      }),
    });

    const error = await server.start().then(() => undefined, (reason: unknown) => reason);
    expect(error).toBeInstanceOf(GatewayPortInUseError);
    // main.ts writes this verbatim; PickyRemoteGatewayLauncher parses it.
    expect((error as GatewayPortInUseError).stderrLine).toBe(`PICKY_GATEWAY_PORT_IN_USE:${port}\n`);
    expect(GATEWAY_PORT_IN_USE_EXIT_CODE).toBe(3);
  });
});
