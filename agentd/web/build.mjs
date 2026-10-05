#!/usr/bin/env node
// Builds the remote PWA into agentd/dist/web (served by the gateway).
//
//   node web/build.mjs            production build (minified, hashed assets)
//   node web/build.mjs --dev      readable build with inline source maps
//   node web/build.mjs --watch    dev build, rebuilt on change
//   node web/build.mjs --out DIR  write somewhere else
//
// Steps: generate the string catalog from Picky/Resources/Localizable.xcstrings
// plus web/i18n/remote-strings.json, bundle src/main.tsx (JS + CSS, hashed),
// bundle src/sw.ts to /sw.js with the precache list, copy web/public, and fill
// web/index.html with the hashed asset names.
import { build, context } from "esbuild";
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const webDir = dirname(fileURLToPath(import.meta.url));
const agentdDir = dirname(webDir);
const repoDir = dirname(agentdDir);
const args = process.argv.slice(2);
const watch = args.includes("--watch");
const dev = watch || args.includes("--dev");
const outIndex = args.indexOf("--out");
const outDir = outIndex >= 0 ? args[outIndex + 1] : join(agentdDir, "dist", "web");
const generatedDir = join(webDir, ".generated");

/** Catalog keys the PWA may use: HUD copy, shared copy, and phone-only keys. */
const CATALOG_PREFIXES = ["hud.", "common.", "dictation."];

function generateStrings() {
  const catalog = JSON.parse(readFileSync(join(repoDir, "Picky/Resources/Localizable.xcstrings"), "utf8")).strings;
  const strings = { ko: {}, en: {} };
  for (const [key, entry] of Object.entries(catalog)) {
    if (!CATALOG_PREFIXES.some((prefix) => key.startsWith(prefix))) continue;
    for (const lang of ["ko", "en"]) {
      const value = entry.localizations?.[lang]?.stringUnit?.value;
      if (typeof value === "string") strings[lang][key] = value;
    }
  }
  const remote = JSON.parse(readFileSync(join(webDir, "i18n/remote-strings.json"), "utf8"));
  for (const [key, value] of Object.entries(remote)) {
    if (key.startsWith("$")) continue;
    strings.ko[key] = value.ko;
    strings.en[key] = value.en;
  }
  mkdirSync(generatedDir, { recursive: true });
  const path = join(generatedDir, "strings.json");
  const next = JSON.stringify(strings);
  // Rewriting an unchanged file would retrigger the watcher forever.
  if (!existsSync(path) || readFileSync(path, "utf8") !== next) writeFileSync(path, next);
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
  define: { "process.env.NODE_ENV": JSON.stringify(dev ? "development" : "production") },
  logLevel: "warning",
};

function hashOf(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex").slice(0, 10);
}

async function buildApp() {
  rmSync(join(outDir, "assets"), { recursive: true, force: true });
  mkdirSync(join(outDir, "assets"), { recursive: true });
  const result = await build({
    ...shared,
    entryPoints: { app: join(webDir, "src/main.tsx") },
    outdir: join(outDir, "assets"),
    entryNames: dev ? "[name]" : "[name]-[hash]",
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
  generateStrings();
  mkdirSync(outDir, { recursive: true });
  if (existsSync(join(webDir, "public"))) cpSync(join(webDir, "public"), outDir, { recursive: true });
  const assets = await buildApp();
  writeIndex(assets);
  await buildServiceWorker(assets);
  console.log(`web: built ${relative(process.cwd(), outDir) || outDir} in ${Date.now() - started} ms`);
}

if (watch) {
  await buildAll();
  // Rebuild everything on any source change; the app is small enough that this stays fast.
  const watcher = await context({ ...shared, entryPoints: [join(webDir, "src/main.tsx")], outdir: join(generatedDir, "watch"), plugins: [{ name: "rebuild", setup(b) { b.onEnd(() => { buildAll().catch((error) => console.error(error)); }); } }] });
  await watcher.watch();
  console.log("web: watching for changes");
} else {
  await buildAll();
}
