# OpenAI Realtime 메인 에이전트 옵션 전환 계획

Status: draft, user decisions incorporated  
Target: Picky 메인 에이전트의 음성 입력부터 음성 출력까지 `gpt-realtime-2` 또는 `gpt-realtime-1.5` 기반 옵션으로 제공하되, 기존 Pi 메인/사이드 구조는 기본값으로 보존한다.

## 1. 목표

Picky 설정 탭에서 사용자가 선택할 수 있는 두 가지 메인 에이전트 모드를 제공한다.

1. **Pi main agent (current)**
   
   - 현재 구조 유지.
   
   - Swift `BuddyDictationManager`가 STT를 수행한다.
   
   - `picky-agentd`의 Pi `mainRuntime`이 판단한다.
   
   - Swift `PickySpeechPlaybackProvider`가 TTS를 수행한다.

2. **OpenAI Realtime main agent (optional)**
   
   - 메인 음성 입력, 모델 판단, 함수 호출, 음성 출력까지 OpenAI Realtime 세션이 담당한다.
   
   - 모델은 `gpt-realtime-2`를 기본값으로 하되 `gpt-realtime-1.5`도 선택 가능하게 한다.
   
   - 사이드 에이전트는 계속 Pi SDK 런타임을 사용한다.
   
   - 사이드 HUD card 위에 hover한 상태에서 말하는 follow-up은 현재처럼 side Pi agent에게 직접 전달한다. 즉, Realtime main을 거치지 않는다.
   
   - hover 대상이 없는 메인 요청에서 복잡한 작업 위임, 사이드 세션 목록 조회, 사이드 세션 조향이 필요하면 Realtime function calling으로 수행한다.

## 2. 비목표

- 사이드 에이전트를 OpenAI Realtime으로 바꾸지 않는다.
- Pi skills/MCP/tools를 Picky에 복제하지 않는다.
- URL/app 이름 기반 deterministic workflow routing을 추가하지 않는다.
- OpenAI/Azure OpenAI API key를 로그, 프로세스 인자, crash log에 노출하지 않는다. 단, 사용자가 설정 탭에 입력한 key는 현재 Azure STT 설정과 동일하게 로컬 settings 저장 방식으로 보존한다.
- Realtime 옵션을 기본값으로 켜지 않는다. 명시적 opt-in만 허용한다.

## 3. 공식 문서 근거

- `gpt-realtime-2`는 realtime voice interaction용 모델이며 function calling과 configurable reasoning effort를 지원한다.  
  Reference: https://developers.openai.com/api/docs/models/gpt-realtime-2
- Realtime API는 stateful `Session`, `Conversation`, `Response`로 구성되고, `session.update`, `conversation.item.create`, `input_audio_buffer.append`, `input_audio_buffer.commit`, `response.create` 등의 client event와 `response.output_audio.delta`, `response.output_audio_transcript.delta`, `response.done` 등의 server event로 동작한다.  
  Reference: https://developers.openai.com/docs/guides/realtime-conversations
- 서버-투-서버 Realtime 연동은 WebSocket으로 연결하고 백엔드에서 API key를 보관하는 방식을 안내한다.  
  Reference: https://developers.openai.com/docs/guides/realtime-websocket
- Realtime session은 최대 60분이며, audio output은 transcript를 동반하고, `output_modalities`는 현재 `audio` 또는 `text` 중 하나를 선택한다. 따라서 “audio + text” UX는 `output_modalities: ["audio"]`와 `response.output_audio_transcript.*` 이벤트를 함께 사용해 구현한다. input audio transcription은 모델이 듣는 native audio와 별개인 ASR 결과이므로 UI 참고용으로만 취급해야 한다.  
  Reference: https://developers.openai.com/api/reference/resources/realtime/server-events
- Azure OpenAI Realtime은 WebSocket `/realtime` endpoint를 제공하며, GA 경로는 `/openai/v1/realtime?model=<deployment>`, preview 경로는 `/openai/realtime?api-version=<version>&deployment=<deployment>` 형식을 사용한다. `gpt-realtime-1.5`도 Azure 지원 모델 목록에 포함된다.  
  Reference: https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/realtime-audio-websockets

## 4. 현재 구조

```text
Picky.app
  ├─ BuddyDictationManager
  │    └─ AVAudioEngine -> Apple/Azure STT -> final transcript
  ├─ PickyContextPacket capture
  ├─ PickyAgentClient routeTask/followUp
  └─ PickySpeechPlaybackProvider
       └─ local/Azure/ElevenLabs TTS

picky-agentd
  ├─ side runtime: PiSdkRuntime
  └─ main runtime: PiSdkRuntime
       ├─ picky_handoff
       ├─ picky_side_sessions
       └─ picky_side_steer
```

주요 파일:

- 앱 음성 입력: `Picky/BuddyDictationManager.swift`
- 앱 음성 출력: `Picky/Companion/Speech/PickySpeechPlaybackProvider.swift`
- 앱 interaction state/effects: `Picky/Interaction/`
- 앱 agentd client/protocol: `Picky/PickyAgentClient.swift`, `Picky/PickyAgentProtocol.swift`
- agentd composition: `agentd/src/index.ts`
- session orchestration: `agentd/src/session-supervisor.ts`
- runtime interface: `agentd/src/runtime/types.ts`
- Pi runtime: `agentd/src/runtime/pi-sdk-runtime.ts`
- main prompt/tool bridge: `agentd/src/prompt-builder.ts`, `agentd/src/application/handoff-tool.ts`

## 5. 목표 구조

