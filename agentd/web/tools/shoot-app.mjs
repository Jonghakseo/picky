#!/usr/bin/env node
/**
 * Screenshot sweep of the PWA shell in demo mode, iPhone 14 size (390x844, 2x),
 * light and dark.
 *
 *   node web/tools/shoot-app.mjs                 build, serve, shoot everything
 *   node web/tools/shoot-app.mjs room-list pair  only those shots
 *
 * Writes build/render-gallery/remote-pwa-app/<shot>-<theme>.png.
 *
 * Headless Chrome is driven over CDP instead of `--screenshot` because half of
 * these states only exist after a tap (archive section, collapsed group, sheets).
 * Chrome runs with a throwaway profile and is killed by pid, so a browser the
 * user already has open is never touched.
 */
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { extname, dirname, join, normalize, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";

const webDir = dirname(dirname(fileURLToPath(import.meta.url)));
const repoDir = dirname(dirname(webDir));
const outDir = join(repoDir, "build/render-gallery/remote-pwa-app");
const siteDir = join(tmpdir(), "picky-web-shots");
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

/** click/type/wait run in the page between load and capture. */
const SHOTS = [
  { name: "room-list", url: "/?demo=1" },
  { name: "room-list-group-collapsed", url: "/?demo=1", steps: [{ click: ".group-section .group-header" }] },
  { name: "room-list-archive-open", url: "/?demo=1", steps: [{ click: ".archived-row" }] },
  { name: "room-list-empty", url: "/?demo=1&state=empty" },
  { name: "room-list-mac-offline", url: "/?demo=1&state=offline" },
  { name: "new-pickle-sheet", url: "/?demo=1", steps: [{ click: ".app-topbar .list-new" }] },
  { name: "install-guide", url: "/?demo=1&state=install" },
  { name: "pair", url: "/?demo=1&state=unpaired" },
  {
    name: "pair-error",
    url: "/?demo=1&state=unpaired",
    // The pairing alphabet has no 0/1/I/O; the demo Mac only accepts PCKY-2345.
    steps: [{ type: ["#pair-code", "ABCD-2345"] }, { click: ".primary-button" }, { wait: 400 }, { scrollToBottom: ".app-scroll" }],
  },
  { name: "settings", url: "/settings?demo=1" },
  { name: "settings-push-blocked", url: "/settings?demo=1&state=ios" },
  { name: "preview-text", url: "/preview?room=s-webhook&path=/Users/you/Pickles/picky/agentd/src/server.ts&demo=1" },
  { name: "preview-markdown", url: "/preview?room=s-webhook&path=/Users/you/Pickles/picky/docs/report.md&demo=1" },
  { name: "preview-image", url: "/preview?room=s-webhook&path=/Users/you/Pickles/picky/shot.png&demo=1" },
  { name: "preview-unsupported", url: "/preview?room=s-webhook&path=/Users/you/Pickles/picky/build/Picky.zip&demo=1" },
  // Conversation rooms (src/room). The demo fixtures cover one state per room.
  { name: "room-running", url: "/room/s-archive?demo=1", steps: [{ wait: 300 }] },
  { name: "room-question", url: "/room/s-webhook?demo=1", steps: [{ wait: 300 }] },
  { name: "room-completed", url: "/room/s-release?demo=1", steps: [{ wait: 300 }] },
  { name: "room-failed", url: "/room/s-queue-migration?demo=1", steps: [{ wait: 300 }] },
  { name: "room-queued", url: "/room/s-docs?demo=1", steps: [{ wait: 300 }] },
  { name: "room-tool-image", url: "/room/s-pipeline?demo=1", steps: [{ wait: 300 }] },
  { name: "room-main", url: "/room/main?demo=1", steps: [{ wait: 300 }] },
  { name: "room-confirm", url: "/room/s-deploy?demo=1", steps: [{ wait: 300 }] },
  // Second step of a three-question form: the answer chip, a checkbox list, and its own-text row.
  {
    name: "room-question-step2",
    url: "/room/s-webhook?demo=1",
    steps: [
      { wait: 300 },
      { click: ".q-opts .q-opt" },
      { click: ".q-btn.is-primary" },
      { wait: 200 },
      { click: ".q-other .q-opt" },
      { type: [".q-other-field", "PagerDuty 당직"] },
      { wait: 200 },
    ],
  },
  // The waiting question scrolled out of view: the bar above the composer points back at it.
  { name: "room-question-pinned", url: "/room/main?demo=1", steps: [{ wait: 400 }, { scrollTop: ".room-scroll" }, { wait: 300 }] },
  {
    name: "room-question-answered",
    url: "/room/s-release?demo=1",
    steps: [{ wait: 300 }, { click: ".q-collapse" }, { wait: 200 }],
  },
  { name: "room-select-stacked", url: "/room/s-models?demo=1", steps: [{ wait: 300 }] },
  { name: "room-select-inline", url: "/room/s-flags?demo=1", steps: [{ wait: 300 }] },
  { name: "room-input", url: "/room/s-keys?demo=1", steps: [{ wait: 300 }] },
  { name: "room-editor", url: "/room/s-notes?demo=1", steps: [{ wait: 300 }] },
  { name: "room-mac-offline", url: "/room/s-archive?demo=1&state=offline", steps: [{ wait: 300 }] },
  { name: "room-long-markdown", url: "/room/s-release?demo=1", steps: [{ wait: 300 }, { scrollToBottom: ".room-scroll" }] },
  {
    name: "room-work-artifacts",
    url: "/room/s-release?demo=1",
    steps: [{ wait: 300 }, { click: ".hdr-work" }, { wait: 200 }],
  },
  {
    name: "room-work-changes",
    url: "/room/s-release?demo=1",
    steps: [{ wait: 300 }, { click: ".hdr-work" }, { wait: 200 }, { click: ".panel-tabs .panel-tab:nth-child(2)" }, { wait: 300 }],
  },
  {
    name: "room-settings-sheet",
    url: "/room/s-archive?demo=1",
    steps: [{ wait: 300 }, { click: ".settings-chip" }, { wait: 300 }],
  },
  {
    name: "room-send-timing",
    url: "/room/s-archive?demo=1",
    steps: [{ wait: 300 }, { type: [".composer-editor", "내일 아침에 보내줘"] }, { click: ".send-chevron" }, { wait: 200 }],
  },
  {
    name: "room-stop-choice",
    url: "/room/s-pipeline?demo=1",
    steps: [{ wait: 300 }, { click: ".toolbar-icon.is-stop" }, { wait: 200 }],
  },
];

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json",
  ".png": "image/png",
  ".svg": "image/svg+xml",
};

