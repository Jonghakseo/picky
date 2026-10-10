/**
 * Response headers on `/api/files/raw`, over a real socket.
 *
 * HTML and SVG come back under a sandbox policy; a PDF must come back under a
 * policy that still lets the browser's own viewer open it.
 */
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { parseGatewayConfig } from "./config.js";
import { GatewayServer } from "./server.js";
import { MAIN_ROOM_ID } from "../remote/constants.js";

let gateway: GatewayServer;
let supportDir: string;
let origin = "";
let cookie = "";
let reportsDir = "";

beforeAll(async () => {
  supportDir = await mkdtemp(join(tmpdir(), "picky-preview-headers-"));
  reportsDir = await mkdtemp(join(tmpdir(), "picky-preview-files-"));
  await writeFile(join(reportsDir, "report.pdf"), "%PDF-1.4\n%%EOF\n");
  await writeFile(join(reportsDir, "page.html"), "<h1>hi</h1>");

  gateway = new GatewayServer({
    config: parseGatewayConfig({
      env: {
        PICKY_GATEWAY_PORT: "0",
        PICKY_GATEWAY_HUB_TOKEN: "hub-token",
        PICKY_APP_SUPPORT_DIR: supportDir,
        PICKY_GATEWAY_WEB_ROOT: join(supportDir, "web"),
      },
      entryDir: join(supportDir, "dist", "gateway"),
    }),
  });
  const port = await gateway.start();
  origin = `http://127.0.0.1:${port}`;

  const { token } = await gateway.core.devices.add("test phone");
  cookie = `picky_remote=${token}`;
  gateway.core.main.replaceMessages([
    { role: "assistant", text: `[report](${join(reportsDir, "report.pdf")}) and [page](${join(reportsDir, "page.html")})`, createdAt: new Date().toISOString() },
  ] as never);
});

afterAll(async () => {
  await gateway?.stop();
  await rm(supportDir, { recursive: true, force: true });
  await rm(reportsDir, { recursive: true, force: true });
});

function raw(name: string): Promise<Response> {
  const path = encodeURIComponent(join(reportsDir, name));
  return fetch(`${origin}/api/files/raw?sessionId=${MAIN_ROOM_ID}&path=${path}`, { headers: { cookie } });
}

describe("file preview responses", () => {
  it("serves a referenced PDF as application/pdf under a policy that does not sandbox the viewer", async () => {
    const response = await raw("report.pdf");
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/pdf");
    const policy = response.headers.get("content-security-policy") ?? "";
    expect(policy).toContain("script-src 'none'");
    expect(policy).not.toMatch(/sandbox|object-src/);
  });

  it("still sandboxes HTML", async () => {
    const response = await raw("page.html");
    expect(response.status).toBe(200);
    expect(response.headers.get("content-security-policy")).toMatch(/^sandbox;/);
  });
});
