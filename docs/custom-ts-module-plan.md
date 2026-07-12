# Custom TypeScript Module Plan

## Goal

Let advanced users override selected local Picky behavior with a user-owned TypeScript module, instead of entering provider-specific API keys in Picky settings. The first supported hooks are:

1. Voice STT/TTS providers
2. Speech text transforms around STT/TTS
3. Context packet filter/enricher
4. Prompt shaping hooks

Artifact/report post-processing is intentionally out of scope.

## Product constraints

- Keep Picky thin: Swift owns macOS capture, permissions, HUD, audio input/output, and session UI.
- Put custom logic in `picky-agentd`, not in Swift.
- Do not add deterministic workflow routing in Picky or custom hooks. No `if URL is Sentry then run Sentry flow` style behavior.
- Preserve local-first behavior. User modules run locally under the user's account.
- Preserve existing Local/OpenAI/Azure/ElevenLabs providers. Custom TS is an opt-in provider/hook layer.
- Keep default behavior unchanged when no custom module is configured.
- Treat privacy hooks differently from convenience hooks: if the user enables fail-closed context redaction, hook failure must not leak the original context into Pi prompts.

## Non-goals

- No SaaS plugin registry.
- No remote code loading.
- No sandbox guarantee in v1. The module is local trusted code and should be labelled as such in Settings.
- The module targets the existing Pi STT/TTS path first.
- No custom artifact/report post-processor in this phase.

## Proposed user experience

Settings → Voice (STT & TTS):

- STT provider: `Apple Speech`, `OpenAI`, `Azure OpenAI`, `ElevenLabs`, `Custom TypeScript`
- TTS provider: `macOS Speech`, `OpenAI`, `Azure OpenAI`, `ElevenLabs`, `Custom TypeScript`
- Custom module path: default `~/Library/Application Support/Picky/custom-module.ts`
- Hook toggles:
  - Speech text transforms
  - Context filter/enricher
  - Prompt shaping
- Context failure policy:
  - `Safe fallback`: log and use original context
  - `Privacy fail-closed`: log and replace with minimal context
- Buttons:
  - `Create/Open Template`
  - `Reload Module`
  - `Validate Module`

When `Custom TypeScript` is selected:

- Existing Azure API key fields are hidden for that capability.
- Picky shows a warning: the module runs locally with the user's account permissions.
- Validation errors are surfaced in Settings and agentd logs.

## Module API v1

User module default export:

```ts
import type { PickyCustomModule } from "./custom-module";

export default {
  voice: {
    stt: {
      async transcribe(input) {
        return { text: "recognized text" };
      },
    },

    tts: {
      async synthesize(input) {
        return {
          audio: new Uint8Array(),
          mimeType: "audio/wav",
        };
      },
    },

    normalizeTranscript(text, context) {
      return text.replaceAll("픽클", "Pickle");
    },

    prepareSpeech(text, context) {
      return text;
    },
  },

  context: {
    filter(packet) {
      return packet;
    },

    enrich(packet) {
      return packet;
    },
  },

  prompt: {
    extraInstructions(context) {
      return "";
    },

    modifyMainPrompt(prompt, context) {
      return prompt;
    },

    modifyPicklePrompt(prompt, context) {
      return prompt;
    },
  },
} satisfies PickyCustomModule;
```

### Type definitions

Add exported declarations in agentd for internal implementation, and copy a `custom-module.d.ts` file beside the generated user template. The template uses a relative type import (`./custom-module`) instead of `picky-agentd/custom-module` so editor/`tsc` support does not depend on package `exports` from a private bundled app runtime.

