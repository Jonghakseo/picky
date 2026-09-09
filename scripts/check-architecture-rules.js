#!/usr/bin/env node
/* eslint-disable no-console */

const { execFileSync } = require("node:child_process");
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

// Message types the daemon accepts or emits only for the local `picky` CLI and
// other external clients. Picky.app never sends or decodes them, so they are the
// only permitted TypeScript-only protocol members. Remove an entry when the app
// adopts the message; the guard errors if an entry is present in Swift.
const EXTERNAL_ONLY_PROTOCOL_COMMANDS = new Set([
  "awaitPickleSessionTerminal",
  "createPickleFromExternal",
  "submitMainFromExternal",
  "listPickySettings",
  "getPickySettings",
  "setPickySettings",
  "listDockGroups",
]);
const EXTERNAL_ONLY_PROTOCOL_EVENTS = new Set([
  "dockGroupsSnapshot",
  "pickleSessionsSnapshot",
  "pickleSessionUpdated",
  "externalEntryAck",
  "pickySettingsAck",
  "pushToTalkControlAck",
]);

// Reads the `type: z.literal("...")` discriminators of a zod discriminated union,
// following identifiers that reference schemas declared elsewhere in the file.
function zodUnionTypeLiterals(source, unionName) {
  const header = `export const ${unionName} = z.discriminatedUnion("type", [`;
  const start = source.indexOf(header);
  if (start === -1) return undefined;
  let index = start + header.length - 1;
  let depth = 0;
  for (; index < source.length; index += 1) {
    if (source[index] === "[") depth += 1;
    else if (source[index] === "]") {
      depth -= 1;
      if (depth === 0) break;
    }
  }
  const body = source.slice(start + header.length, index);
  const types = new Set();
  for (const match of body.matchAll(/type:\s*z\.literal\("([A-Za-z0-9_]+)"\)/g)) types.add(match[1]);
  for (const match of body.matchAll(/^\s*([A-Za-z0-9_]+),?\s*$/gm)) {
    const referenced = source.match(new RegExp(String.raw`const ${match[1]}\s*=[\s\S]*?type:\s*z\.literal\("([A-Za-z0-9_]+)"\)`));
    if (referenced) types.add(referenced[1]);
    else addError(`Could not resolve zod schema ${match[1]} referenced by ${unionName}.`);
  }
  return types;
}

// Raw values of a `String` enum, honoring `case a, b` lists and `case a = "raw"`.
function swiftStringEnumRawValues(source, enumName) {
  const match = source.match(new RegExp(String.raw`enum ${enumName}: String[^{]*\{([\s\S]*?)\n\}`));
  if (!match) return undefined;
  const values = new Set();
  for (const line of stripSwiftCommentsAndStrings(match[1]).split("\n")) {
    const caseLine = line.match(/^\s*case\s+(.+)$/);
    if (!caseLine) continue;
    for (const entry of caseLine[1].split(",")) {
      const name = entry.trim().match(/^([A-Za-z0-9_]+)(?:\s*=\s*(.*))?$/);
      if (!name) continue;
      if (name[2] !== undefined) {
        const raw = match[1].match(new RegExp(String.raw`case[^\n]*\b${name[1]}\s*=\s*"([^"]+)"`));
        values.add(raw ? raw[1] : name[1]);
      } else {
        values.add(name[1]);
      }
    }
  }
  return values;
}

// Event type strings matched by `PickyEvent.init(type:decoder:)` and its decode helpers.
function swiftDecodedEventTypes(source) {
  const start = source.indexOf("init(type: String, decoder: Decoder) throws");
  if (start === -1) return undefined;
  const end = source.indexOf("\n}\n", start);
  const types = new Set();
  for (const match of source.slice(start, end).matchAll(/^\s*case\s+((?:"[A-Za-z0-9_]+",?\s*)+):/gm)) {
    for (const literal of match[1].matchAll(/"([A-Za-z0-9_]+)"/g)) types.add(literal[1]);
  }
  return types;
}

