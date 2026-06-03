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
    { pattern: /from\s+["']node:(?:fs(?:\/[^"']*)?|http|https|child_process)["']/, reason: "node side-effect module" },
    { pattern: /from\s+["']ws["']/, reason: "transport adapter" },
    { pattern: /from\s+["']\.\.\/server(?:\.js)?["']/, reason: "server adapter" },
    { pattern: /from\s+["']\.\.\/application\//, reason: "application service" },
    { pattern: /from\s+["']\.\.\/session-supervisor(?:\.js)?["']/, reason: "session supervisor facade" },
  ];
  for (const file of walk("agentd/src/domain", (candidate) => candidate.endsWith(".ts") && !candidate.endsWith(".test.ts"))) {
    const text = fs.readFileSync(file, "utf8");
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
  const thresholds = {
    swift: 1500,
    ts: 1500,
  };
  const allowlist = new Map([
    ["Picky/HUD/PickyHUDView.swift", 4300],
    ["Picky/PickySessionViewModel.swift", 3200],
    ["Picky/CompanionManager.swift", 3100],
    ["Picky/Companion/CompanionPanelSettingsView.swift", 2300],
    ["Picky/Overlay/BlueCursorView.swift", 1800],
    ["agentd/src/session-supervisor.ts", 3750],
    ["agentd/src/runtime/openai-realtime-main-runtime.ts", 2200],
  ]);

  const swiftFiles = walk("Picky", (file) => file.endsWith(".swift"));
  const tsFiles = walk("agentd/src", (file) => file.endsWith(".ts") && !file.endsWith(".test.ts") && !rel(file).includes("/__tests__/"));

  for (const file of [...swiftFiles, ...tsFiles]) {
    const relative = rel(file);
    const ext = relative.endsWith(".swift") ? "swift" : "ts";
    const lines = lineCount(file);
    const allowedMax = allowlist.get(relative);
    if (allowedMax !== undefined) {
      if (lines > allowedMax) addWarning(`${relative} grew to ${lines} lines, above ratchet ${allowedMax}.`);
      continue;
    }
    if (lines > thresholds[ext]) {
      addWarning(`${relative} is ${lines} lines, above new-file ${ext} warning threshold ${thresholds[ext]}.`);
    }
  }
}

function main() {
  if (!exists("Picky/PickyAgentProtocol.swift") || !exists("agentd/src/protocol.ts")) {
    addError("Run this script from the repository root.");
  } else {
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