```ts
export interface PickyCustomModule {
  voice?: PickyVoiceHooks;
  context?: PickyContextHooks;
  prompt?: PickyPromptHooks;
}

export interface PickyVoiceHooks {
  stt?: {
    transcribe(input: PickyTranscribeInput): Promise<PickyTranscribeResult> | PickyTranscribeResult;
  };
  tts?: {
    synthesize(input: PickySynthesizeInput): Promise<PickySynthesizeResult> | PickySynthesizeResult;
  };
  normalizeTranscript?(text: string, context: PickySpeechTransformContext): Promise<string> | string;
  prepareSpeech?(text: string, context: PickySpeechTransformContext): Promise<string> | string;
}

export interface PickyTranscribeInput {
  audio: Uint8Array;
  format: "wav" | "pcm16";
  sampleRate: number;
  language?: string;
  keyterms: string[];
  signal: AbortSignal;
}

export interface PickyTranscribeResult {
  text: string;
  language?: string;
}

export interface PickySynthesizeInput {
  text: string;
  voice?: string;
  signal: AbortSignal;
}

export interface PickySynthesizeResult {
  audio: Uint8Array;
  mimeType: "audio/wav" | "audio/mpeg" | "audio/mp4" | "audio/aac";
}

export interface PickySpeechTransformContext {
  source: "voice" | "voice-follow-up" | "text" | "text-follow-up" | "system" | "cli";
  sessionId?: string;
  cwd?: string;
}

export interface PickyContextPacketPublic {
  id: string;
  source: "voice" | "text" | "voice-follow-up" | "text-follow-up" | "system" | "cli";
  transcript?: string;
  cwd?: string;
  activeApp?: { name?: string; bundleId?: string };
  activeWindow?: { title?: string };
  selectedText?: string;
  browser?: { url?: string; title?: string; selectedText?: string };
  screens?: Array<{ id: string; label?: string; path?: string }>;
}

export interface PickyContextHooks {
  filter?(packet: PickyContextPacketPublic): Promise<PickyContextPacketPublic | null> | PickyContextPacketPublic | null;
  enrich?(packet: PickyContextPacketPublic): Promise<PickyContextPacketPublic> | PickyContextPacketPublic;
}

export interface PickyPromptHooks {
  extraInstructions?(context: PickyPromptHookContext): Promise<string> | string;
  modifyMainPrompt?(prompt: PickyBuiltPrompt, context: PickyPromptHookContext): Promise<PickyBuiltPrompt> | PickyBuiltPrompt;
  modifyPicklePrompt?(prompt: PickyBuiltPrompt, context: PickyPromptHookContext): Promise<PickyBuiltPrompt> | PickyBuiltPrompt;
}

export interface PickyBuiltPrompt {
  text: string;
  imagePaths: string[];
}

export interface PickyPromptHookContext {
  source?: string;
  cwd?: string;
  sessionId?: string;
  contextPacket?: PickyContextPacketPublic;
}
```

Keep v1 types deliberately small. Internally, agentd can pass full context packets, but the public contract should emphasize safe, stable fields.

## Architecture

```text
Picky.app Swift
  ├─ captures microphone / screen / app context
  ├─ converts audio to WAV or PCM16
  ├─ sends custom voice/context settings to agentd
  ├─ sends transcribe/synthesize requests over local WebSocket
  └─ plays returned audio locally

picky-agentd Node/TS
  ├─ loads user TS module from local path
  ├─ validates hook shape
  ├─ runs hooks with timeout + abort signal
  ├─ redacts logs
  ├─ applies context/prompt hooks before Pi runtime
  └─ returns voice results to Swift
```

## Runtime loading strategy

Status: roadmap. The current repo still keeps `tsx` as a development dependency and packaged runtime deploys production dependencies only, so this section describes a future implementation requirement rather than behavior available today.

### Development

Current development agentd runs through `pnpm exec tsx src/index.ts`, so loading `.ts` is straightforward.

### Packaged app

Current packaged agentd runs `node dist/index.js` and intentionally does not require `tsx` or TypeScript at app launch. To support user `.ts` files in packaged builds, add a runtime transpiler dependency.

Recommended v1 choice: `tsx` as a production dependency of `picky-agentd`.