```text
Picky.app
  ├─ MainAgentMode setting
  │    ├─ piCurrent
  │    └─ openAIRealtime
  │
  ├─ Pi current mode
  │    ├─ BuddyDictationManager
  │    ├─ agentd routeTask
  │    └─ PickySpeechPlaybackProvider
  │
  └─ Realtime mode
       ├─ Main-agent turn
       │    ├─ RealtimeVoiceInputManager
       │    │    └─ AVAudioEngine -> PCM16 24kHz mono chunks -> local agentd WS
       │    ├─ RealtimeAudioPlaybackEngine
       │    │    └─ OpenAI/Azure output_audio.delta PCM playback
       │    └─ PickyContextPacket capture
       │         └─ context/images sent to agentd before response.create
       └─ Side-card hover follow-up
            └─ BuddyDictationManager -> followUp command -> side Pi agent

picky-agentd
  ├─ sideRuntime: PiSdkRuntime
  │    └─ HUD side sessions, Pi tools, skills, MCP, terminal resume
  │
  └─ mainRuntime: selectable
       ├─ PiSdkRuntime
       └─ OpenAIRealtimeMainRuntime
            ├─ OpenAI/Azure OpenAI Realtime WebSocket
            ├─ session.update instructions/audio/tools
            ├─ input_audio_buffer append/commit
            ├─ function calling
            │    ├─ picky_handoff -> Pi side agent 생성
            │    ├─ picky_side_sessions
            │    ├─ picky_side_steer
            │    └─ picky_pointer_overlay (Realtime mode 전용 권장)
            └─ output audio + transcript relay to Picky.app
```

## 6. 설정 UX

Settings > Main Agent 또는 Voice 섹션에 다음을 추가한다.

### 6.1 Main agent runtime

Radio/Picker:

- `Pi (current, local-first)`
- `OpenAI Realtime (voice-to-voice, sends main-agent voice/context to OpenAI or Azure OpenAI)`

설명 문구:

> OpenAI Realtime mode sends microphone audio, captured screen context, selected text, browser metadata, and screenshots to OpenAI or Azure OpenAI for main-agent turns. Side agents still run locally through Pi, and side-card hover follow-ups are sent directly to the side Pi agent as they are today.

### 6.2 OpenAI Realtime 설정 필드

Realtime 모드 선택 시 노출:

- Provider: 기본 `OpenAI`, 확장 가능 값 `Azure OpenAI`
- API key: SecureField. 현재 Azure STT와 동일하게 Settings에서 입력하고 로컬 settings 저장 방식으로 보존한다.
- Model/deployment: 기본 `gpt-realtime-2`, 선택 가능 `gpt-realtime-1.5`. Azure OpenAI provider에서는 이 값을 deployment name으로 해석할 수 있게 라벨을 바꾼다.
- Azure OpenAI endpoint fields: provider가 Azure일 때 `resourceEndpoint`, `apiVersion`, `deploymentName/model`, `apiShape(GA|preview)`를 담을 수 있게 settings 구조를 잡는다.
- Voice: 기본 `marin`, 선택지 `marin`, `cedar`, `alloy`, `ash`, `ballad`, `coral`, `echo`, `sage`, `shimmer`, `verse`
- Reasoning effort: `low`, `medium`, `high` 중심. 기존 `PickyMainAgentThinkingLevel`의 `xhigh`는 OpenAI 쪽에 그대로 매핑하지 않고 `high`로 제한한다.
- Turn detection: 기본 `push-to-talk manual commit`
- Optional: input transcription language, 기본 auto

### 6.3 API key 저장 원칙

확정 구현:

- API key는 Settings 탭에서 입력하고 현재 Azure STT 설정과 동일하게 로컬 settings 파일에 저장한다.
- Settings 저장 경로/serialization은 기존 `PickySettingsStore` 흐름을 재사용한다.
- app이 agentd에 연결되면 authenticated local WebSocket command로 API key와 provider config를 전달한다.
- agentd는 API key를 파일에 쓰지 않고 메모리에만 보관한다.
- agentd 로그에는 provider, endpoint host, model/deployment, key 존재 여부만 남기고 key 값은 절대 남기지 않는다.
- 사용자가 `OPENAI_API_KEY` 또는 Azure 관련 환경변수로 override할 수 있게 할지는 개발 편의 옵션으로만 둔다. UI 설정값과 충돌하면 UI 설정값을 우선한다.

## 7. 설정/프로토콜 모델 변경

### 7.1 Swift settings

수정 후보:

- `Picky/App/Settings/PickySettings.swift`
- `Picky/App/Settings/PickySettingsStore.swift`
- `Picky/Companion/CompanionPanelSettingsView.swift`
- `Picky/PickyAgentDaemonLauncher.swift`

추가 타입 예시:

```swift
enum PickyMainAgentRuntimeMode: String, Codable, CaseIterable, Identifiable {
    case pi
    case openAIRealtime
}

enum PickyOpenAIRealtimeProvider: String, Codable, CaseIterable, Identifiable {
    case openAI
    case azureOpenAI
}

enum PickyAzureOpenAIRealtimeAPIShape: String, Codable, CaseIterable, Identifiable {
    case ga      // /openai/v1/realtime?model=<deployment>
    case preview // /openai/realtime?api-version=<version>&deployment=<deployment>
}

struct PickyOpenAIRealtimeSettings: Codable, Equatable {
    var provider: PickyOpenAIRealtimeProvider = .openAI
    var apiKey: String = ""
    var modelOrDeployment: String = "gpt-realtime-2"
    var azureResourceEndpoint: String = ""
    var azureAPIVersion: String = ""
    var azureAPIShape: PickyAzureOpenAIRealtimeAPIShape = .ga
    var voice: String = "marin"
    var reasoningEffort: String = "medium"
    var transcriptionLanguage: String = ""
}
```

