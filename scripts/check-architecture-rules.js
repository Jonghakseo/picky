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

// Lower-only ratchet: count code references after stripping Swift comments and strings.
// When a refactor lowers this count, re-run the count, pin the new lower value here, and
// update the self-test. Never raise this baseline; new concrete HUD references must be removed.
// The sole HUD reference constructs an isolated preview fixture; mounted HUD
// production code receives only PickySessionCommands and registry child stores.
const HUD_SESSION_LIST_VIEW_MODEL_REFERENCE_BASELINE = 1;

// Session-shaped value types that must never be exposed as a public observable
// collection. Renaming one of these silently disarms the rule, so the self-test
// asserts every entry still resolves to a declared Swift type.
const SESSION_PROJECTION_VALUE_TYPES = [
  "SessionCard",
  "PickySessionCard",
  "PickySessionMessage",
  "PickyAgentSession",
  "PickySessionMetadata",
  "PickySessionDockProjection",
];
const sessionProjectionValueTypePattern = SESSION_PROJECTION_VALUE_TYPES.join("|");
const observableSessionArrayPattern = new RegExp(
  String.raw`^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^\n]*\))?\s*)*((?:(?:public|internal|package|fileprivate|private(?:\(set\))?|static|class|final|lazy|weak|unowned|nonisolated)\s+)*)(var|let)\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*\[\s*(${sessionProjectionValueTypePattern})\s*\](?!\s*\{)`,
  "gm",
);

// Lower-only ratchet across the whole app: a view may not subscribe to the
// global session façade. `Picky/HUD` has its own stricter reference ratchet;
// this one closes the gap for views outside that directory.
const FACADE_OBSERVATION_BASELINE = 1;
const facadeObservationPattern = /@(?:ObservedObject|EnvironmentObject|StateObject)(?:\s*\([^\n]*\))?\s+(?:(?:public|internal|package|fileprivate|private(?:\(set\))?|var|let|weak|unowned)\s+)*[A-Za-z_][A-Za-z0-9_]*\s*:\s*PickySessionListViewModel\b/g;

function facadeObservationViolations(source) {
  return [...stripSwiftCommentsAndStrings(source).matchAll(facadeObservationPattern)].map((match) => match[0]);
}

function facadeObservationCount() {
  return walk("Picky", (candidate) => candidate.endsWith(".swift"))
    .reduce((count, file) => count + facadeObservationViolations(fs.readFileSync(file, "utf8")).length, 0);
}