Rationale:

- Familiar ESM TypeScript loading behavior.
- Already used in development.
- Lower implementation risk than building a custom esbuild loader.

Required packaging change:

- Move `tsx` from `devDependencies` to `dependencies`, even if it is currently present transitively through another dependency. Relying on the transitive path is fragile.
- Ensure `scripts/package-agentd-runtime.sh` production deploy keeps the loader dependency.
- Keep the app launch command as `node dist/index.js`; `CustomModuleService` loads `.ts` modules through the bundled loader from inside agentd.
- Add a Phase 1 spike/test that runs the compiled `dist/index.js` path, loads a temp `custom-module.ts`, and proves the chosen loader API works without global `pnpm`, `tsx`, or TypeScript.
- Use cache-busted file URLs for reloads, for example by converting the expanded path with `pathToFileURL()` and adding a version query before dynamic import. The exact loader API must be locked by the packaged-runtime test rather than assumed from development mode.

## Settings model changes

Swift files:

- `Picky/App/Settings/PickySettings.swift`
- `Picky/Companion/CompanionPanelSettingsView.swift`
- `Picky/App/Settings/PickySettingsViewModel.swift` if needed

Add:

```swift
case customTypeScript
```

to `PickyVoiceProviderSelection`.

Add settings fields:

```swift
var customModulePath: String
var customSpeechTransformsEnabled: Bool
var customContextHooksEnabled: Bool
var customPromptHooksEnabled: Bool
var customContextFailurePolicy: PickyCustomContextFailurePolicy // safeFallback | privacyFailClosed
```

Default:

```text
~/Library/Application Support/Picky/custom-module.ts
```

Normalize path with tilde expansion, but do not require file existence on every save. Validation should be explicit via `Validate Module`, because a user may configure path before creating the file.

Provider selection drives only custom STT/TTS. Speech transforms, context hooks, and prompt hooks must have explicit persisted toggles so Picky can deterministically send `enabledHooks` and preserve default-unchanged behavior.

## App-daemon protocol changes

Swift:

- `Picky/PickyAgentProtocol.swift`
- `Picky/PickyAgentClient.swift`

agentd:

- `agentd/src/protocol.ts`
- `agentd/src/server.ts`
- `agentd/src/session-supervisor.ts` only where routing is needed

Mechanical protocol updates:

- Bump `PROTOCOL_VERSION` in `agentd/src/protocol.ts`.
- Bump `pickyAgentProtocolVersion` in `Picky/PickyAgentProtocol.swift` to match.
- Update Swift `PickyCommandType` and `PickyEvent`/decode cases for every new command/event.
- Update protocol redaction/log-summary helpers on both sides.

Add commands:

```ts
type ConfigureCustomModuleCommand = {
  type: "configureCustomModule";
  modulePath: string;
  enabledHooks: Array<"customSTT" | "customTTS" | "speechTransforms" | "context" | "prompt">;
  contextFailurePolicy: "safeFallback" | "privacyFailClosed";
  configVersion: string;
};

type ValidateCustomModuleCommand = {
  type: "validateCustomModule";
  modulePath: string;
  enabledHooks: Array<"customSTT" | "customTTS" | "speechTransforms" | "context" | "prompt">;
};

type TranscribeAudioCommand = {
  type: "transcribeAudio";
  audioBase64: string;
  audioFormat: "wav" | "pcm16";
  sampleRate: number;
  language?: string;
  keyterms?: string[];
};

type SynthesizeSpeechCommand = {
  type: "synthesizeSpeech";
  text: string;
  voice?: string;
};
```

Add events:

```ts
type CustomModuleStatusEvent = {
  type: "customModuleStatus";
  commandId?: string;
  configVersion?: string;
  status: "loaded" | "invalid" | "missing" | "disabled";
  message?: string;
};

type TranscriptionResultEvent = {
  type: "transcriptionResult";
  commandId: string;
  text: string;
  language?: string;
};

type SpeechSynthesisResultEvent = {
  type: "speechSynthesisResult";
  commandId: string;
  audioBase64: string;
  mimeType: string;
};
```

