#!/usr/bin/env node
// Builds the remote PWA into agentd/dist/web (served by the gateway).
//
//   node web/build.mjs            production build (minified, hashed assets)
//   node web/build.mjs --dev      readable build with inline source maps
//   node web/build.mjs --watch    dev build, rebuilt on change
//   node web/build.mjs --demo     production build that keeps the ?demo=1 fixtures
//                                 (screenshot tooling only; --dev and --watch keep them too)
//   node web/build.mjs --out DIR  write somewhere else
//
// Steps: generate the string catalog from Picky/Resources/Localizable.xcstrings
// plus web/i18n/*.json, bundle src/main.tsx (JS + CSS, hashed),
// bundle src/sw.ts to /sw.js with the precache list, copy web/public, and fill
// web/index.html with the hashed asset names.
//
// PICKY_WEB_ROOM=placeholder builds the shell against the stand-in room view
// even when src/room/RoomView.tsx exists (used to keep the shell buildable
// while the conversation UI is mid-change).
import { build, context } from "esbuild";
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const webDir = dirname(fileURLToPath(import.meta.url));
const agentdDir = dirname(webDir);
const repoDir = dirname(agentdDir);
const args = process.argv.slice(2);
const watch = args.includes("--watch");
const dev = watch || args.includes("--dev");
// The ?demo=1 fixtures ship only in builds made for development or screenshots.
// A production bundle defines this false, so the demo entry point and its
// fixtures are dead-code eliminated and `?demo=1` is ignored.
const demo = dev || args.includes("--demo");
const outIndex = args.indexOf("--out");
const outDir = outIndex >= 0 ? args[outIndex + 1] : join(agentdDir, "dist", "web");
const generatedDir = join(webDir, ".generated");

/** Every source file the app bundles, for key scanning and the build id. */
function sourceFiles() {
  const root = join(webDir, "src");
  const files = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) walk(path);
      else if (/\.(ts|tsx|css)$/.test(entry.name)) files.push(path);
    }
  };
  walk(root);
  return files.sort();
}

/**
 * Catalog keys the bundle actually uses. Any dotted string literal in the source
 * is a candidate; only the ones the Mac catalog defines are kept, so the phone
 * ships the HUD's own wording and nothing else (595 `hud.*` keys would be 40 KB).
 */