// Projection indexes are built from server-provided identity, which is not
// unique inside a session (real sessions repeat subagent `runId`). The trapping
// initializer turns that data into a launch crash, so it is banned here.
const trappingDictionaryPattern = /Dictionary\(\s*uniqueKeysWithValues:/g;

function trappingDictionaryViolations(source) {
  return [...stripSwiftCommentsAndStrings(source).matchAll(trappingDictionaryPattern)].map((match) => match[0]);
}

const PROJECTION_INDEX_DIRECTORY = "Picky/Sessions";

function projectionTrappingDictionaryFiles() {
  return walk(PROJECTION_INDEX_DIRECTORY, (candidate) => candidate.endsWith(".swift"))
    .filter((file) => trappingDictionaryViolations(fs.readFileSync(file, "utf8")).length > 0)
    .map((file) => rel(file));
}

// Lower-only ratchet: fixed microtask pumps make terminal/journal assertions
// order-dependent. New waits must express their condition (`waitUntil`).
// 138 is the independently recounted post-waitUntil ceiling. The baseline may
// shrink with future conversions, but must never rise above this proven count.
const SETTLE_PUMP_HARD_CEILING = 138;
const SETTLE_PUMP_BASELINE = 132;

function settlePumpBaselineExceedsCeiling(baseline) {
  return baseline > SETTLE_PUMP_HARD_CEILING;
}

function settlePumpCount() {
  return walk("agentd/src", (candidate) => candidate.endsWith(".test.ts"))
    .reduce((count, file) => count + (fs.readFileSync(file, "utf8").match(/\bsettle\(\)/g)?.length ?? 0), 0);
}

function observableSessionArrayViolations(source) {
  const stripped = stripSwiftCommentsAndStrings(source);
  if (!/@Observable\b/.test(stripped)) return [];
  return [...stripped.matchAll(observableSessionArrayPattern)]
    .filter((match) => !(match[1].trim() === "private" && match[2] === "var"))
    .map((match) => match[3]);
}

function hudSessionListViewModelReferenceCount() {
  return walk("Picky/HUD", (candidate) => candidate.endsWith(".swift"))
    .reduce((count, file) => count + (stripSwiftCommentsAndStrings(fs.readFileSync(file, "utf8")).match(/\bPickySessionListViewModel\b/g)?.length ?? 0), 0);
}

function hudSessionListViewModelReferenceExceedsBaseline(referenceCount) {
  return referenceCount > HUD_SESSION_LIST_VIEW_MODEL_REFERENCE_BASELINE;
}

function checkSessionProjectionRules() {
  for (const file of walk("Picky", (candidate) => candidate.endsWith(".swift"))) {
    const violations = observableSessionArrayViolations(fs.readFileSync(file, "utf8"));
    if (violations.length > 0) {
      addError(`${rel(file)} exposes non-private stored [${violations.join("], [")}] property from an @Observable store; project sessions through a private store boundary.`);
    }
  }

  const referenceCount = hudSessionListViewModelReferenceCount();
  if (hudSessionListViewModelReferenceExceedsBaseline(referenceCount)) {
    addError(`Picky/HUD concrete PickySessionListViewModel references grew to ${referenceCount}, above recorded baseline ${HUD_SESSION_LIST_VIEW_MODEL_REFERENCE_BASELINE}.`);
  }

  const observationCount = facadeObservationCount();
  if (observationCount > FACADE_OBSERVATION_BASELINE) {
    addError(`Picky views observing the concrete PickySessionListViewModel grew to ${observationCount}, above recorded baseline ${FACADE_OBSERVATION_BASELINE}. Observe the exact projection store instead of the global façade.`);
  }

  for (const file of projectionTrappingDictionaryFiles()) {
    addError(`${file} builds a projection index with Dictionary(uniqueKeysWithValues:). Server identity repeats inside a session, so use uniquingKeysWith (lastProjectionValueWins) instead of trapping at launch.`);
  }

  const settleCount = settlePumpCount();
  if (settleCount > SETTLE_PUMP_BASELINE) {
    addError(`agentd tests use settle() ${settleCount} times, above recorded baseline ${SETTLE_PUMP_BASELINE}. Await an explicit condition (waitUntil) instead of a fixed microtask pump.`);
  }
}

function checkSessionProjectionGuardFixtures() {
  // A rename that orphans an entry disarms the rule silently, which is exactly
  // how `SessionCard` -> `PickySessionCard` slipped past it once.
  const declaredTypePattern = (type) => new RegExp(String.raw`\b(?:struct|final class|class|enum|typealias)\s+${type}\b`);
  const swiftSources = walk("Picky", (candidate) => candidate.endsWith(".swift")).map((file) => fs.readFileSync(file, "utf8"));
  for (const type of SESSION_PROJECTION_VALUE_TYPES) {
    if (!swiftSources.some((source) => declaredTypePattern(type).test(source))) {
      addError(`Session-projection guard lists '${type}', which no longer names a declared Swift type. Update SESSION_PROJECTION_VALUE_TYPES after the rename so the rule keeps matching.`);
    }
  }

  for (const type of SESSION_PROJECTION_VALUE_TYPES) {
    const canonicalStore = `
    @Observable
    final class SessionStore {
      var values: [${type}] = []
    }
  `;
    if (observableSessionArrayViolations(canonicalStore).length !== 1) {
      addError(`Session-projection guard self-test failed to block a non-private Observable [${type}] array.`);
    }
  }

  const blockedFacadeObservers = `
    struct PanelView: View {
      @ObservedObject var viewModel: PickySessionListViewModel
      @EnvironmentObject private var injected: PickySessionListViewModel
      @StateObject var owned: PickySessionListViewModel
    }
  `;
  const allowedNarrowObserver = `
    struct PanelView: View {
      @ObservedObject var viewModel: PickySessionDockStore
      let commands: PickySessionCommands
    }
  `;
  if (facadeObservationViolations(blockedFacadeObservers).length !== 3) {
    addError("Session-projection guard self-test failed to block views observing the concrete fa\u00e7ade.");
  }
  if (facadeObservationViolations(allowedNarrowObserver).length !== 0) {
    addError("Session-projection guard self-test incorrectly blocked a narrow projection observer.");
  }
  if (facadeObservationCount() !== FACADE_OBSERVATION_BASELINE) {
    addError(`Session-projection guard self-test fa\u00e7ade observation count drifted from its recorded baseline ${FACADE_OBSERVATION_BASELINE}.`);
  }
  const blockedIndex = `
    func replace(_ runs: [PickySubagentRun]) {
      runsByID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
    }
  `;
  const allowedIndex = `
    func replace(_ runs: [PickySubagentRun]) {
      runsByID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: lastProjectionValueWins)
    }
  `;
  if (trappingDictionaryViolations(blockedIndex).length !== 1) {
    addError("Session-projection guard self-test failed to block a trapping projection index.");
  }
  if (trappingDictionaryViolations(allowedIndex).length !== 0) {
    addError("Session-projection guard self-test incorrectly blocked a duplicate-tolerant projection index.");
  }
  if (projectionTrappingDictionaryFiles().length !== 0) {
    addError(`Session-projection guard self-test found trapping projection indexes still present: ${projectionTrappingDictionaryFiles().join(", ")}.`);
  }

  if (settlePumpBaselineExceedsCeiling(SETTLE_PUMP_BASELINE)) {
    addError(`Session-projection guard self-test settle() baseline ${SETTLE_PUMP_BASELINE} exceeds the hard lower-only ceiling ${SETTLE_PUMP_HARD_CEILING}.`);
  }
  if (!settlePumpBaselineExceedsCeiling(SETTLE_PUMP_HARD_CEILING + 1)) {
    addError("Session-projection guard self-test failed to reject a raised settle() baseline.");
  }
  if (settlePumpCount() !== SETTLE_PUMP_BASELINE) {
    addError(`Session-projection guard self-test settle() count drifted from its recorded baseline ${SETTLE_PUMP_BASELINE}. Lower the pin when waits are converted; never raise it.`);
  }

  const blockedStore = `
    @Observable
    final class SessionStore {
      var cards: [SessionCard] = []
      var messages: [PickySessionMessage] = []
      var sessions: [PickyAgentSession] = []
    }
  `;
  const blockedAccessModifiedStore = `
    @Observable
    final class SessionStore {
      internal var cards: [SessionCard] = []
      public private(set) var messages: [PickySessionMessage] = []
      package var sessions: [PickyAgentSession] = []
      static var cachedCards: [SessionCard] = []
      private(set) var cachedMessages: [PickySessionMessage] = []
      private static var cachedSessions: [PickyAgentSession] = []
    }
  `;
  const allowedPrivateStore = `
    @Observable
    final class SessionStore {
      private var cards: [SessionCard] = []
    }
  `;
  const allowedNonObservableStore = `
    final class SessionStore {
      var cards: [SessionCard] = []
    }
  `;

  if (observableSessionArrayViolations(blockedStore).length !== 3) {
    addError("Session-projection guard self-test failed to block non-private Observable session arrays.");
  }
  if (observableSessionArrayViolations(blockedAccessModifiedStore).length !== 6) {
    addError("Session-projection guard self-test failed to block access-modified Observable session arrays.");
  }
  if (observableSessionArrayViolations(allowedPrivateStore).length !== 0) {
    addError("Session-projection guard self-test incorrectly blocked a private Observable session array.");
  }
  if (observableSessionArrayViolations(allowedNonObservableStore).length !== 0) {
    addError("Session-projection guard self-test incorrectly blocked a non-Observable store.");
  }
  if (hudSessionListViewModelReferenceCount() !== HUD_SESSION_LIST_VIEW_MODEL_REFERENCE_BASELINE) {
    addError("Session-projection guard self-test HUD reference count drifted from its recorded baseline.");
  }
  if (hudSessionListViewModelReferenceExceedsBaseline(HUD_SESSION_LIST_VIEW_MODEL_REFERENCE_BASELINE)) {
    addError("Session-projection guard self-test incorrectly rejected the HUD reference baseline.");
  }
  if (!hudSessionListViewModelReferenceExceedsBaseline(HUD_SESSION_LIST_VIEW_MODEL_REFERENCE_BASELINE + 1)) {
    addError("Session-projection guard self-test failed to reject HUD references above the baseline.");
  }
}

function checkTestWindowReleasePolicy() {
  // NSWindow/NSPanel default to isReleasedWhenClosed = true. A test that closes
  // one under ARC over-releases it, and the crash surfaces much later inside an
  // unrelated autorelease pool drain, blaming whichever test happens to be
  // running. Production window controllers already opt out; tests must too.
  for (const file of walk("PickyTests", (candidate) => candidate.endsWith(".swift"))) {
    const text = fs.readFileSync(file, "utf8");
    if (!/NS(Window|Panel)\s*\(/.test(text)) continue;
    if (!/\.close\(\)/.test(text)) continue;
    if (/isReleasedWhenClosed\s*=\s*false/.test(text)) continue;
    addError(
      `${rel(file)} closes an NSWindow/NSPanel without setting isReleasedWhenClosed = false. ` +
        "ARC then double-releases the window and crashes the test host during a later autorelease drain."
    );
  }
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
    ["Picky/PickySessionViewModel.swift", 2860],
    ["Picky/CompanionManager.swift", 2671],
    ["Picky/Interaction/PickyInteractionReducer.swift", 1400],
    ["Picky/Companion/CompanionPanelSettingsView.swift", 2150],
    ["Picky/Overlay/BlueCursorView.swift", 1830],
    ["Picky/App/Settings/PickySettings.swift", 1550],
    ["Picky/PickyAgentProtocol.swift", 1509],
    ["agentd/src/session-supervisor.ts", 3000],
    ["agentd/src/runtime/pi-sdk-runtime.ts", 1539],
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

function finish() {
  for (const warning of warnings) console.warn(`warning: ${warning}`);
  for (const error of errors) console.error(`error: ${error}`);

  if (errors.length > 0 || (strict && warnings.length > 0)) {
    console.error(`Architecture guard failed with ${errors.length} error(s), ${warnings.length} warning(s).`);
    process.exit(1);
  }

  console.log(`Architecture guard passed with ${warnings.length} warning(s).`);
}

function main() {
  if (process.argv.includes("--self-test=session-projection")) {
    checkSessionProjectionGuardFixtures();
    finish();
    return;
  }

  if (!exists("Picky/PickyAgentProtocol.swift") || !exists("agentd/src/protocol.ts")) {
    addError("Run this script from the repository root.");
  } else {
    checkGuardPatternFixtures();
    // Self-verification runs with the normal gate too: the pre-push hook never
    // passes `--self-test`, so rename detection and baseline drift would
    // otherwise never be enforced automatically.
    checkSessionProjectionGuardFixtures();
    checkPermissionPromptAPIUsage();
    checkProtocolParity();
    checkSwiftDomainImports();
    checkAgentdDomainImports();
    checkInteractionReducerMutationBoundary();
    checkSecretCodingKeys();
    checkSessionProjectionRules();
    checkTestWindowReleasePolicy();
    checkFileSizeRatchet();
  }

  finish();
}

main();