Use the existing envelope `id` as the canonical request correlation key. Result, validation status, and error events should reference it as `commandId`; avoid a second public `requestId` unless a future multi-result command requires it. `enabledHooks` must be derived deterministically from STT/TTS provider selection plus the explicit speech-transform/context/prompt toggles. Validation must check the enabled capabilities, not just module loadability; for example `customSTT` requires `voice.stt.transcribe`, and `customTTS` requires `voice.tts.synthesize`.

Log rules:

- Never log full audio payloads.
- Never log returned audio payloads.
- Log text length, not full text, for synthesize requests.
- Module path may be logged.

## Voice provider implementation

### STT bridge

Add Swift provider:

- `Picky/Companion/Dictation/AgentdTranscriptionProvider.swift`

Responsibilities:

- Implement `BuddyTranscriptionProvider`.
- Capture audio through existing `BuddyDictationManager` session path.
- Convert buffers to PCM16 or WAV using existing `BuddyPCM16AudioConverter` and `BuddyWAVFileBuilder`.
- On `requestFinalTranscript()`, send `transcribeAudio` to agentd.
- Request transcription through a central `PickyAgentClient` request/response broker and wait for `transcriptionResult` by command `id`/`commandId`.
- Apply timeout/fallback error.

Recommended v1 format: WAV.

Reason: existing Azure STT path already batches WAV at the end of recording, so this minimizes protocol complexity.

### TTS bridge

Add Swift provider:

- `Picky/Companion/Speech/AgentdSpeechPlaybackProvider.swift`

Responsibilities:

- Implement `PickySpeechPlaybackProvider`.
- Send `synthesizeSpeech` to agentd.
- Request synthesis through a central `PickyAgentClient` request/response broker and receive `speechSynthesisResult` by command `id`/`commandId`.
- Hop result handling and `AVAudioPlayer` state mutation back to `@MainActor`; `PickySpeechPlaybackProvider` is main-actor isolated while WebSocket events may arrive off the main actor.
- Play returned `audioBase64` with `AVAudioPlayer`.
- Fall back to `PickySystemSpeechPlaybackProvider` if configured as a fallback wrapper.

### Factory changes

Update:

- `BuddyTranscriptionProviderFactory.makeDefaultProvider`
- `PickySpeechPlaybackProviderFactory.makeDefaultProvider`

When selected provider is `customTypeScript`, return agentd-backed providers.

Caveat: current factories do not receive `PickyAgentClient`. They are called from `CompanionManager`, which has `agentClient`. Prefer adding explicit factory overloads or constructing agentd-backed providers in `CompanionManager.reloadVoiceProvidersFromSettings`, not as a global singleton.

## Speech text transform hooks

Add agentd module service methods:

```ts
normalizeTranscript(text, context): Promise<string>
prepareSpeech(text, context): Promise<string>
```

Application points:

1. After STT result is received from module, before Swift submits/follows up.
2. Before TTS synthesis, after Picky has chosen the visible/spoken reply text.

For non-custom STT/TTS providers, text transform hooks can still run if a module is configured and hooks are enabled. This gives users value even when they keep Apple Speech or macOS Speech.

Protocol options:

- Either bake transforms into `transcribeAudio` and `synthesizeSpeech` results for custom providers.
- Or add independent commands:

```ts
transformTranscript
prepareSpeechText
```

Recommended v1: independent commands only if transforms should apply to non-custom providers. Otherwise keep transforms internal to custom STT/TTS first.

Given requested scope includes separate speech text transforms, implement independent commands so transforms are provider-agnostic.

## Context filter/enricher hooks

agentd is the right application point because context packets already cross into agentd for routing/prompt construction.