`PickySettings` 추가 필드:

```swift
var mainAgentRuntimeMode: PickyMainAgentRuntimeMode
var openAIRealtime: PickyOpenAIRealtimeSettings
```

API key는 `PickyOpenAIRealtimeSettings.apiKey`에 저장한다. 이 결정은 현재 Azure STT 설정과의 일관성을 우선한 것이다. 대신 logging/redaction 테스트를 필수로 둔다.

### 7.2 Daemon launcher environment

`PickyAgentDaemonConfiguration.environment`에는 runtime mode 정도의 non-secret bootstrap만 넣는다.

```text
PICKY_MAIN_AGENT_RUNTIME=pi | openai-realtime
```

Realtime provider, API key, model/deployment, Azure endpoint/API version/voice/reasoning 설정은 agentd 시작 직후 app이 `configureMainRealtimeAuth` command로 전달한다. API key를 env에 넣는 방식은 개발 override로만 허용한다.

### 7.3 Picky app <-> agentd protocol

수정 후보:

- `Picky/PickyAgentProtocol.swift`
- `agentd/src/protocol.ts`
- `agentd/src/server.ts`
- `Picky/PickyAgentClient.swift`

신규 command 초안:

```ts
configureMainRealtimeAuth {
  provider: "openai" | "azure_openai"
  apiKey: string // server log redaction mandatory
  modelOrDeployment: string // e.g. gpt-realtime-2, gpt-realtime-1.5, or Azure deployment name
  voice: string
  reasoningEffort?: "low" | "medium" | "high"
  transcriptionLanguage?: string
  azure?: {
    resourceEndpoint: string
    apiVersion?: string
    apiShape: "ga" | "preview"
  }
}

beginMainRealtimeVoiceTurn {
  inputId: string
  context: PickyContextPacket
}

appendMainRealtimeInputAudio {
  inputId: string
  audioBase64: string // PCM16 24kHz mono
}

commitMainRealtimeVoiceTurn {
  inputId: string
}

cancelMainRealtimeVoiceTurn {
  inputId?: string
  playedAudioMs?: number
}
```

신규 event 초안:

```ts
mainRealtimeStateChanged {
  state: "connecting" | "ready" | "listening" | "thinking" | "speaking" | "failed"
  message?: string
}

mainRealtimeInputTranscriptDelta {
  inputId: string
  delta: string
}

mainRealtimeInputTranscriptCompleted {
  inputId: string
  transcript: string
}

mainRealtimeOutputAudioDelta {
  inputId?: string
  audioBase64: string // PCM16 24kHz mono
}

mainRealtimeOutputAudioDone {
  inputId?: string
}

mainRealtimeOutputTranscriptDelta {
  inputId?: string
  delta: string
}

mainRealtimeOutputTranscriptCompleted {
  inputId?: string
  transcript: string
}

mainRealtimeTurnDone {
  inputId?: string
  status: "completed" | "cancelled" | "failed" | "incomplete"
  finalTranscript?: string
}
```

주의:

- `quickReply`를 그대로 재사용하면 기존 reducer가 TTS를 다시 실행할 수 있다.
- Realtime audio mode에서는 `quickReply`를 음성 출력 트리거로 쓰지 않는다.
- 화면 표시용 transcript는 신규 Realtime transcript event로 처리하거나, `quickReply`에 `audioAlreadyPlayed` 같은 명시 플래그를 추가해야 한다.

## 8. Realtime 음성 턴 흐름

이 흐름은 **hover 대상 side session이 없는 메인 에이전트 음성 턴**에만 적용한다. side HUD card 위에 hover된 상태의 음성 follow-up은 기존 방식대로 transcript를 만든 뒤 `followUp` command로 side Pi agent에 직접 전달한다.

### 8.1 Push-to-talk down

```text
Picky.app
  1. 기존 speech playback 중단
  2. agentd cancelMainRealtimeVoiceTurn 또는 abortMainAgent 전송
  3. context capture 시작 또는 예약
  4. beginMainRealtimeVoiceTurn(context shell)
  5. AVAudioEngine tap 시작
  6. PCM16 24kHz mono로 변환해 appendMainRealtimeInputAudio 반복 전송

agentd
  1. OpenAI Realtime session ensure/prewarm
  2. input_audio_buffer.clear
  3. state=listening emit
```

### 8.2 Push-to-talk up

```text
Picky.app
  1. mic tap 중지
  2. context capture 완료본을 begin 시점에 못 보냈다면 commit 직전 전송
  3. commitMainRealtimeVoiceTurn

agentd
  1. captured context를 conversation item으로 추가
  2. screenshot image paths를 data URL input_image로 추가
  3. input_audio_buffer.commit
  4. response.create { output_modalities: ["audio"] }
  5. text UI는 별도 text modality가 아니라 `response.output_audio_transcript.*` 이벤트로 업데이트한다.
```

Context item 전략:

- system message: desktop context 텍스트, source, cwd, active app/window, browser URL/title, selected text.
- user message 또는 response input: screenshots as `input_image`.
- audio item과 context item의 순서가 중요하다. 권장 순서: context item 먼저, audio commit 다음, response.create.

### 8.3 Response streaming

