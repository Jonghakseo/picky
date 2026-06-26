#!/usr/bin/env node
/* eslint-disable no-console */

const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const strict = process.env.PICKY_ARCH_GUARD_STRICT === "1";
const warnings = [];
const errors = [];

function rel(filePath) {
  return path.relative(root, filePath).replaceAll(path.sep, "/");
}

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), "utf8");
}

function exists(relativePath) {
  return fs.existsSync(path.join(root, relativePath));
}

function walk(relativeDir, predicate = () => true) {
  const base = path.join(root, relativeDir);
  if (!fs.existsSync(base)) return [];
  const result = [];
  const stack = [base];
  while (stack.length > 0) {
    const current = stack.pop();
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(full);
      } else if (predicate(full)) {
        result.push(full);
      }
    }
  }
  return result.sort();
}

function addWarning(message) {
  warnings.push(message);
}

function addError(message) {
  errors.push(message);
}

const nodeSideEffectModulePattern = String.raw`(?:node:)?(?:fs(?:\/[^"']*)?|http|https|child_process)`;
const nodeSideEffectImportPatterns = [
  new RegExp(String.raw`from\s+["']${nodeSideEffectModulePattern}["']`),
  new RegExp(String.raw`^\s*import\s+["']${nodeSideEffectModulePattern}["']`, "m"),
  new RegExp(String.raw`\brequire\s*\(\s*["']${nodeSideEffectModulePattern}["']\s*\)`),
  new RegExp(String.raw`\bimport\s*\(\s*["']${nodeSideEffectModulePattern}["']\s*\)`),
];

function hasNodeSideEffectImport(text) {
  return nodeSideEffectImportPatterns.some((pattern) => pattern.test(text));
}

function checkGuardPatternFixtures() {
  const blocked = [
    "import { readFileSync } from \"node:fs\";",
    "import { readFile } from \"node:fs/promises\";",
    "import { readFile } from \"fs/promises\";",
    "import \"node:fs\";",
    "const fs = require(\"node:fs/promises\");",
    "const fs = require(\"fs/promises\");",
    "const fs = await import(\"node:fs/promises\");",
    "const fs = await import(\"fs/promises\");",
    "import http from \"node:http\";",
    "const childProcess = require(\"child_process\");",
  ];
  const allowed = [
    "import path from \"node:path\";",
    "import type { RuntimeEvent } from \"../runtime/types.js\";",
    "import { readFixture } from \"../test-fixtures/fs-helper.js\";",
  ];

  for (const fixture of blocked) {
    if (!hasNodeSideEffectImport(fixture)) addError(`Architecture guard self-test failed to block: ${fixture}`);
  }
  for (const fixture of allowed) {
    if (hasNodeSideEffectImport(fixture)) addError(`Architecture guard self-test incorrectly blocked: ${fixture}`);
  }
}

function checkProtocolParity() {
  const swift = read("Picky/PickyAgentProtocol.swift").match(/pickyAgentProtocolVersion\s*=\s*"([^"]+)"/);
  const ts = read("agentd/src/protocol.ts").match(/PROTOCOL_VERSION\s*=\s*"([^"]+)"/);
  if (!swift) addError("Could not find Swift pickyAgentProtocolVersion.");
  if (!ts) addError("Could not find TypeScript PROTOCOL_VERSION.");
  if (!swift || !ts) return;

  const swiftVersion = swift[1];
  const tsVersion = ts[1];
  if (swiftVersion !== tsVersion) {
    addError(`Protocol version drift: Swift=${swiftVersion}, TypeScript=${tsVersion}.`);
  }

  const fixtureFiles = walk("contracts/protocol", (file) => file.endsWith(".json"));
  for (const file of fixtureFiles) {
    const json = JSON.parse(fs.readFileSync(file, "utf8"));
    if (json.protocolVersion && json.protocolVersion !== swiftVersion) {
      addError(`${rel(file)} uses protocolVersion=${json.protocolVersion}, expected ${swiftVersion}.`);
    }
    if (Array.isArray(json.supportedProtocolVersions)) {
      for (const version of json.supportedProtocolVersions) {
        if (version !== swiftVersion) addError(`${rel(file)} supports ${version}, expected ${swiftVersion}.`);
      }
    }
  }
}

function checkSwiftDomainImports() {
  const disallowed = new Set([
    "SwiftUI",
    "AppKit",
    "Combine",
    "AVFoundation",
    "ScreenCaptureKit",
    "Security",
    "Sparkle",
    "SwiftTerm",
  ]);
  const dirs = ["Picky/Domain", "Picky/Interaction"];
  for (const dir of dirs) {
    for (const file of walk(dir, (candidate) => candidate.endsWith(".swift"))) {
      const text = fs.readFileSync(file, "utf8");
      for (const match of text.matchAll(/^import\s+([A-Za-z0-9_]+)/gm)) {
        if (disallowed.has(match[1])) {
          addError(`${rel(file)} imports ${match[1]}; pure domain/interaction code must stay UI/effect-free.`);
        }
      }
    }
  }
}