Modify around:

- `agentd/src/session-supervisor.ts`
- `agentd/src/prompt-builder.ts`

Add a `CustomModuleService.applyContextHooks(packet)` before building prompts for:

- `routeTask`
- `startPickle` / handoff context
- main agent prompt
- steer/follow-up context where available

The Pi SDK main runtime is the sole main runtime for custom hooks.

Rules:

- Hook may return a modified packet.
- If hook returns `null`, treat as a blocked context and continue with minimal context rather than crashing.
- Re-validate the returned object with `PickyContextPacketSchema` where possible.
- Hook failure follows the persisted policy:
  - `safeFallback`: log compactly and use the original packet.
  - `privacyFailClosed`: log compactly and replace with a minimal packet that preserves source/transcript/cwd but drops browser details, selected text, screenshots, and window titles.
- Default policy should be `safeFallback` for compatibility, but Settings should recommend `privacyFailClosed` when the user enables context hooks primarily for redaction.

Security/privacy use case:

- Redact selected window titles, URLs, selected text, screenshots metadata.
- Add local-only hints such as project nickname or preferred cwd labels.

Explicitly prohibited in docs/template:

- Do not perform routing decisions here.
- Do not call remote services with screenshots unless the user intentionally coded that behavior.

Technical guardrail for v1:

- Context hooks should receive a public, redaction-oriented context subset, not the full internal packet object by reference.
- Hook output must be schema-validated and normalized by agentd before use.
- Add a single sanitizer/normalizer entry point before any prompt construction, session context persistence, handoff prompt creation, or child agentd handoff. This entry point maps internal context → `PickyContextPacketPublic` → hook result → internal context, including top-level `selectedText`.
- Treat context hooks as privacy/context shaping only; do not expose APIs from this hook layer that can create sessions, steer Pickles, call MCPs, or execute tools.

## Prompt shaping hooks

Application point:

- `agentd/src/prompt-builder.ts` returns `BuiltPrompt`.
- `session-supervisor.ts` can call prompt hooks immediately after prompt construction and before runtime delivery.

Hooks:

```ts
prompt.extraInstructions(context)
prompt.modifyMainPrompt(prompt, context)
prompt.modifyPicklePrompt(prompt, context)
```

Recommended v1 behavior:

- `extraInstructions(context)` is evaluated per prompt and appended to that prompt before delivery. Do not map it onto the existing daemon `mainExtraInstructions` bootstrap-only path, because that path is injected once when the main handle is created and would become stale for context-sensitive hooks.
- `modifyMainPrompt` and `modifyPicklePrompt` receive the existing full prompt and may return a full edited prompt. Users who only want append-only behavior can implement that by returning `{ ...prompt, text: prompt.text + "\n\n" + extra }`.
- Re-validate result shape.
- If hook fails, fall back to the unmodified prompt.

Do not add deterministic workflow routing here. Prompt hooks should shape language, context formatting, and constraints, not decide task execution paths.

Technical guardrail for v1:

- Prompt hooks should not receive tool/MCP/session-control capabilities.
- The default template must explicitly warn against URL/provider-based workflow routing.
- Full prompt editing is intentionally allowed for advanced users, but deterministic workflow routing remains unsupported by Picky; the hook layer is user-owned text shaping, not a Picky router.
- Tests should include a prompt hook that removes image paths, appends to the existing prompt, and returns an invalid object; verify agentd accepts valid full edits and falls back safely for invalid output.

## CustomModuleService design

Create:

- `agentd/src/custom-module/custom-module-service.ts`
- `agentd/src/custom-module/types.ts`
- `agentd/src/custom-module/template.ts` or `templates/custom-module.ts`

Responsibilities:

- Track configured module path, enabled hooks, and context failure policy.
- Load/reload module with cache-busting import URL.
- Validate default export shape.
- Provide safe wrappers:
  - `transcribeAudio`
  - `synthesizeSpeech`
  - `normalizeTranscript`
  - `prepareSpeech`
  - `applyContextHooks`
  - `applyPromptHooks`