```text
OpenAI
  -> response.created
  -> response.output_audio.delta
  -> response.output_audio_transcript.delta
  -> response.function_call_arguments.done?    // 필요한 경우
  -> response.done

agentd
  -> output_audio.delta를 Picky.app으로 relay
  -> transcript delta를 Picky.app overlay/main history로 relay
  -> function_call이면 tool 실행 후 function_call_output + response.create 재호출

Picky.app
  -> audio delta를 streaming playback
  -> transcript bubble 업데이트
  -> done에서 voiceState idle/complete
```

### 8.4 사용자가 응답 도중 다시 말하는 경우

```text
Picky.app
  1. playback 즉시 중단
  2. playedAudioMs 계산 가능하면 전달
  3. cancelMainRealtimeVoiceTurn
  4. 새 beginMainRealtimeVoiceTurn 시작

agentd
  1. response.cancel
  2. conversation.item.truncate(item_id, audio_end_ms)
  3. input_audio_buffer.clear
```

초기 버전부터 `conversation.item.truncate`까지 구현한다. truncate에 필요한 `item_id`, `content_index`, playback 시작 시각, playedAudioMs를 app/agentd 양쪽에서 추적한다. truncate를 하지 않으면 모델 conversation에는 사용자가 듣지 못한 assistant audio transcript가 남을 수 있으므로 필수 범위로 둔다.

## 9. OpenAIRealtimeMainRuntime 설계

신규 파일 후보:

- `agentd/src/runtime/openai-realtime-main-runtime.ts`
- `agentd/src/runtime/openai-realtime-client.ts`
- `agentd/src/runtime/openai-realtime-events.ts`
- `agentd/src/runtime/openai-realtime-tools.ts`
- `agentd/src/runtime/openai-realtime-audio.ts`

### 9.1 Runtime interface 확장

기존 `AgentRuntime`은 text prompt 중심이다. Realtime voice stream을 억지로 `followUp(prompt)`에 넣지 말고 optional interface를 추가한다.

```ts
export interface MainRealtimeVoiceRuntime extends AgentRuntime {
  configureAuth?(auth: { apiKey: string }): Promise<void>;
  beginVoiceTurn?(turn: {
    inputId: string;
    context: PickyContextPacket;
  }): Promise<void>;
  appendVoiceAudio?(inputId: string, audioBase64: string): Promise<void>;
  commitVoiceTurn?(inputId: string): Promise<void>;
  cancelVoiceTurn?(inputId?: string, playedAudioMs?: number): Promise<void>;
}
```

`SessionSupervisor`는 `options.mainRuntime`이 이 interface를 지원할 때만 Realtime voice commands를 처리한다.

### 9.2 Session lifecycle

- app 시작 시 runtime mode가 `openai-realtime`이고 settings에 API key가 있으면 app이 `configureMainRealtimeAuth`를 보낸 뒤 prewarm.
- API key가 아직 없으면 `mainRealtimeStateChanged { state: "failed", message: "API key required" }` 대신 `ready=false` 상태만 emit하고 기존 Pi mode로 자동 fallback하지 않는다. 사용자가 선택한 모드가 실패했다는 것을 명확히 보여준다.
- Realtime session 최대 60분 제약 때문에 다음 중 하나를 구현한다.
  - `expires_at` 또는 연결 시간 기준 50분에 새 session 준비.
  - 최근 main messages, side session summaries, standing instructions를 새 session에 replay.

### 9.3 Provider connection strategy

OpenAI public API:

```text
wss://api.openai.com/v1/realtime?model=<model>
Authorization: Bearer <apiKey>
```

Azure OpenAI GA API:

```text
wss://<resource>.openai.azure.com/openai/v1/realtime?model=<deployment>
api-key: <apiKey>
```

Azure OpenAI preview API:

```text
wss://<resource>.openai.azure.com/openai/realtime?api-version=<apiVersion>&deployment=<deployment>
api-key: <apiKey>
```

`OpenAIRealtimeMainRuntime`은 provider별 URL/auth builder를 분리한다. event loop와 Realtime event parser는 OpenAI/Azure 공통으로 재사용한다.

### 9.4 session.update 예시

```json
{
  "type": "session.update",
  "session": {
    "type": "realtime",
    "model": "gpt-realtime-2",
    "instructions": "...Picky main-agent standing instructions...",
    "output_modalities": ["audio"],
    "audio": {
      "input": {
        "format": { "type": "audio/pcm", "rate": 24000 },
        "turn_detection": null,
        "transcription": {
          "model": "gpt-realtime-whisper"
        }
      },
      "output": {
        "format": { "type": "audio/pcm" },
        "voice": "marin"
      }
    },
    "tools": [
      { "type": "function", "name": "picky_handoff", "parameters": { } },
      { "type": "function", "name": "picky_side_sessions", "parameters": { } },
      { "type": "function", "name": "picky_side_steer", "parameters": { } },
      { "type": "function", "name": "picky_pointer_overlay", "parameters": { } }
    ],
    "tool_choice": "auto"
  }
}
```

### 9.5 Prompt/instructions 차이

현재 `buildMainAgentBootstrapPair()`는 Pi transcript에 synthetic user/assistant pair를 주입한다. Realtime mode에서는 같은 내용을 `session.instructions`로 제공한다.

필요한 조정:

- “마크다운 없이 1~3문장” 규칙은 유지.
- “pointer tags를 마지막에 붙이라”는 규칙은 Realtime audio mode에서 제거한다. 음성으로 태그를 읽을 위험이 있기 때문이다.
- 대신 `picky_pointer_overlay` function을 호출하라고 지시한다.
- `picky_handoff`, `picky_side_sessions`, `picky_side_steer` 사용 규칙은 유지한다.

