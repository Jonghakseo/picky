#!/usr/bin/env node
/**
 * Tap-target check for the PWA in demo mode at iPhone size (390x844).
 *
 *   node web/tools/hit-test.mjs
 *
 * For every visible interactive element (button, link, input, textarea,
 * select, role=button) on each screen below, the element that receives a tap
 * at its center must be the element itself or something inside it. A
 * transparent layer on top (for example an enlarged hit area drawn by a
 * parent's ::after) passes every screenshot review but swallows real taps;
 * programmatic `element.click()` in other tools never notices it.
 *
 * Exits 1 and lists every covered control when one is found. Chrome runs with
 * a throwaway profile and is killed by pid.
 */
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { extname, dirname, join, normalize, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";

const webDir = dirname(dirname(fileURLToPath(import.meta.url)));
const siteDir = join(tmpdir(), "picky-web-hittest");
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

/** Screens to check. Sheets and menus are covered by their own screens, not underneath. */
const PAGES = [
  "/?demo=1",
  "/?demo=1&state=offline",
  "/?demo=1&state=unpaired",
  "/settings?demo=1",
  "/room/s-archive?demo=1",
  "/room/s-webhook?demo=1",
  "/room/s-deploy?demo=1",
  "/room/s-docs?demo=1",
  "/room/s-queue-migration?demo=1",
  "/room/s-release?demo=1",
  "/room/main?demo=1",
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

/** Runs in the page: returns the controls whose center is covered by something else. */
const PROBE = `(() => {
  const describe = (el) => {
    if (!el) return "nothing";
    const cls = typeof el.className === "string" && el.className.trim() ? "." + el.className.trim().split(/\\s+/).join(".") : "";
    return el.tagName.toLowerCase() + cls;
  };
  const controls = document.querySelectorAll('button, a[href], input:not([type="hidden"]), textarea, select, [role="button"]');
  const covered = [];
  let checked = 0;
  for (const el of controls) {
    const rect = el.getBoundingClientRect();
    if (rect.width < 4 || rect.height < 4) continue;
    const style = getComputedStyle(el);
    if (style.visibility === "hidden" || style.pointerEvents === "none" || Number(style.opacity) === 0) continue;
    if (el.closest('[aria-hidden="true"], [inert]')) continue;
    const x = rect.left + rect.width / 2;
    const y = rect.top + rect.height / 2;
    if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) continue;
    checked += 1;
    const hit = document.elementFromPoint(x, y);
    if (hit && (hit === el || el.contains(hit))) continue;
    covered.push({ control: describe(el), label: (el.getAttribute("aria-label") || el.textContent || "").trim().slice(0, 40), coveredBy: describe(hit) });
  }
  return { checked, covered };
})()`;

async function buildSite() {
  rmSync(siteDir, { recursive: true, force: true });
  await new Promise((done, fail) => {
    const child = spawn(process.execPath, [join(webDir, "build.mjs"), "--out", siteDir], { stdio: "inherit" });
    child.on("exit", (code) => (code === 0 ? done() : fail(new Error(`web build failed (${code})`))));
  });
}

function serve() {
  const server = createServer((request, response) => {
    const path = new URL(request.url, "http://127.0.0.1").pathname;
    let file = resolve(siteDir, "." + normalize(path));
    if (!file.startsWith(siteDir) || extname(file) === "") file = join(siteDir, "index.html");
    try {
      response.writeHead(200, { "content-type": MIME[extname(file)] ?? "application/octet-stream" });
      response.end(readFileSync(file));
    } catch {
      response.writeHead(404).end("not found");
    }
  });
  return new Promise((done) => server.listen(0, "127.0.0.1", () => done({ server, port: server.address().port })));
}

function startChrome(profile) {
  const chrome = spawn(CHROME, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "--disable-extensions", "about:blank"]);
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

async function openTab(port) {
  const target = await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: "PUT" }).then((r) => r.json());
  const socket = new WebSocket(target.webSocketDebuggerUrl, { perMessageDeflate: false });
  await new Promise((done, fail) => socket.once("open", done).once("error", fail));
  let next = 1;
  const pending = new Map();
  socket.on("message", (data) => {
    const message = JSON.parse(data.toString());
    const entry = pending.get(message.id);
    if (!entry) return;
    pending.delete(message.id);
    message.error ? entry.fail(new Error(message.error.message)) : entry.done(message.result);
  });
  const send = (method, params = {}) =>
    new Promise((done, fail) => {
      const id = next++;
      pending.set(id, { done, fail });
      socket.send(JSON.stringify({ id, method, params }));
    });
  return { send, close: () => socket.close() };
}

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

async function main() {
  await buildSite();
  const { server, port } = await serve();
  const profile = mkdtempSync(join(tmpdir(), "picky-web-hittest-profile."));
  const { chrome, port: debugPort } = await startChrome(profile);
  const tab = await openTab(debugPort);
  let failures = 0;
  try {
    await tab.send("Page.enable");
    await tab.send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 2, mobile: true, screenWidth: 390, screenHeight: 844 });
    for (const page of PAGES) {
      await tab.send("Page.navigate", { url: `http://127.0.0.1:${port}${page}` });
      await sleep(800);
      const result = await tab.send("Runtime.evaluate", { expression: PROBE, returnByValue: true });
      const { checked, covered } = result.result.value;
      failures += covered.length;
      console.log(`${covered.length === 0 ? "ok  " : "FAIL"} ${page}  (${checked} controls)`);
      for (const item of covered) console.log(`     ${item.control} "${item.label}" is covered by ${item.coveredBy}`);
    }
  } finally {
    tab.close();
    chrome.kill("SIGTERM");
    server.close();
    await sleep(300);
    rmSync(profile, { recursive: true, force: true });
    rmSync(siteDir, { recursive: true, force: true });
  }
  if (failures > 0) {
    console.error(`${failures} control(s) cannot be tapped at their center.`);
    process.exit(1);
  }
}

await main();