- Apply timeout and abort signals.
- Emit status events.
- Validate enabled capabilities, not only module loadability.

Composition point:

- Instantiate `CustomModuleService` in `agentd/src/bootstrap.ts` inside `composeAgentdServices()`.
- Pass the same service to `AgentdServer` for configure/validate/voice/transform commands.
- Pass it to `SessionSupervisor` for context and prompt hooks.
- In child agentd mode, initialize from environment/config as well as from explicit configure commands so per-Pickle daemons can apply the same hooks.
- Child creation must use a `configVersion` ack/handshake: the router sends or injects the latest config, waits until the child reports the matching version as loaded/disabled, and only then sends `createPickleFromHandoff`.

Suggested timeout defaults:

- STT: 60s
- TTS: 30s
- text transform: 5s
- context hook: 5s
- prompt hook: 5s

## Failure behavior

Voice:

- Custom STT failure: surface dictation error to user. Do not silently submit empty transcript.
- Custom TTS failure: fall back to macOS Speech if wrapped in fallback provider.

Transforms/context/prompt:

- Speech transform failure should not block core Picky operation; log compact error and use original text.
- Prompt hook failure should not block core Picky operation; log compact error and use the unmodified prompt.
- Context hook failure must follow `customContextFailurePolicy`: use original context for `safeFallback`, or minimal redacted context for `privacyFailClosed`.

Module load:

- Missing/invalid module: custom provider reports not configured.
- Existing non-custom providers remain usable.

## Test plan

### agentd unit tests

Add tests for:

- Loads `.ts` custom module from temp directory.
- Loads `.ts` custom module through the compiled `node dist/index.js` path with only packaged production dependencies available.
- Loads `.ts` module with a relative import and reloads it with cache-busting.
- Rejects module without default object.
- Rejects validation when enabled capabilities are missing, for example `customSTT` without `voice.stt.transcribe`.
- Redacts audio/text payloads from logs.
- `transcribeAudio` returns text.
- `synthesizeSpeech` returns audio/mimeType.
- Transform hook modifies text.
- Transform hook failure falls back to original text.
- Context hook redacts browser fields and top-level `selectedText`, then validates returned packet.
- Context hook failure uses original packet in `safeFallback` mode.
- Context hook failure uses minimal redacted packet in `privacyFailClosed` mode.
- `privacyFailClosed` prevents original browser, selected text, ink marks, screenshots, and window-title data from reaching main, handoff, steer/follow-up, and child prompt construction paths.
- Prompt hook appends/modifies prompt.
- Prompt hook failure falls back to original prompt.
- Prompt `extraInstructions(context)` is evaluated per prompt, not cached in the bootstrap-only path.
- Custom module validation/status events include `commandId` so overlapping validate/reload/configure requests cannot be confused.
- Custom module configuration is available in per-Pickle child agentd before `createPickleFromHandoff` runs, verified by matching `configVersion` ack.

Likely files:

- `agentd/src/custom-module/custom-module-service.test.ts`
- `agentd/src/protocol.test.ts`
- `agentd/src/server.test.ts`
- targeted `session-supervisor.test.ts` for context/prompt integration

### Swift tests

Add/update:

- `PickyTests/PickySettingsPolishTests.swift`
- `PickyTests/PickyAgentClientTests.swift`
- `PickyTests/PickyCompanionManagerTests.swift`

Test cases:

- Settings decode default path/backward compatibility.
- Settings persist explicit toggles for speech transforms, context hooks, prompt hooks, and context failure policy.
- Provider picker includes Custom TypeScript for STT and TTS.
- Custom provider selection constructs agentd-backed provider.
- Audio command logs redact payload in client summary.
- `PickyAgentClient`/router exposes a single-consumer typed request/response broker so voice providers do not independently consume `agentClient.events`.
- TTS provider handles successful synthesize event and fallback failure path on `@MainActor`.
- Router/pool propagates custom module configuration to child agentd clients and waits for matching config ack before creating delegated Pickles.