## 10. Function calling / side Pi 유지

### 10.1 Tool schema 재사용

현재 tool 정의는 `agentd/src/application/handoff-tool.ts`에서 Pi `ToolDefinition`으로 생성된다. Realtime에서도 같은 이름/스키마/핸들러를 써야 하므로 runtime-agnostic tool definition으로 추출한다.

신규 구조 후보:

```text
agentd/src/application/main-agent-tools.ts
  ├─ canonical JSON schemas
  ├─ tool descriptions/guidelines
  └─ handlers factory

agentd/src/application/handoff-tool.ts
  └─ Pi ToolDefinition adapter

agentd/src/runtime/openai-realtime-tools.ts
  └─ OpenAI Realtime tools adapter
```

### 10.2 Function call loop

```text
response.done output contains function_call
  -> parse name/arguments/call_id
  -> execute local handler
  -> conversation.item.create { type: function_call_output, call_id, output }
  -> response.create { output_modalities: ["audio"] }
```

처리해야 할 edge cases:

- JSON arguments parse 실패: function_call_output에 error JSON 전달.
- tool handler throw: function_call_output에 recoverable error 전달.
- tool 실행 중 사용자가 새 PTT로 interrupt: tool 결과는 버리거나 stale turn이면 response.create를 생략.
- handoff tool이 side session을 시작하면 `SessionSupervisor.createSideFromHandoff()`는 기존 Pi side runtime을 그대로 사용한다.

### 10.3 Side completion delivery

현재 side session 완료 시 `buildMainAgentSideCompletionPrompt()`를 main runtime에 followUp한다. Realtime mode에서도 이 경로를 유지하되, 출력은 text TTS가 아니라 Realtime audio response로 보낸다.

주의:

- 사용자가 현재 PTT 중이면 side completion audio를 재생하지 말고 queue/defer한다.
- side completion prompt는 audio output으로 짧게 응답하게 한다.
- 사용자가 side completion 알림 음성 재생을 원치 않을 수 있으므로 기존 `notifyMainOnCompletion`을 존중한다.

## 11. Picky.app 음성 입력 변경

신규 파일 후보:

- `Picky/Companion/Realtime/OpenAIRealtimeVoiceInputManager.swift`
- `Picky/Companion/Realtime/OpenAIRealtimeAudioPlaybackEngine.swift`
- `Picky/Companion/Realtime/OpenAIRealtimeMainAgentController.swift`

### 11.1 Input manager

역할:

- AVAudioEngine input tap 설치.
- 기존 `BuddyPCM16AudioConverter`를 재사용하거나 24kHz 변환을 지원하도록 확장.
- 20~100ms 단위로 PCM16 mono chunk를 base64 인코딩.
- `appendMainRealtimeInputAudio` command로 agentd에 전송.
- backpressure: send queue가 밀리면 오래된 silent chunk가 아닌 전체 turn fail 처리. 음성 chunk drop은 모델 이해를 망가뜨릴 수 있다.

기존 `BuddyDictationManager`는 유지하고 Pi current mode에서만 사용한다.

### 11.2 Output playback engine

역할:

- `mainRealtimeOutputAudioDelta`의 PCM16 24kHz mono base64를 decode.
- AVAudioPCMBuffer로 변환.
- AVAudioEngine + AVAudioPlayerNode에 schedule.
- playback 시작/완료 상태를 `CompanionManager.voiceState`와 동기화.
- user interrupt 시 즉시 stop/reset.
- 가능하면 playedAudioMs를 계산해 agentd에 전달.

초기 구현은 PCM output만 지원한다. OpenAI output format도 `audio/pcm`으로 고정한다.

## 12. Interaction reducer 변경

수정 후보:

- `Picky/Interaction/PickyInteractionEffect.swift`
- `Picky/Interaction/PickyInteractionReducer.swift`
- `Picky/CompanionManager.swift`

원칙:

- runtime mode가 `pi`이면 현재 reducer/effect 흐름을 그대로 사용한다.
- runtime mode가 `openAIRealtime`이고 target이 main이면 `startDictation`/`stopDictation` 대신 Realtime voice effects를 사용한다.
- side session hover follow-up은 Realtime mode에서도 현재 구조를 유지한다. 즉, `BuddyDictationManager`로 transcript를 만든 뒤 `followUp` command로 side Pi agent에 직접 전달한다.
- hover 대상이 없는 메인 대화 중 사용자가 기존 delegated work를 언급하면, Realtime main이 `picky_side_sessions`/`picky_side_steer` function을 호출할 수 있다.

신규 effect 후보:

```swift
case beginRealtimeVoice(inputID: UUID)
case appendRealtimeVoiceAudio(inputID: UUID, audioBase64: String)
case commitRealtimeVoice(inputID: UUID)
case cancelRealtimeVoice(inputID: UUID?)
case playRealtimeAudioDelta(inputID: UUID?, audioBase64: String)
case finishRealtimeAudio(inputID: UUID?)
```

다만 audio append는 reducer event로 매 chunk를 통과시키지 않는다. 고빈도 오디오 chunk는 manager/controller가 직접 agent client에 보내고, reducer에는 lifecycle event만 넣는다.

## 13. Text input 처리

Realtime mode에서도 quick text input은 지원해야 한다.

권장:

- typed text request도 Realtime main mode에서는 `conversation.item.create` with `input_text` + context/images 후 `response.create { output_modalities: ["audio"] }`를 사용한다.
- 사용자는 지금처럼 음성 응답과 화면 텍스트를 함께 받아야 한다. 단, 공식 Realtime API는 `output_modalities`에서 `audio`와 `text`를 동시에 요청하지 않으므로, 화면 텍스트는 `response.output_audio_transcript.delta/done` transcript로 표시한다.
- 기존 Pi mode에서는 typed text가 현재처럼 text reply 중심으로 동작한다.

## 14. Pointer overlay 처리

현재 Pi main은 final answer에 `[POINT:x,y:label]` tags를 붙이고 agentd가 파싱한다. Realtime audio mode에서는 이 방식이 부적합하다.

문제:

- audio transcript에 pointer tag가 들어가면 모델이 태그를 음성으로 읽을 수 있다.
- OpenAI Realtime audio output은 별도 hidden text channel을 제공하지 않는다.

권장 대안:

- Realtime mode 전용 function tool `picky_pointer_overlay` 추가.
- schema:

```json
{
  "screenId": "optional string",
  "points": [
    { "x": 100, "y": 200, "label": "검색창" }
  ]
}
```

- handler는 기존 `makePointerOverlayRequestForContext()` / `pointerOverlayRequested` event를 재사용한다.
- Pi current mode는 기존 pointer tag 방식을 유지한다.

## 15. 오류/복구 정책

### 15.1 API key 없음/invalid

- 설정 UI에 명확한 에러를 표시한다.
- Realtime mode에서 key가 없으면 PTT 시작을 막고 “OpenAI API key가 필요합니다” 상태를 보여준다.
- 자동으로 Pi mode로 fallback하지 않는다. 사용자가 선택한 동작과 실제 동작이 달라지는 것을 피한다.

### 15.2 Realtime WebSocket 끊김

- turn 중 끊기면 해당 turn은 failed 처리.
- 다음 PTT에서 재연결 시도.
- 연결 실패 횟수/마지막 에러를 settings/status view에 표시.

### 15.3 60분 session 만료

- 50분 경과 또는 `expires_at` 근접 시 새 session 생성.
- standing instructions, 최근 main messages, side sessions summary를 replay.
- pending side completion queue는 보존.

### 15.4 Rate limit

- `rate_limits.updated`를 debug log에 남긴다.
- rate limit error는 사용자에게 짧게 안내한다.

### 15.5 Privacy

Realtime mode가 전송하는 데이터:

- microphone audio
- active app/window metadata
- browser URL/title
- selected text
- screenshots
- cwd
- side session summaries when tool calls happen

설정 UI에 이 내용을 명시한다.

## 16. Logging / redaction

필수:

- command logging에서 `configureMainRealtimeAuth.apiKey`는 절대 출력하지 않는다.
- audio chunk payload는 로그에 남기지 않는다. 길이/byte count만 기록한다.
- screenshot data URL은 로그에 남기지 않는다.
- OpenAI error response는 message/code만 로그에 남기고 request body dump는 금지한다.

## 17. 테스트 계획

### 17.1 agentd unit tests

수정/추가 후보:

- `agentd/src/protocol.test.ts`
- `agentd/src/server.test.ts`
- `agentd/src/session-supervisor.test.ts`
- `agentd/src/runtime/openai-realtime-main-runtime.test.ts`

테스트 항목:

1. runtime mode가 기본값 `pi`로 migration된다.
2. `PICKY_MAIN_AGENT_RUNTIME=openai-realtime`이면 sideRuntime은 `PiSdkRuntime`, mainRuntime만 `OpenAIRealtimeMainRuntime`이 된다.
3. API key는 settings payload에 존재할 수 있지만 log field에는 값이 남지 않는다.
4. OpenAI public provider URL/auth와 Azure OpenAI GA/preview provider URL/auth가 올바르게 만들어진다.
5. `gpt-realtime-2`와 `gpt-realtime-1.5` model/deployment 값이 모두 허용된다.
6. voice begin/append/commit command가 Realtime client event로 매핑된다.
7. OpenAI `response.output_audio.delta`가 Picky protocol event로 relay된다.
8. `response.output_audio_transcript.delta/done`이 main transcript event로 relay된다.
9. `function_call` output이 `picky_handoff` handler를 호출하고 side Pi session을 만든다.
10. function call result 후 `response.create { output_modalities: ["audio"] }`가 다시 호출된다.
11. interrupt 시 `response.cancel`과 `conversation.item.truncate`가 호출되고 stale delta는 무시된다.
12. session expiration/reconnect 시 bootstrap replay가 수행된다.

OpenAI 실제 API는 CI에서 호출하지 않는다. fake WebSocket server/client를 사용한다.

### 17.2 Swift tests

수정/추가 후보:

- `PickyTests/PickyCompanionManagerTests.swift`
- `PickyTests/PickyAgentClientTests.swift`
- `PickyTests/PickySessionViewModelTests.swift`
- 신규 `PickyTests/OpenAIRealtimeSettingsTests.swift`

테스트 항목:

1. settings Codable migration: 기존 settings 파일에 신규 필드가 없어도 defaults 적용.
2. Realtime mode에서 PTT down이 BuddyDictationManager 대신 Realtime controller를 사용.
3. Realtime mode에서 기존 TTS provider가 중복 실행되지 않음.
4. side follow-up hover 상태에서는 Realtime main을 거치지 않고 기존 direct side follow-up 경로를 사용함.
5. audio delta event 수신 시 playback engine으로 전달됨.
6. output audio transcript event가 화면 텍스트로 표시됨.
7. user interrupt 시 playback stop + cancel command + playedAudioMs 전달.
8. API key는 Azure STT와 동일하게 settings JSON에 저장되지만 로그/agentd persistence에는 남지 않음.