async function buildSite() {
  rmSync(siteDir, { recursive: true, force: true });
  await new Promise((done, fail) => {
    const child = spawn(process.execPath, [join(webDir, "build.mjs"), "--out", siteDir], { stdio: "inherit" });
    child.on("exit", (code) => (code === 0 ? done() : fail(new Error(`web build failed (${code})`))));
  });
}

/** Static server with the app's history fallback: unknown paths serve index.html. */
function serve() {
  const server = createServer((request, response) => {
    const path = new URL(request.url, "http://127.0.0.1").pathname;
    let file = resolve(siteDir, "." + normalize(path));
    if (!file.startsWith(siteDir) || extname(file) === "") file = join(siteDir, "index.html");
    try {
      const body = readFileSync(file);
      response.writeHead(200, { "content-type": MIME[extname(file)] ?? "application/octet-stream" });
      response.end(body);
    } catch {
      response.writeHead(404).end("not found");
    }
  });
  return new Promise((done) => server.listen(0, "127.0.0.1", () => done({ server, port: server.address().port })));
}

function startChrome(profile) {
  const chrome = spawn(CHROME, [
    "--headless=new",
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-extensions",
    "--hide-scrollbars",
    "about:blank",
  ]);
  return new Promise((done, fail) => {
    let log = "";
    const timer = setTimeout(() => fail(new Error(`Chrome did not report a DevTools port:\n${log}`)), 20_000);
    chrome.stderr.on("data", (chunk) => {
      log += chunk;
      const match = log.match(/ws:\/\/127\.0\.0\.1:(\d+)\//);
      if (!match) return;
      clearTimeout(timer);
      done({ chrome, port: Number(match[1]) });
    });
  });
}

/** Minimal CDP client: one socket per tab, numbered commands, awaited replies. */
class Tab {
  constructor(socket) {
    this.socket = socket;
    this.next = 1;
    this.pending = new Map();
    socket.on("message", (data) => {
      const message = JSON.parse(data.toString());
      const entry = this.pending.get(message.id);
      if (!entry) return;
      this.pending.delete(message.id);
      message.error ? entry.fail(new Error(message.error.message)) : entry.done(message.result);
    });
  }

  static async open(port) {
    const target = await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: "PUT" }).then((r) => r.json());
    const socket = new WebSocket(target.webSocketDebuggerUrl, { perMessageDeflate: false });
    await new Promise((done, fail) => socket.once("open", done).once("error", fail));
    const tab = new Tab(socket);
    tab.targetId = target.id;
    return tab;
  }

  send(method, params = {}) {
    const id = this.next++;
    return new Promise((done, fail) => {
      this.pending.set(id, { done, fail });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  async evaluate(expression) {
    const result = await this.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description ?? "page threw");
    return result.result.value;
  }

  close() {
    this.socket.close();
  }
}

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

function stepScript(step) {
  if (step.scrollTop) {
    return `(() => { const el = document.querySelector(${JSON.stringify(step.scrollTop)});
      if (!el) throw new Error("no element for ${step.scrollTop}");
      el.scrollTop = 0; return true; })()`;
  }
  if (step.scrollToBottom) {
    return `(() => { const el = document.querySelector(${JSON.stringify(step.scrollToBottom)});
      if (!el) throw new Error("no element for ${step.scrollToBottom}");
      el.scrollTop = el.scrollHeight; return true; })()`;
  }
  if (step.click) {
    return `(() => { const el = document.querySelector(${JSON.stringify(step.click)});
      if (!el) throw new Error("no element for ${step.click}");
      el.click(); return true; })()`;
  }
  const [selector, text] = step.type;
  // Preact listens for input events, so set the value natively and dispatch one.
  // The composer is a textarea, so the setter comes from the element's own class.
  return `(() => { const el = document.querySelector(${JSON.stringify(selector)});
    if (!el) throw new Error("no element for ${selector}");
    const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
    setter.call(el, ${JSON.stringify(text)});
    el.dispatchEvent(new Event("input", { bubbles: true })); return true; })()`;
}

async function main() {
  const wanted = process.argv.slice(2);
  const shots = wanted.length > 0 ? SHOTS.filter((shot) => wanted.includes(shot.name)) : SHOTS;
  if (shots.length === 0) throw new Error(`no such shot: ${wanted.join(", ")}`);

  await buildSite();
  mkdirSync(outDir, { recursive: true });
  const { server, port } = await serve();
  const profile = mkdtempSync(join(tmpdir(), "picky-web-shot."));
  const { chrome, port: debugPort } = await startChrome(profile);
  const tab = await Tab.open(debugPort);
  await tab.send("Page.enable");
  await tab.send("Runtime.enable");
  await tab.send("Emulation.setDeviceMetricsOverride", {
    width: 390,
    height: 844,
    deviceScaleFactor: 2,
    mobile: true,
    screenWidth: 390,
    screenHeight: 844,
  });

  try {
    for (const shot of shots) {
      for (const theme of ["light", "dark"]) {
        const url = `http://127.0.0.1:${port}${shot.url}${shot.url.includes("?") ? "&" : "?"}theme=${theme}`;
        await tab.send("Page.navigate", { url });
        await sleep(700);
        for (const step of shot.steps ?? []) {
          if (step.wait) await sleep(step.wait);
          else await tab.evaluate(stepScript(step));
        }
        if (shot.steps) await sleep(350);
        const file = join(outDir, `${shot.name}-${theme}.png`);
        const image = await tab.send("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
        writeFileSync(file, Buffer.from(image.data, "base64"));
        console.log(file);
      }
    }
  } finally {
    tab.close();
    chrome.kill("SIGTERM");
    server.close();
    await sleep(300);
    rmSync(profile, { recursive: true, force: true });
  }
}

await main();