const KEY_LITERAL = /["'`]([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9_]+)+)["'`]/g;

function referencedKeys(files) {
  const keys = new Set();
  for (const file of files) {
    if (file.endsWith(".css")) continue;
    const source = readFileSync(file, "utf8");
    for (const match of source.matchAll(KEY_LITERAL)) keys.add(match[1]);
  }
  return keys;
}

/**
 * Phone-only copy: every JSON file in web/i18n/, merged. Each owner keeps its
 * own file (remote-strings.json for the shell, room-strings.json for the
 * conversation UI) so parallel edits never collide. A key defined twice fails
 * the build instead of silently picking one.
 */
function phoneStrings() {
  const merged = {};
  for (const name of readdirSync(join(webDir, "i18n")).filter((file) => file.endsWith(".json")).sort()) {
    const table = JSON.parse(readFileSync(join(webDir, "i18n", name), "utf8"));
    for (const [key, value] of Object.entries(table)) {
      if (key.startsWith("$")) continue;
      if (key in merged) throw new Error(`web: ${key} is defined in more than one web/i18n/*.json file`);
      if (typeof value?.ko !== "string" || typeof value?.en !== "string") throw new Error(`web: ${key} in web/i18n/${name} needs both ko and en`);
      merged[key] = value;
    }
  }
  return merged;
}

function generateStrings(files) {
  const catalog = JSON.parse(readFileSync(join(repoDir, "Picky/Resources/Localizable.xcstrings"), "utf8")).strings;
  const wanted = referencedKeys(files);
  const strings = { ko: {}, en: {} };
  for (const key of wanted) {
    const entry = catalog[key];
    if (!entry) continue;
    for (const lang of ["ko", "en"]) {
      const value = entry.localizations?.[lang]?.stringUnit?.value;
      if (typeof value === "string") strings[lang][key] = value;
    }
  }
  const remote = phoneStrings();
  const unusedRemote = [];
  for (const [key, value] of Object.entries(remote)) {
    if (key.startsWith("$")) continue;
    if (!wanted.has(key)) unusedRemote.push(key);
    strings.ko[key] = value.ko;
    strings.en[key] = value.en;
  }
  const missing = [...wanted].filter((key) => key.startsWith("remote.") && !(key in remote));
  if (missing.length > 0) throw new Error(`web: these remote.* keys are used but not in web/i18n/*.json: ${missing.join(", ")}`);
  if (unusedRemote.length > 0) console.warn(`web: unused remote.* keys: ${unusedRemote.join(", ")}`);
  mkdirSync(generatedDir, { recursive: true });
  const path = join(generatedDir, "strings.json");
  const next = JSON.stringify(strings);
  // Rewriting an unchanged file would retrigger the watcher forever.
  if (!existsSync(path) || readFileSync(path, "utf8") !== next) writeFileSync(path, next);
  return strings;
}

/**
 * `picky:room` and `picky:markdown` are the seams with the conversation UI
 * (web/src/room/, built separately). Each resolves to the real file when it
 * exists and to a stand-in in src/screens/ when it does not.
 */
function seamPlugin() {
  const placeholderOnly = process.env.PICKY_WEB_ROOM === "placeholder";
  const pick = (real, fallback) => {
    const path = join(webDir, real);
    return !placeholderOnly && existsSync(path) ? path : join(webDir, fallback);
  };
  return {
    name: "picky-room-seam",
    setup(builder) {
      builder.onResolve({ filter: /^picky:room$/ }, () => ({ path: pick("src/room/RoomView.tsx", "src/screens/RoomUnavailable.tsx") }));
      builder.onResolve({ filter: /^picky:markdown$/ }, () => ({ path: pick("src/room/markdown/Markdown.tsx", "src/screens/MarkdownFallback.tsx") }));
    },
  };
}

/** Shown in settings so a bug report can name the build. */
function buildId(files) {
  const hash = createHash("sha256");
  for (const file of files) hash.update(file).update(readFileSync(file));
  hash.update(JSON.stringify(phoneStrings()));
  return hash.digest("hex").slice(0, 8);
}

const shared = {
  absWorkingDir: agentdDir,
  bundle: true,
  format: "esm",
  target: ["safari16.4", "chrome120"],
  platform: "browser",
  jsx: "automatic",
  jsxImportSource: "preact",
  minify: !dev,
  sourcemap: dev ? "inline" : false,
  legalComments: "none",
  define: { "process.env.NODE_ENV": JSON.stringify(dev ? "development" : "production"), __PICKY_DEMO__: JSON.stringify(demo) },
  logLevel: "warning",
};

/** Filled by buildAll before the app bundle runs. */
let appDefine = {};

function hashOf(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex").slice(0, 10);
}

async function buildApp() {
  rmSync(join(outDir, "assets"), { recursive: true, force: true });
  mkdirSync(join(outDir, "assets"), { recursive: true });
  const result = await build({
    ...shared,
    define: { ...shared.define, ...appDefine },
    plugins: [seamPlugin()],
    entryPoints: { app: join(webDir, "src/main.tsx") },
    outdir: join(outDir, "assets"),
    // Code splitting keeps `import()`ed code (the QR decoder) out of the first
    // load; index.html still has one entry and the service worker precaches
    // every chunk the metafile reports.
    splitting: true,
    entryNames: dev ? "[name]" : "[name]-[hash]",
    // Chunks always carry a hash: esbuild names anonymous ones "chunk", which
    // would collide in a dev build.
    chunkNames: "[name]-[hash]",
    assetNames: dev ? "[name]" : "[name]-[hash]",
    loader: { ".png": "file", ".svg": "file", ".woff2": "file" },
    metafile: true,
  });
  const outputs = Object.keys(result.metafile.outputs).map((file) => relative(outDir, join(agentdDir, file)).split("\\").join("/"));
  const js = outputs.find((file) => /^assets\/app(-[A-Z0-9]+)?\.js$/i.test(file));
  const css = outputs.find((file) => /^assets\/app(-[A-Z0-9]+)?\.css$/i.test(file));
  return { js, css, outputs };
}

function writeIndex(assets) {
  const template = readFileSync(join(webDir, "index.html"), "utf8");
  const html = template
    .replace("%APP_CSS%", assets.css ? `<link rel="stylesheet" href="/${assets.css}">` : "")
    .replace("%APP_JS%", `<script type="module" src="/${assets.js}"></script>`);
  writeFileSync(join(outDir, "index.html"), html);
}

function publicFiles() {
  const root = join(webDir, "public");
  const files = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) walk(path);
      else files.push(relative(root, path).split("\\").join("/"));
    }
  };
  if (existsSync(root)) walk(root);
  return files;
}

async function buildServiceWorker(assets) {
  const precache = ["/", ...assets.outputs.filter((file) => !file.endsWith(".map")).map((file) => `/${file}`), ...publicFiles().map((file) => `/${file}`)];
  const version = createHash("sha256").update(precache.join("\n") + hashOf(join(outDir, "index.html"))).digest("hex").slice(0, 12);
  await build({
    ...shared,
    format: "iife",
    entryPoints: [join(webDir, "src/sw.ts")],
    outfile: join(outDir, "sw.js"),
    define: { ...shared.define, __PRECACHE__: JSON.stringify(precache), __SW_VERSION__: JSON.stringify(version) },
  });
}

async function buildAll() {
  const started = Date.now();
  const files = sourceFiles();
  const strings = generateStrings(files);
  appDefine = { __STRINGS__: JSON.stringify(strings), __BUILD_ID__: JSON.stringify(buildId(files)) };
  mkdirSync(outDir, { recursive: true });
  if (existsSync(join(webDir, "public"))) cpSync(join(webDir, "public"), outDir, { recursive: true });
  const assets = await buildApp();
  writeIndex(assets);
  await buildServiceWorker(assets);
  const sizes = [assets.js, assets.css]
    .filter(Boolean)
    .map((file) => `${file.split("/").pop()} ${(statSync(join(outDir, file)).size / 1024).toFixed(1)} KB`)
    .join(", ");
  console.log(`web: built ${relative(process.cwd(), outDir) || outDir} in ${Date.now() - started} ms (${sizes})`);
}

if (watch) {
  await buildAll();
  // Rebuild everything on any source change; the app is small enough that this stays fast.
  const watcher = await context({ ...shared, entryPoints: [join(webDir, "src/main.tsx")], outdir: join(generatedDir, "watch"), plugins: [seamPlugin(), { name: "rebuild", setup(b) { b.onEnd(() => { buildAll().catch((error) => console.error(error)); }); } }] });
  await watcher.watch();
  console.log("web: watching for changes");
} else {
  await buildAll();
}