### Manual smoke

1. Create `~/Library/Application Support/Picky/custom-module.ts` from template.
2. Select Custom TypeScript for STT only.
3. Speak a short prompt and confirm transcript comes from module.
4. Select Custom TypeScript for TTS only.
5. Trigger a quick reply and confirm custom audio plays.
6. Keep Local STT/TTS but enable transform hooks and confirm text normalization.
7. Add context redaction hook and verify prompt/log snapshot omits redacted data.
8. Force the context hook to throw with `privacyFailClosed` enabled and verify sensitive context is not sent.
9. Add prompt `extraInstructions` and confirm main prompt behavior changes per turn.
10. Delegate a Pickle and confirm child agentd applies context/prompt hooks before `createPickleFromHandoff`.

## Implementation phases

### Phase 1 — Agentd loader and protocol foundation

Files:

- `agentd/package.json`
- `agentd/src/custom-module/types.ts`
- `agentd/src/custom-module/custom-module-service.ts`
- `agentd/src/protocol.ts`
- `agentd/src/server.ts`
- `agentd/src/bootstrap.ts`
- template-side `custom-module.d.ts` resource

Steps:

1. Add explicit runtime TS loader dependency.
2. Generate or copy template-side `custom-module.d.ts` and make the default template import types from `./custom-module`.
3. Implement compiled-runtime spike/test for loading a temp `.ts` module from `node dist/index.js`, including relative imports and cache-busted reload.
4. Implement module service with load/validate/status.
5. Instantiate `CustomModuleService` in `composeAgentdServices()` and pass it to `AgentdServer` and `SessionSupervisor`.
6. Add configure/validate protocol commands.
7. Add status events.
8. Bump protocol versions in agentd and Swift.
9. Add tests.

### Phase 2 — Voice STT/TTS bridge

Files:

- `Picky/PickyAgentProtocol.swift`
- `Picky/PickyAgentClient.swift`
- `Picky/Companion/Dictation/AgentdTranscriptionProvider.swift`
- `Picky/Companion/Speech/AgentdSpeechPlaybackProvider.swift`
- `Picky/CompanionManager.swift`
- `agentd/src/protocol.ts`
- `agentd/src/server.ts`

Steps:

1. Add `transcribeAudio` and `synthesizeSpeech` protocol using envelope `id`/event `commandId` correlation.
2. Update Swift command/event enums and log summaries.
3. Add a typed request/response broker in `PickyAgentClient`/router so `CompanionManager.bindAgentEvents` remains the single consumer that fans out correlated results.
4. Use the broker from Swift voice providers instead of independently iterating `agentClient.events`.
5. Ensure `AgentdSpeechPlaybackProvider` handles response callbacks and audio player mutations on `@MainActor`.
6. Wire provider selection to settings.
7. Keep fallback to local TTS for failed custom TTS.
8. Add tests.

### Phase 3 — Speech transform hooks

Files:

- `agentd/src/custom-module/custom-module-service.ts`
- `agentd/src/protocol.ts`
- `Picky/PickyAgentProtocol.swift`
- `Picky/PickyAgentClient.swift`
- `Picky/CompanionManager.swift`
- `Picky/BuddyDictationManager.swift` if transform must happen before submission callbacks

Steps:

1. Add `transformTranscript` and `prepareSpeechText` commands/events using envelope `id`/event `commandId` correlation.
2. Update Swift command/event enums and log summaries.
3. Route transform requests through the same typed request/response broker.
4. Apply transcript normalization before context submission/follow-up.
5. Apply speech preparation before local/custom TTS playback.
6. Add provider-agnostic tests.

### Phase 4 — Context hooks

