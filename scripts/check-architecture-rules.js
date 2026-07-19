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

function stripSwiftCommentsAndStrings(source) {
  let result = "";
  let index = 0;
  let blockCommentDepth = 0;
  let state = "code";

  while (index < source.length) {
    const character = source[index];
    const next = source[index + 1];
    const nextTwo = source.slice(index, index + 3);

    if (state === "code") {
      if (character === "/" && next === "/") {
        state = "lineComment";
        result += "  ";
        index += 2;
      } else if (character === "/" && next === "*") {
        state = "blockComment";
        blockCommentDepth = 1;
        result += "  ";
        index += 2;
      } else if (nextTwo === '\"\"\"') {
        state = "multilineString";
        result += "   ";
        index += 3;
      } else if (character === '\"') {
        state = "string";
        result += " ";
        index += 1;
      } else {
        result += character;
        index += 1;
      }
    } else if (state === "lineComment") {
      if (character === "\n") {
        state = "code";
        result += "\n";
      } else {
        result += " ";
      }
      index += 1;
    } else if (state === "blockComment") {
      if (character === "/" && next === "*") {
        blockCommentDepth += 1;
        result += "  ";
        index += 2;
      } else if (character === "*" && next === "/") {
        blockCommentDepth -= 1;
        if (blockCommentDepth === 0) state = "code";
        result += "  ";
        index += 2;
      } else {
        result += character === "\n" ? "\n" : " ";
        index += 1;
      }
    } else if (state === "string") {
      if (character === "\\") {
        result += "  ";
        index += 2;
      } else if (character === '\"') {
        state = "code";
        result += " ";
        index += 1;
      } else {
        result += character === "\n" ? "\n" : " ";
        index += 1;
      }
    } else if (state === "multilineString") {
      if (nextTwo === '\"\"\"') {
        state = "code";
        result += "   ";
        index += 3;
      } else {
        result += character === "\n" ? "\n" : " ";
        index += 1;
      }
    }
  }

  return result;
}

const permissionPromptAPIs = [
  { capability: "screenRecording", api: "CGRequestScreenCaptureAccess", pattern: /\bCGRequestScreenCaptureAccess\s*\(/ },
  { capability: "screenContent", api: "SCShareableContent.excludingDesktopWindows", pattern: /\bSCShareableContent\s*\.\s*excludingDesktopWindows\s*\(/ },
  { capability: "screenContent", api: "SCScreenshotManager.captureImage", pattern: /\bSCScreenshotManager\s*\.\s*captureImage\s*\(/ },
  { capability: "microphone", api: "AVCaptureDevice.requestAccess", pattern: /\bAVCaptureDevice\s*\.\s*requestAccess(?:\s*\(|\s*\{)/ },
  { capability: "speechRecognition", api: "SFSpeechRecognizer.requestAuthorization", pattern: /\bSFSpeechRecognizer\s*\.\s*requestAuthorization(?:\s*\(|\s*\{)/ },
  { capability: "accessibility", api: "AXIsProcessTrustedWithOptions", pattern: /\bAXIsProcessTrustedWithOptions\s*\(/ },
];

function checkPermissionPromptAPIUsage() {
  const gateway = "Picky/Context/PickySystemPermissionGateway.swift";
  const productionFiles = walk("Picky", (file) => file.endsWith(".swift"));
  const testFiles = [
    ...walk("PickyTests", (file) => file.endsWith(".swift")),
    ...walk("PickyUITests", (file) => file.endsWith(".swift")),
  ];

  for (const file of productionFiles) {
    const relative = rel(file);
    if (relative === gateway) continue;
    const source = stripSwiftCommentsAndStrings(fs.readFileSync(file, "utf8"));
    for (const { capability, api, pattern } of permissionPromptAPIs) {
      if (pattern.test(source)) {
        addError(`${relative} directly invokes ${api} for ${capability}; route permission prompts through ${gateway}.`);
      }
    }
  }

  for (const file of testFiles) {
    const relative = rel(file);
    const source = stripSwiftCommentsAndStrings(fs.readFileSync(file, "utf8"));
    for (const { capability, api, pattern } of permissionPromptAPIs) {
      if (pattern.test(source)) {
        addError(`${relative} invokes ${api} for ${capability}; unit tests must use PickySystemPermissionGateway fakes instead.`);
      }
    }
  }

  const blockedFixtures = [
    "let granted = CGRequestScreenCaptureAccess()",
    "let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)",
    "SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)",
    "AVCaptureDevice.requestAccess(for: .audio) { _ in }",
    "SFSpeechRecognizer.requestAuthorization { _ in }",
    "AXIsProcessTrustedWithOptions(options)",
  ];
  const allowedFixtures = [
    "// CGRequestScreenCaptureAccess()",
    "let documentation = \"SCScreenshotManager.captureImage(...)\"",
    "let hasAccess = CGPreflightScreenCaptureAccess()",
  ];
  for (const fixture of blockedFixtures) {
    const source = stripSwiftCommentsAndStrings(fixture);
    if (!permissionPromptAPIs.some(({ pattern }) => pattern.test(source))) {
      addError(`Permission prompt architecture guard self-test failed to block: ${fixture}`);
    }
  }
  for (const fixture of allowedFixtures) {
    const source = stripSwiftCommentsAndStrings(fixture);
    if (permissionPromptAPIs.some(({ pattern }) => pattern.test(source))) {
      addError(`Permission prompt architecture guard self-test incorrectly blocked: ${fixture}`);
    }
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

function checkInteractionReducerMutationBoundary() {
  const allowedFiles = new Set([
    "Picky/Interaction/PickyInteractionReducer.swift",
    "Picky/Interaction/PickyInteractionAnnotationReducer.swift",
  ]);
  for (const file of walk("Picky", (candidate) => candidate.endsWith(".swift"))) {
    const relative = rel(file);
    if (allowedFiles.has(relative)) continue;
    if (fs.readFileSync(file, "utf8").includes("PickyInteractionReducing")) {
      addError(`${relative} accesses PickyInteractionReducing; reducer mutation is restricted to the reducer implementation files.`);
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
    ["Picky/PickySessionViewModel.swift", 2879],
    ["Picky/CompanionManager.swift", 3000],
    ["Picky/Interaction/PickyInteractionReducer.swift", 1400],
    ["Picky/Companion/CompanionPanelSettingsView.swift", 2150],
    ["Picky/Overlay/BlueCursorView.swift", 1830],
    ["Picky/App/Settings/PickySettings.swift", 1550],
    ["agentd/src/session-supervisor.ts", 3000],
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
    checkPermissionPromptAPIUsage();
    checkProtocolParity();
    checkSwiftDomainImports();
    checkAgentdDomainImports();
    checkInteractionReducerMutationBoundary();
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