### 17.3 수동 smoke

1. Pi current mode에서 기존 PTT/STT/TTS/HUD 동작 회귀 확인.
2. Realtime mode API key 없이 PTT: 명확한 설정 오류.
3. Realtime mode API key 입력 후 PTT: 음성 입력 -> 음성 응답 + 화면 transcript 표시.
4. “복잡한 건 사이드에 맡겨” 류 요청: Realtime이 `picky_handoff` 호출, side Pi HUD 생성.
5. 실행 중 side session 위에 hover 후 음성 추가 지시: 기존처럼 side Pi agent에 직접 follow-up 전달.
6. hover 없이 기존 delegated work를 언급: Realtime이 `picky_side_sessions` 후 필요 시 `picky_side_steer` 호출.
7. 응답 도중 PTT 재시작: 기존 응답 중단, `conversation.item.truncate`, 새 응답 시작.
8. screenshot 기반 “여기 뭐야?” 요청: image context 전달 확인.
9. pointer overlay 필요 요청: Realtime function으로 pointer 표시.

## 18. 구현 단계

### Phase 0: 설계 확정

- 이 문서 리뷰.
- UX 문구 최종 확인.
- API key 저장 방식은 settings local 저장으로 확정.
- Realtime mode의 typed text output은 audio + transcript text 표시로 확정.

### Phase 1: Settings / local API key / protocol foundation

파일:

- `Picky/App/Settings/PickySettings.swift`
- `Picky/Companion/CompanionPanelSettingsView.swift`
- `Picky/PickyAgentProtocol.swift`
- `agentd/src/protocol.ts`
- `agentd/src/server.ts`

작업:

- runtime mode setting 추가.
- OpenAI/Azure OpenAI Realtime settings 추가.
- API key local settings 저장 필드 추가.
- configure auth command에 provider/model/Azure endpoint까지 포함.
- realtime voice command/event schema 추가.
- logging redaction 추가.

### Phase 2: agentd OpenAI Realtime client

파일:

- `agentd/src/runtime/openai-realtime-client.ts`
- `agentd/src/runtime/openai-realtime-main-runtime.ts`
- `agentd/src/index.ts`
- `agentd/src/session-supervisor.ts`

작업:

- OpenAI WebSocket 연결.
- session.update 구성.
- response event normalization.
- audio/transcript relay.
- response.cancel.
- conversation.item.truncate.
- session expiry/reconnect skeleton.

### Phase 3: Realtime function tools

파일:

- `agentd/src/application/main-agent-tools.ts`
- `agentd/src/application/handoff-tool.ts`
- `agentd/src/runtime/openai-realtime-tools.ts`
- `agentd/src/session-supervisor.ts`

작업:

- handoff/side sessions/side steer canonical schema 추출.
- Pi adapter와 OpenAI adapter 분리.
- function call loop 구현.
- pointer overlay function 추가.

### Phase 4: Swift realtime voice input/output

파일:

- `Picky/Companion/Realtime/OpenAIRealtimeVoiceInputManager.swift`
- `Picky/Companion/Realtime/OpenAIRealtimeAudioPlaybackEngine.swift`
- `Picky/CompanionManager.swift`
- `Picky/Interaction/*`

작업:

- AVAudioEngine -> PCM16 24kHz mono stream.
- output_audio.delta playback.
- Realtime mode PTT path 분기.
- transcript UI event 처리.
- 기존 TTS 중복 방지.

### Phase 5: context/image integration

파일:

- `Picky/Context/*`
- `Picky/CompanionManager.swift`
- `agentd/src/runtime/openai-realtime-main-runtime.ts`

작업:

- PTT 중/후 context capture 타이밍 정리.
- screenshot path -> data URL 변환.
- context item ordering 보장.
- main Realtime turn에는 side hover target을 전달하지 않는다. side hover follow-up은 기존 direct side path에서 처리한다.

### Phase 6: hardening / QA

작업:

- truncate 정확도 검증 및 playback position 보정.
- reconnect/session replay.
- rate limit 상태.
- logs redaction audit.
- docs/settings help text.
- alpha build smoke.

## 19. 주요 리스크와 대응

| 리스크                                            | 영향                     | 대응                                                                         |
| ---------------------------------------------- | ----------------------:| -------------------------------------------------------------------------- |
| Realtime session 60분 제한                        | 장시간 main context 유실    | proactive reconnect + recent history replay                                |
| output audio를 듣기 전 interrupt                   | 모델 context에 안 들은 내용 잔류 | `response.cancel` + `conversation.item.truncate`를 초기 범위에 포함                |
| 기존 quickReply가 TTS를 중복 실행                      | 이중 음성 출력               | Realtime 전용 transcript/audio event 사용 또는 `audioAlreadyPlayed` 플래그          |
| pointer tags가 음성으로 읽힘                          | UX 손상                  | Realtime mode에서는 pointer function tool 사용                                  |
| API key local settings 저장                      | settings 파일 접근 시 노출 가능 | Azure STT와 동일한 UX 유지, 로그/proc args/agentd persistence 금지                   |
| audio chunk JSON overhead                      | 지연/CPU 증가              | 초기 JSON, 필요 시 binary WS frame로 개선                                          |
| side hover direct follow-up은 Realtime main을 우회 | 메인 Realtime 일관성 일부 감소  | 사용자가 확정한 UX. hover는 명시적 side targeting으로 보고 기존 side Pi direct follow-up 유지 |
| OpenAI/Azure Realtime 장애 시 자동 Pi fallback      | 사용자 기대 불일치/개인정보 혼선     | 자동 fallback 금지, 명시 오류 표시                                                   |