function checkProtocolMessageSetParity() {
  const ts = read("agentd/src/protocol.ts");
  const swift = read("Picky/PickyAgentProtocol.swift");
  const tsCommands = zodUnionTypeLiterals(ts, "CommandEnvelopeSchema");
  const tsEvents = zodUnionTypeLiterals(ts, "EventEnvelopeVariantSchema");
  const swiftCommands = swiftStringEnumRawValues(swift, "PickyCommandType");
  const swiftEvents = swiftDecodedEventTypes(swift);
  if (!tsCommands || !tsEvents) addError("Could not locate CommandEnvelopeSchema/EventEnvelopeVariantSchema in agentd/src/protocol.ts.");
  if (!swiftCommands || !swiftEvents) addError("Could not locate PickyCommandType or the PickyEvent decoder in Picky/PickyAgentProtocol.swift.");
  if (!tsCommands || !tsEvents || !swiftCommands || !swiftEvents) return;

  const compare = (kind, tsSet, swiftSet, externalOnly) => {
    for (const type of swiftSet) {
      if (!tsSet.has(type)) addError(`Swift ${kind} "${type}" has no TypeScript schema in agentd/src/protocol.ts. Add both sides and a contracts/protocol fixture in the same change.`);
      if (externalOnly.has(type)) addError(`Protocol ${kind} "${type}" is listed as external-only but Picky.app defines it; remove it from the external-only allowlist.`);
    }
    for (const type of tsSet) {
      if (!swiftSet.has(type) && !externalOnly.has(type)) addError(`TypeScript ${kind} "${type}" is missing from Picky/PickyAgentProtocol.swift. Mirror it in Swift, or add it to the external-only allowlist if only the CLI uses it.`);
    }
    for (const type of externalOnly) {
      if (!tsSet.has(type)) addError(`External-only ${kind} "${type}" no longer exists in agentd/src/protocol.ts; remove it from the allowlist.`);
    }
  };
  compare("command", tsCommands, swiftCommands, EXTERNAL_ONLY_PROTOCOL_COMMANDS);
  compare("event", tsEvents, swiftEvents, EXTERNAL_ONLY_PROTOCOL_EVENTS);
}