Files:

- `agentd/src/session-supervisor.ts`
- `agentd/src/prompt-builder.ts` if helper signatures need context
- `agentd/src/custom-module/custom-module-service.ts`

Steps:

1. Add a single context sanitizer/normalizer entry point and apply it before prompt construction, session context persistence, handoff prompt creation, and child agentd handoff.
2. Pass only the public context subset to user hooks and normalize the result back into an internal packet, including top-level `selectedText`.
3. Re-validate returned context packet.
4. Apply `safeFallback` vs `privacyFailClosed` failure policy. `safeFallback` is the default.
5. Add redaction/enrichment/fail-closed tests.

### Phase 5 — Prompt hooks

Files:

- `agentd/src/session-supervisor.ts`
- `agentd/src/prompt-builder.ts`
- `agentd/src/custom-module/custom-module-service.ts`

Steps:

1. Add per-prompt `extraInstructions` integration after prompt construction and before runtime delivery.
2. Add main prompt modification hook with full prompt edit support.
3. Add Pickle prompt modification hook with full prompt edit support.
4. Validate prompt result; invalid output falls back to the original prompt.
5. Add tests for main and Pickle prompt paths, including full edit and append-only-by-user examples.

### Phase 6 — Settings UI and template polish

Files:

- `Picky/App/Settings/PickySettings.swift`
- `Picky/Companion/CompanionPanelSettingsView.swift`
- `Picky/App/Settings/PickySettingsStore.swift`
- `Picky/CompanionManager.swift`
- `Picky/PickyAgentClientRouter.swift`
- `Picky/PickyAgentDaemonPool.swift`
- `Picky/PickyAgentDaemonLauncher.swift`
- template file under `agentd` or app resources

Steps:

1. Add UI for module path, explicit hook toggles, context failure policy, and warnings.
2. Add create/open template behavior.
3. Add validate/reload buttons.
4. Send `configureCustomModule` when settings change.
5. Persist latest custom module configuration in the router/pool layer and send it to every newly spawned child agentd before `createPickleFromHandoff` or manual Pickle creation.
6. Pass module path/enabled hooks/failure policy/configVersion through child daemon environment when possible so child startup is deterministic before WebSocket commands arrive.
7. Wait for the child `customModuleStatus.configVersion` ack before sending the first child session command.
8. Display module status.

## Implementation decisions

Decisions:

1. Speech transform hooks run when `customSpeechTransformsEnabled` is true, even if STT/TTS providers are not custom.
2. Use one shared module path for all hooks in v1.
3. Context hooks are disabled by default and require `customContextHooksEnabled`; default failure policy is `safeFallback`.
4. Custom hooks run only against the Pi SDK main runtime.
5. Prompt hooks support full prompt editing in v1. Users who only want append-only behavior receive the existing prompt and can append to it in their hook.
6. The user template uses a local `custom-module.d.ts` with a relative `./custom-module` import, not a `picky-agentd/custom-module` package export.

## Acceptance criteria

- Existing users see no behavior change without selecting/configuring Custom TypeScript or enabling hook toggles.
- A packaged Picky build can load a local `.ts` module without requiring the user to install `pnpm`, `tsx`, or TypeScript globally, proven by a compiled-runtime test.
- The generated template includes a local `custom-module.d.ts` and its relative type import resolves in editors/tests without package export setup.
- Custom STT can return transcript through the current PTT flow.
- Custom TTS can return audio and Picky can play it.
- Transcript and speech text transforms can run independently of custom STT/TTS providers when explicitly enabled.
- Context hooks can redact/enrich packets before prompt construction and can fail closed without leaking original sensitive context.
- Prompt hooks can add/modify main and Pickle prompts without breaking runtime delivery.
- Per-Pickle child agentd receives custom module configuration before creating delegated Pickles.
- Hook failures are contained and visible in logs/status.
- Audio payloads and secrets are not logged.