function checkAgentdDomainImports() {
  const forbiddenPatterns = [
    { pattern: /from\s+["']ws["']/, reason: "transport adapter" },
    { pattern: /from\s+["']\.\.\/server(?:\.js)?["']/, reason: "server adapter" },
    { pattern: /from\s+["']\.\.\/application\//, reason: "application service" },
    { pattern: /from\s+["']\.\.\/session-supervisor(?:\.js)?["']/, reason: "session supervisor facade" },
  ];
  for (const file of walk("agentd/src/domain", (candidate) => candidate.endsWith(".ts") && !candidate.endsWith(".test.ts"))) {
    const text = fs.readFileSync(file, "utf8");
    if (hasNodeSideEffectImport(text)) addError(`${rel(file)} imports node side-effect module; domain code should remain pure.`);
    for (const { pattern, reason } of forbiddenPatterns) {
      if (pattern.test(text)) addError(`${rel(file)} imports ${reason}; domain code should remain pure.`);
    }
    if (/from\s+["']\.\.\/runtime\//.test(text)) {
      addWarning(`${rel(file)} imports runtime types. Keep this type-only and avoid runtime adapter coupling.`);
    }
  }
}

function checkSecretCodingKeys() {
  const file = "Picky/App/Settings/PickySettings.swift";
  const text = read(file);
  const allowed = new Set([
    "apiKey",
    "azureOpenAIAPIKey",
    "azureOpenAITTSAPIKey",
    "openAITTSAPIKey",
    "openAISTTAPIKey",
    "elevenLabsTTSAPIKey",
    "elevenLabsSTTAPIKey",
  ]);
  const found = new Set();
  for (const match of text.matchAll(/case\s+([A-Za-z0-9_]*(?:apiKey|APIKey|token|Token|secret|Secret)[A-Za-z0-9_]*)\b/g)) {
    found.add(match[1]);
  }
  for (const key of found) {
    if (!allowed.has(key)) {
      addError(`${file} persists secret-like CodingKey '${key}'. Store new secrets in Keychain-backed storage instead.`);
    }
  }
  if (found.size > 0) {
    addWarning(`${file} still contains legacy secret-like CodingKeys: ${[...found].sort().join(", ")}. Plan migration to Keychain-backed storage.`);
  }
}

function lineCount(file) {
  return fs.readFileSync(file, "utf8").split("\n").length;
}

function checkFileSizeRatchet() {
  // Hard ratchet: existing oversized files may only shrink. Growing past the
  // pinned ratchet, or adding a new file above the threshold, is an error.
  // When a refactor lowers a file below its ratchet, tighten the pin to the
  // new size + small headroom (or delete the entry once under the threshold).
  const thresholds = {
    swift: 1500,
    ts: 1500,
  };
  const allowlist = new Map([
    ["Picky/PickySessionViewModel.swift", 2970],
    ["Picky/CompanionManager.swift", 3040],
    ["Picky/Companion/CompanionPanelSettingsView.swift", 2150],
    ["Picky/Overlay/BlueCursorView.swift", 1830],
    ["Picky/App/Settings/PickySettings.swift", 1550],
    ["agentd/src/session-supervisor.ts", 3283],
    ["agentd/src/runtime/openai-realtime-main-runtime.ts", 2110],
  ]);

  const swiftFiles = walk("Picky", (file) => file.endsWith(".swift"));
  const tsFiles = walk("agentd/src", (file) => file.endsWith(".ts") && !file.endsWith(".test.ts") && !rel(file).includes("/__tests__/"));

  for (const file of [...swiftFiles, ...tsFiles]) {
    const relative = rel(file);
    const ext = relative.endsWith(".swift") ? "swift" : "ts";
    const lines = lineCount(file);
    const allowedMax = allowlist.get(relative);
    if (allowedMax !== undefined) {
      if (lines > allowedMax) addError(`${relative} grew to ${lines} lines, above ratchet ${allowedMax}. Shrink the file; do not raise the ratchet.`);
      continue;
    }
    if (lines > thresholds[ext]) {
      addError(`${relative} is ${lines} lines, above the ${ext} file-size limit ${thresholds[ext]}. Split by responsibility (docs/refactoring-principles.md) or, for a deliberate exception, add a pinned ratchet entry in checkFileSizeRatchet.`);
    }
  }
}

function main() {
  if (!exists("Picky/PickyAgentProtocol.swift") || !exists("agentd/src/protocol.ts")) {
    addError("Run this script from the repository root.");
  } else {
    checkGuardPatternFixtures();
    checkProtocolParity();
    checkSwiftDomainImports();
    checkAgentdDomainImports();
    checkSecretCodingKeys();
    checkFileSizeRatchet();
  }

  for (const warning of warnings) console.warn(`warning: ${warning}`);
  for (const error of errors) console.error(`error: ${error}`);

  if (errors.length > 0 || (strict && warnings.length > 0)) {
    console.error(`Architecture guard failed with ${errors.length} error(s), ${warnings.length} warning(s).`);
    process.exit(1);
  }

  console.log(`Architecture guard passed with ${warnings.length} warning(s).`);
}

main();