function checkProtocolMessageSetParityFixtures() {
  const tsFixture = [
    "const ReferencedSchema = Base.extend({",
    '  type: z.literal("referenced"),',
    "});",
    'export const SampleSchema = z.discriminatedUnion("type", [',
    '  Base.extend({ type: z.literal("inline"), payload: z.array(z.string()) }),',
    "  ReferencedSchema,",
    "]);",
  ].join("\n");
  const tsTypes = zodUnionTypeLiterals(tsFixture, "SampleSchema");
  if (!tsTypes || [...tsTypes].sort().join(",") !== "inline,referenced") addError("Protocol parity self-test: zod union extraction drifted.");

  const swiftEnumFixture = [
    "enum SampleType: String, Codable, Equatable {",
    "    case alpha",
    "    case beta, gamma",
    '    case delta = "deltaRaw"',
    "    // case commented",
    "    var label: String { rawValue }",
    "}",
  ].join("\n");
  const swiftValues = swiftStringEnumRawValues(swiftEnumFixture, "SampleType");
  if (!swiftValues || [...swiftValues].sort().join(",") !== "alpha,beta,deltaRaw,gamma") addError("Protocol parity self-test: Swift enum extraction drifted.");

  const swiftDecoderFixture = [
    "    init(type: String, decoder: Decoder) throws {",
    "        switch type {",
    '        case "one": return .one',
    '        case "two", "three":',
    "            return .grouped",
    '        default: throw DecodingError.dataCorruptedError("unknown")',
    "        }",
    "    }",
    "}",
    "",
  ].join("\n");
  const swiftTypes = swiftDecodedEventTypes(swiftDecoderFixture);
  if (!swiftTypes || [...swiftTypes].sort().join(",") !== "one,three,two") addError("Protocol parity self-test: Swift event decoder extraction drifted.");
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

// Pi SDK packages may be imported only by the runtime adapter layer and the
// composition root. Application, domain, transport, and CLI code must go
// through `runtime/types.ts` so an SDK upgrade stays inside the adapter.
const PI_SDK_IMPORT_PATTERN = /["']@earendil-works\/[^"']+["']/;
const PI_SDK_IMPORT_ALLOWED_PREFIXES = ["agentd/src/runtime/", "agentd/src/bootstrap.ts"];

function checkPiSdkImportBoundary() {
  for (const file of walk("agentd/src", (candidate) => candidate.endsWith(".ts") && !candidate.endsWith(".test.ts") && !rel(candidate).includes("/__tests__/"))) {
    const relative = rel(file);
    if (PI_SDK_IMPORT_ALLOWED_PREFIXES.some((prefix) => relative.startsWith(prefix))) continue;
    if (PI_SDK_IMPORT_PATTERN.test(fs.readFileSync(file, "utf8"))) {
      addError(`${relative} may not mention an @earendil-works/* package outside agentd/src/runtime/ and bootstrap.ts. Route the dependency through runtime/types.ts or move the adapter into runtime/.`);
    }
  }
}

function checkPiSdkImportBoundaryFixtures() {
  const blocked = [
    'import { defineTool } from "@earendil-works/pi-coding-agent";',
    'import type { AutocompleteItem } from "@earendil-works/pi-tui";',
    'const runtime = await import("@earendil-works/pi-coding-agent");',
    'fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent/rpc-entry"))',
    'const pkg = "@earendil-works/pi-coding-agent"; await import(pkg);',
    'const sdk = require("@earendil-works/pi-ai");',
  ];
  const allowed = [
    'const label = "earendil";',
    'import { RuntimeCustomTool } from "../runtime/types.js";',
    'import { z } from "zod";',
  ];
  for (const fixture of blocked) {
    if (!PI_SDK_IMPORT_PATTERN.test(fixture)) addError(`Pi SDK boundary self-test failed to block: ${fixture}`);
  }
  for (const fixture of allowed) {
    if (PI_SDK_IMPORT_PATTERN.test(fixture)) addError(`Pi SDK boundary self-test incorrectly blocked: ${fixture}`);
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
const FACADE_OBSERVATION_BASELINE = 0;
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
    ["Picky/CompanionManager.swift", 2522],
    ["Picky/Interaction/PickyInteractionReducer.swift", 1400],
    ["Picky/Companion/CompanionPanelSettingsView.swift", 2150],
    ["Picky/Overlay/BlueCursorView.swift", 1830],
    ["Picky/App/Settings/PickySettings.swift", 1550],
    ["Picky/PickyAgentProtocol.swift", 1509],
    ["agentd/src/session-supervisor.ts", 1992],
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

  const groups = checkSwiftTypeGroupRatchet(swiftFiles, thresholds.swift);
  checkRatchetPinsDidNotIncrease(groups, thresholds);
}

// `Foo.swift` plus every `Foo+Role.swift` extension file form one type group.
// Extension files split compilation units, not state ownership, so the group
// total is the real facade size and must obey the same lower-only ratchet.
function swiftTypeGroupStem(relativePath) {
  const name = path.posix.basename(relativePath, ".swift");
  const plus = name.indexOf("+");
  return plus === -1 ? name : name.slice(0, plus);
}

const SWIFT_TYPE_GROUP_RATCHET = new Map([
  ["CompanionManager", 4014],
  ["PickySessionViewModel", 3667],
  ["PickyHUDOverlayManager", 2449],
  ["PickyHUDDockRailView", 1771],
  ["PickyAgentClientRouter", 1471],
]);

function swiftExtensionBlockLineCount(source, stem) {
  const lines = stripSwiftCommentsAndStrings(source).split("\n");
  const opener = new RegExp(`^extension\\s+${stem.replace(/[.*+?^${}()|[\\]\\]/g, "\\$&")}\\s*(?::[^\\{]*)?\\{`);
  let count = 0;
  for (let index = 0; index < lines.length; index += 1) {
    if (!opener.test(lines[index])) continue;
    let depth = 0;
    for (; index < lines.length; index += 1) {
      for (const character of lines[index]) {
        if (character === "{") depth += 1;
        if (character === "}") depth -= 1;
      }
      count += 1;
      if (depth === 0) break;
    }
  }
  return count;
}

function swiftTypeGroups(swiftFiles) {
  const groups = new Map();
  for (const file of swiftFiles) {
    const relative = rel(file);
    const stem = swiftTypeGroupStem(relative);
    const group = groups.get(stem) ?? { lines: 0, files: [], extensionContributors: [] };
    group.lines += lineCount(file);
    group.files.push(relative);
    groups.set(stem, group);
  }

  const stems = new Set([
    ...SWIFT_TYPE_GROUP_RATCHET.keys(),
    ...[...groups].filter(([, group]) => group.files.length >= 2).map(([stem]) => stem),
  ]);
  for (const stem of stems) {
    const group = groups.get(stem) ?? { lines: 0, files: [], extensionContributors: [] };
    for (const file of swiftFiles) {
      const relative = rel(file);
      if (swiftTypeGroupStem(relative) === stem) continue;
      const extensionLines = swiftExtensionBlockLineCount(fs.readFileSync(file, "utf8"), stem);
      if (extensionLines === 0) continue;
      group.lines += extensionLines;
      group.extensionContributors.push(`${relative} (${extensionLines} extension lines)`);
    }
    groups.set(stem, group);
  }
  return groups;
}

function checkSwiftTypeGroupRatchet(swiftFiles, threshold) {
  const groups = swiftTypeGroups(swiftFiles);
  for (const [stem, group] of groups) {
    if (group.files.length < 2 && !SWIFT_TYPE_GROUP_RATCHET.has(stem)) continue;
    const contributors = group.extensionContributors.length === 0 ? "" : ` Extension blocks: ${group.extensionContributors.join(", ")}.`;
    const allowedMax = SWIFT_TYPE_GROUP_RATCHET.get(stem);
    if (allowedMax !== undefined) {
      if (group.lines > allowedMax) addError(`Swift type group ${stem} grew to ${group.lines} lines across ${group.files.length} files, above ratchet ${allowedMax}. Move a coherent responsibility to its own owner; do not raise the ratchet or add another +Extension file.${contributors}`);
      continue;
    }
    if (group.lines > threshold) {
      addError(`Swift type group ${stem} spans ${group.lines} lines across ${group.files.join(", ")}, above the ${threshold}-line limit. +Extension files do not reduce facade size; split by owner or add a pinned entry in SWIFT_TYPE_GROUP_RATCHET.${contributors}`);
    }
  }
  return groups;
}

function checkSwiftTypeGroupRatchetFixtures() {
  const cases = [
    ["Picky/CompanionManager.swift", "CompanionManager"],
    ["Picky/Overlay/CompanionManager+AgentAnnotationOverlay.swift", "CompanionManager"],
    ["Picky/Sessions/Projection/PickySessionViewModel+DiffStore.swift", "PickySessionViewModel"],
    ["Picky/HUD/PickyHUDView.swift", "PickyHUDView"],
  ];
  for (const [input, expected] of cases) {
    const actual = swiftTypeGroupStem(input);
    if (actual !== expected) addError(`Type-group ratchet self-test: ${input} resolved to ${actual}, expected ${expected}.`);
  }
  const extensions = `
extension CompanionManager {
  func first() {}
  func second() {}
}
extension Other {
  func ignored() {}
}
`;
  if (swiftExtensionBlockLineCount(extensions, "CompanionManager") !== 4) {
    addError("Type-group ratchet self-test failed to count a top-level CompanionManager extension block.");
  }
}

function extractRatchetPins(source) {
  const entries = (text, prefix) => [...text.matchAll(/\[\s*["']([^"']+)["']\s*,\s*(\d+)\s*\]/g)]
    .map(([, name, pin]) => [`${prefix}:${name}`, Number(pin)]);
  const groups = source.match(/const SWIFT_TYPE_GROUP_RATCHET = new Map\(\[([\s\S]*?)\]\);/)?.[1] ?? "";
  const files = source.match(/function checkFileSizeRatchet\(\) \{[\s\S]*?const allowlist = new Map\(\[([\s\S]*?)\]\);/)?.[1] ?? "";
  return new Map([...entries(groups, "group"), ...entries(files, "file")]);
}

function ratchetPinChanges(baseSource, currentSource, isStillAboveThreshold) {
  const basePins = extractRatchetPins(baseSource);
  const currentPins = extractRatchetPins(currentSource);
  return [...basePins].flatMap(([entry, basePin]) => {
    const currentPin = currentPins.get(entry);
    if (currentPin !== undefined && currentPin > basePin) return [`${entry} pin increased from ${basePin} to ${currentPin}.`];
    if (currentPin === undefined && isStillAboveThreshold(entry)) return [`${entry} pin was removed while it remains above its size threshold.`];
    return [];
  });
}

function checkRatchetPinsDidNotIncrease(groups, thresholds) {
  const baseRef = process.env.PICKY_ARCH_GUARD_BASE_REF || (() => {
    try { return execFileSync("git", ["rev-parse", "--verify", "--quiet", "origin/main"], { cwd: root, encoding: "utf8" }).trim() ? "origin/main" : undefined; } catch { return undefined; }
  })();
  if (!baseRef) {
    console.log("ratchet pin history check skipped: no base ref");
    return;
  }
  let baseSource;
  try { baseSource = execFileSync("git", ["show", `${baseRef}:scripts/check-architecture-rules.js`], { cwd: root, encoding: "utf8" }); } catch {
    addError(`Unable to read ratchet pins from ${baseRef}.`);
    return;
  }
  const isStillAboveThreshold = (entry) => {
    const [kind, name] = entry.split(":", 2);
    if (kind === "group") return (groups.get(name)?.lines ?? 0) > thresholds.swift;
    const file = path.join(root, name);
    return fs.existsSync(file) && lineCount(file) > (name.endsWith(".swift") ? thresholds.swift : thresholds.ts);
  };
  for (const change of ratchetPinChanges(baseSource, read("scripts/check-architecture-rules.js"), isStillAboveThreshold)) addError(`Ratchet history check: ${change}`);
}

function checkRatchetPinFixtures() {
  const base = `const SWIFT_TYPE_GROUP_RATCHET = new Map([["Group", 10]]);\nfunction checkFileSizeRatchet() { const allowlist = new Map([["File.swift", 20]]); }`;
  const current = `const SWIFT_TYPE_GROUP_RATCHET = new Map([["Group", 11]]);\nfunction checkFileSizeRatchet() { const allowlist = new Map([]); }`;
  const pins = extractRatchetPins(base);
  if (pins.get("group:Group") !== 10 || pins.get("file:File.swift") !== 20) addError("Ratchet pin self-test failed to extract numeric pins.");
  const changes = ratchetPinChanges(base, current, (entry) => entry === "file:File.swift");
  if (changes.length !== 2) addError("Ratchet pin self-test failed to reject a raised or removed active pin.");
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

// The measured Hub settings focus path must not regain SwiftUI's attributed
// menu-item refresh. Other surfaces remain outside this deliberately narrow
// migration; their controls require their own evidence before replacement.
function hasUncachedHubPicker(source) {
  // A bare Picker defaults to a menu on macOS; checking only .menu would
  // allow the same expensive adapter back in through an omitted style.
  return /\bPicker\b|\.pickerStyle\s*\(\s*(?:\.menu\b|(?:SwiftUI\.)?MenuPickerStyle\s*\()/.test(stripSwiftCommentsAndStrings(source));
}

function checkHubSettingsMenuBoundary() {
  const file = "Picky/Hub/Pages/PickyHubSettingsPage.swift";
  if (hasUncachedHubPicker(read(file))) {
    addError(`${file}: use PickyNativeMenuPicker for menu choices. Focus-only updates must not resolve/rebuild menu labels; see docs/hub-focus-perf.md.`);
  }
  const blocked = ["Picker(selection: selection) { choices }", "Picker(choices).pickerStyle(.menu)", "view.pickerStyle(\n MenuPickerStyle()\n)", "view.pickerStyle(SwiftUI.MenuPickerStyle())"];
  const allowed = ["view.pickerStyle(.segmented)", "PickyNativeMenuPicker(title: title, selection: selection, options: options)", "// .pickerStyle(.menu)\nText(\".pickerStyle(.menu)\")"];
  if (blocked.some((source) => !hasUncachedHubPicker(source)) || allowed.some(hasUncachedHubPicker)) {
    addError("Hub settings menu boundary self-test failed.");
  }
}

function main() {
  if (process.argv.includes("--self-test=hub-focus")) {
    checkHubSettingsMenuBoundary();
    finish();
    return;
  }
  if (process.argv.includes("--self-test=session-projection")) {
    checkSessionProjectionGuardFixtures();
    finish();
    return;
  }

  if (!exists("Picky/PickyAgentProtocol.swift") || !exists("agentd/src/protocol.ts")) {
    addError("Run this script from the repository root.");
  } else {
    checkGuardPatternFixtures();
    checkSwiftTypeGroupRatchetFixtures();
    checkRatchetPinFixtures();
    // Self-verification runs with the normal gate too: the pre-push hook never
    // passes `--self-test`, so rename detection and baseline drift would
    // otherwise never be enforced automatically.
    checkSessionProjectionGuardFixtures();
    checkPermissionPromptAPIUsage();
    checkProtocolParity();
    checkProtocolMessageSetParityFixtures();
    checkProtocolMessageSetParity();
    checkSwiftDomainImports();
    checkAgentdDomainImports();
    checkPiSdkImportBoundaryFixtures();
    checkPiSdkImportBoundary();
    checkInteractionReducerMutationBoundary();
    checkSecretCodingKeys();
    checkSessionProjectionRules();
    checkTestWindowReleasePolicy();
    checkHubSettingsMenuBoundary();
    checkFileSizeRatchet();
  }

  finish();
}

main();
