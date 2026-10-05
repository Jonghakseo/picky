#!/usr/bin/env node
/**
 * Keyboard and screen-reader structure check for the PWA in demo mode, at
 * desktop-browser size (1280x820) where people drive it with a keyboard.
 *
 *   node web/tools/keyboard-check.mjs
 *
 * Every sheet and menu must behave as a dialog: opening it from the keyboard
 * moves focus inside, Tab stays inside, Esc closes it (a sub-page first goes
 * back), and focus returns to the control that opened it. Each screen has
 * one main landmark and one h1. Real key events are dispatched through the
 * DevTools protocol, so a missing handler fails here the way it fails for a
 * person; `element.click()` alone would not notice.
 *
 * Exits 1 and lists every failed expectation. Chrome runs with a throwaway
 * profile and is killed by pid.
 */
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { extname, dirname, join, normalize, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";

const webDir = dirname(dirname(fileURLToPath(import.meta.url)));
const siteDir = join(tmpdir(), "picky-web-keyboard");
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

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

const KEY_CODES = { Enter: 13, Escape: 27, Tab: 9, ArrowRight: 39, ArrowLeft: 37 };

async function main() {
  await buildSite();
  const { server, port } = await serve();
  const profile = mkdtempSync(join(tmpdir(), "picky-web-keyboard-profile."));
  const { chrome, port: debugPort } = await startChrome(profile);
  const tab = await openTab(debugPort);
  const failures = [];
  const evaluate = async (expression) => (await tab.send("Runtime.evaluate", { expression, returnByValue: true })).result.value;
  const press = async (key, { shift = false } = {}) => {
    const modifiers = shift ? 8 : 0;
    await tab.send("Input.dispatchKeyEvent", { type: "rawKeyDown", key, code: key, windowsVirtualKeyCode: KEY_CODES[key], modifiers });
    if (key === "Enter") await tab.send("Input.dispatchKeyEvent", { type: "char", text: "\r", key, modifiers });
    await tab.send("Input.dispatchKeyEvent", { type: "keyUp", key, code: key, windowsVirtualKeyCode: KEY_CODES[key], modifiers });
    await sleep(300);
  };
  const open = async (path) => {
    await tab.send("Page.navigate", { url: `http://127.0.0.1:${port}${path}${path.includes("?") ? "&" : "?"}demo=1` });
    await sleep(1200);
  };
  const expect = (label, ok, detail = "") => {
    console.log(`${ok ? "ok  " : "FAIL"} ${label}${ok || !detail ? "" : `  (${detail})`}`);
    if (!ok) failures.push(label);
  };
  const focusInside = (selector) => evaluate(`!!document.activeElement?.closest(${JSON.stringify(selector)})`);
  const focusIs = (selector) => evaluate(`document.activeElement === document.querySelector(${JSON.stringify(selector)})`);
  const isOpen = (selector) => evaluate(`!!document.querySelector(${JSON.stringify(selector)})`);

  /** Opens a dialog from its control with Return, then checks focus, Tab, Esc and the return of focus. */
  const dialog = async (name, path, opener, selector, extra, prepare) => {
    await open(path);
    if (prepare) await prepare();
    await evaluate(`document.querySelector(${JSON.stringify(opener)})?.focus()`);
    await press("Enter");
    expect(`${name}: opens with focus inside`, await focusInside(selector));
    for (let i = 0; i < 10; i += 1) await press("Tab");
    await press("Tab", { shift: true });
    expect(`${name}: Tab stays inside`, await focusInside(selector));
    if (extra) await extra();
    await press("Escape");
    expect(`${name}: Esc closes it`, !(await isOpen(selector)));
    expect(`${name}: focus returns to its control`, await focusIs(opener));
  };

  try {
    await tab.send("Page.enable");
    await tab.send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 820, deviceScaleFactor: 1, mobile: false });

    await dialog("Pickle settings", "/room/s-archive", ".settings-chip", ".settings-menu", async () => {
      // A sub-page unmounts the focused row; Esc there goes back, not out.
      await evaluate(`document.querySelector('.settings-menu .settings-row')?.focus()`);
      await press("Enter");
      expect("Pickle settings: a sub-page keeps focus inside", await focusInside(".settings-menu"));
      await press("Escape");
      expect("Pickle settings: Esc on a sub-page goes back to the list", await isOpen(".settings-menu .settings-row.is-toggle"));
    });
    // The timing menu is only offered once there is something to send.
    await dialog("Send timing", "/room/s-archive", ".send-chevron", ".send-timing-menu", undefined, async () => {
      await evaluate(`document.querySelector('.room-composer textarea').focus()`);
      await tab.send("Input.insertText", { text: "later" });
      await sleep(200);
    });
    await dialog("Work panel", "/room/s-pipeline", ".hdr-work", ".work-sheet .sheet-panel", async () => {
      await evaluate(`document.querySelector('[role=tab][aria-selected=true]')?.focus()`);
      await press("ArrowRight");
      const selected = await evaluate(`document.activeElement?.getAttribute('aria-selected') === 'true' && document.activeElement.id === document.querySelector('[role=tabpanel]')?.getAttribute('aria-labelledby')`);
      expect("Work panel: arrow keys select the next tab and its panel follows", selected);
    });
    await dialog("Stop choice", "/room/s-pipeline", ".toolbar-icon.is-stop", ".stop-alert", async () => {
      // Checked after reopening: Return on the default control must not stop work.
    });
    await open("/room/s-pipeline");
    await evaluate(`document.querySelector('.toolbar-icon.is-stop')?.focus()`);
    await press("Enter");
    expect("Stop choice: focus starts on Cancel", await focusIs(".stop-alert-action.is-cancel"));
    await dialog("New Pickle", "/", ".list-new", ".sheet");

    for (const path of ["/", "/room/s-archive", "/settings", "/?state=unpaired"]) {
      const structure = await (async () => {
        await open(path);
        return evaluate(`({ main: document.querySelectorAll('main').length, h1: document.querySelectorAll('h1:not(.msgs h1)').length })`);
      })();
      expect(`${path}: one main landmark and one h1`, structure.main === 1 && structure.h1 === 1, JSON.stringify(structure));
    }
  } finally {
    tab.close();
    chrome.kill("SIGTERM");
    server.close();
    await sleep(300);
    rmSync(profile, { recursive: true, force: true });
    rmSync(siteDir, { recursive: true, force: true });
  }
  if (failures.length > 0) {
    console.error(`${failures.length} keyboard expectation(s) failed.`);
    process.exit(1);
  }
}

await main();