## 20. 확정된 제품 결정 사항

사용자가 확정한 구현 기준은 다음과 같다.

1. API key는 Settings 탭에서 입력하고 현재 Azure STT와 동일하게 로컬 settings에 저장한다. agentd에는 local authenticated WebSocket으로 전달하고, agentd는 메모리에만 보관한다.
2. Realtime provider 구조는 OpenAI public API와 Azure OpenAI Realtime으로 확장 가능하게 설계한다. Azure GA/preview endpoint shape를 모두 수용한다.
3. 모델은 `gpt-realtime-2`를 기본으로 하되 `gpt-realtime-1.5`도 사용할 수 있게 한다.
4. Realtime mode의 사용자 응답 UX는 audio + text를 모두 제공한다. API 차원에서는 `output_modalities: ["audio"]`를 사용하고 text는 output audio transcript 이벤트로 표시한다.
5. Pointer overlay는 Realtime 전용 function tool로 구현한다.
6. side HUD card hover 상태의 음성 지시는 Realtime main을 거치지 않고 현재처럼 side Pi agent에게 직접 전달한다.
7. interrupt/cancel 품질을 위해 초기 버전부터 `conversation.item.truncate`까지 구현한다.

## 21. 구현 준비도 보강 체크리스트

문서만 보고 구현을 시작할 때 헷갈리지 않도록 다음 세부사항을 반드시 함께 적용한다.

### 21.1 Runtime routing matrix

| Runtime mode     | Target           | Input path                             | Agent path                    | Output path                                   |
| ---------------- | ---------------- | -------------------------------------- | ----------------------------- | --------------------------------------------- |
| `pi`             | main             | `BuddyDictationManager` STT            | `routeTask` -> Pi mainRuntime | `quickReply` -> existing TTS                  |
| `pi`             | side hover       | `BuddyDictationManager` STT            | `followUp` -> side Pi agent   | HUD / side completion notification            |
| `openAIRealtime` | main             | `RealtimeVoiceInputManager` PCM stream | `OpenAIRealtimeMainRuntime`   | `output_audio.delta` playback + transcript UI |
| `openAIRealtime` | side hover       | `BuddyDictationManager` STT            | `followUp` -> side Pi agent   | HUD / side completion notification            |
| `openAIRealtime` | typed main input | text item + context/images             | `OpenAIRealtimeMainRuntime`   | audio playback + output audio transcript UI   |

Side hover direct follow-up is an explicit exception to “main Realtime voice path”. It preserves the existing precise side-targeting UX.

### 21.2 Protocol/versioning requirements

- Bump `pickyAgentProtocolVersion` and `PROTOCOL_VERSION` when adding realtime commands/events.
- Add contract tests for Swift `Codable` <-> TypeScript `zod` payload shape.
- High-frequency audio commands must bypass reducer/journal. They may use existing JSON WebSocket initially, but command logging must summarize only byte counts.
- Every realtime turn carries a stable `inputId` and agentd-side generation/turn id. Stale OpenAI deltas after cancel/reconnect must be dropped.

### 21.3 Context capture without final transcript

Realtime main mode does not have a final transcript before audio is sent. Context capture must therefore support `transcript: nil` or an empty placeholder for main realtime turns. The recognized user text shown in UI comes later from `conversation.item.input_audio_transcription.*` events and should not be required to build the initial `PickyContextPacket`.

### 21.4 Truncate bookkeeping

To implement `conversation.item.truncate`, store the following for the active assistant audio item:

- `response_id`
- assistant `item_id`
- `content_index`
- first audio delta wall-clock time
- number of scheduled/played PCM frames in Swift playback
- `playedAudioMs` sent from app to agentd on interruption

If `playedAudioMs` is unavailable, cancel the response and skip truncate only as a guarded fallback with a warning log; the happy path must truncate.

### 21.5 Provider URL/auth builders

Implement provider-specific builders with unit tests:

- OpenAI public: `wss://api.openai.com/v1/realtime?model=<model>`, `Authorization: Bearer <apiKey>`.
- Azure OpenAI GA: `wss://<resource-host>/openai/v1/realtime?model=<deployment>`, `api-key: <apiKey>` header.
- Azure OpenAI preview: `wss://<resource-host>/openai/realtime?api-version=<apiVersion>&deployment=<deployment>`, `api-key: <apiKey>` header.

Normalize Azure endpoint input so both `https://x.openai.azure.com` and `x.openai.azure.com` work, and reject paths/query strings with a clear settings error.

### 21.6 Additional required tests

Add these on top of section 17:

- Routing matrix tests for all main/side-hover/runtime combinations.
- Realtime main context capture works with no transcript.
- Realtime mode does not trigger existing `PickySpeechPlaybackProvider` for realtime audio replies.
- Realtime transcript events update visible text without creating duplicate `quickReply` TTS.
- `conversation.item.truncate` includes the last assistant `item_id`, `content_index`, and app-provided `playedAudioMs`.
- Azure endpoint normalization and invalid endpoint validation.
- `gpt-realtime-1.5` is accepted as model/deployment in both OpenAI and Azure provider configs.
- Audio append command logs never include `audioBase64`.
- `configureMainRealtimeAuth` logs never include `apiKey`.
- Side completion notification in Realtime mode uses audio + transcript and respects `notifyMainOnCompletion`.
