# Realtime 런타임 능력 증강 — 추가 커스텀 도구 제안서

> 대상: `PICKY_REALTIME_OPT_IN=1` 빌드의 메인 OpenAI Realtime 런타임
> 
> 현재 활성 도구: `picky_start_pickle`, `picky_pickle_sessions`,
> `picky_steer_pickle`, `picky_skills_search`, `picky_skill_details`,
> `read_picky_user_guide`
> 
> 이 문서는 위 6개 도구 외에 Realtime 메인이 가지면 사용자 경험이 명확히 좋아질
> 후보들을 우선순위와 트레이드오프 까지 정리한 제안서입니다. 코드 변경은 들어
> 있지 않습니다.

---

## 0. 설계 원칙 (제안 도구 모두에 공통)

Realtime 메인은 다음 네 가지 강점에서 Pi 메인과 다릅니다:

1. **저지연 음성 응답** — 길게 도는 작업을 직접 하면 강점이 죽음
2. **모델이 직접 audio 생성** — 짧고 자연스러운 발화에 최적
3. **세션 1개당 60분 hard limit + transcript-only 영속성** — 큰 도구
   output 을 컨텍스트에 쌓으면 비싸짐
4. **Codex/ChatGPT OAuth 기반 quota** — 큰 텍스트 처리는 비용 효율이 낮음

따라서 새 도구는 가능하면:

- **상태/메타데이터 단발 조회** (수십 토큰 이내 응답)
- **사용자 즉시 인지 가능한 UI 액션** (음성 진행 중에도 의미 있음)
- **위임 분기 명확화** — 무거운 본 작업은 여전히 Pickle 로

장기 작업·대량 텍스트 가공·파일 시스템 스캔은 무조건 `picky_start_pickle` /
`picky_steer_pickle` 로 위임해야 한다는 원칙은 유지합니다.

---

## 1. 우선순위 A — 즉시 추가 가치가 큰 도구

### 1.1 `picky_recall_recent_context`

**한 줄**: 사용자가 "방금 그거", "5분 전 본 화면", "그 PR" 같이 가까운 과거를
가리킬 때, 메인이 captured context 의 최근 N개를 직접 조회.

**왜 필요한가**: Transcript-only 모델 + 60분 rollover 때문에 메인은 자기
이전 대화의 텍스트만 갖고 있고 첨부된 screenshot, browser URL, selected text
등은 잃습니다. Pickle 에 매번 위임해서 다시 캡처시키는 건 과함.

**제안 시그니처**:

```ts
{ name: "picky_recall_recent_context",
  description: "Look up the last N captured context packets (browser URL, selected text, screenshot label, cwd) the user submitted to Picky in this session.",
  parameters: { limit: number (default 5, max 20), source?: "voice" | "text" | "cli" | "quickInput" } }
```

**구현 노트**:

- `mainState.contextHistory` 같은 짧은 ring buffer 를 supervisor 에 추가
- 도구 결과는 textOnly summary (URL/path/cwd 등 식별자만, screenshot 바이너리는 제외)
- 비용: 1 turn 당 수십 토큰 추가

**위험**: 사용자가 "내 화면 본 거 기억해?" 라고 물을 때마다 호출되면 quota 낭비
가능. 모델이 적절히 호출하도록 instruction 에 명시 필요.

---

### 1.2 `picky_ask_user_confirm`

**한 줄**: 모델이 발화 중에 사용자에게 짧은 yes/no 또는 2~3 선택지를 시각적으로 묻고, 답이 오면 같은 턴 안에서 응답을 이어감.

**왜 필요한가**: 지금은 모델이 "삭제할까요?" 라고 음성으로 물으면 사용자가
다시 PTT 를 눌러 음성으로 답해야 함. 이게 빠른 UX 가 아님. 시각적 confirm UI
가 화면에 뜨면 사용자가 마우스/단축키로 즉시 답 가능.

**제안 시그니처**:

```ts
{ name: "picky_ask_user_confirm",
  description: "Pop a small confirmation card in front of the user with up to 4 short choices. Use sparingly: only when you genuinely cannot proceed without a binary decision (yes/no, A/B, keep/discard).",
  parameters: { question: string (max 120 chars), choices: string[] (1-4 items) } }
```

**구현 노트**:

- agentd → Picky 측 새 envelope `confirmRequested` 추가
- Picky CompanionManager 에 작은 sheet/card UI
- 답이 도착하면 `conversation.item.create` 로 `tool` role response 주입 → 같은 response 이어짐
- 시간 초과 (예: 30초) 시 자동 "cancel" 응답

**위험**:

- 사용자가 음성 발화 중에 시각적 UI 가 뜨면 혼란 가능 → "음성 모드에 뜨는 즉답형 UI" 라는 사용자 학습 필요
- 모델이 남용 가능 → prompt 에 "정말 차단되는 경우만" 강조

---

### 1.3 `picky_show_link_or_path`

**한 줄**: 모델이 음성으로 발화할 수 없는 URL/file path 를 화면 위 작은 chip 으로 띄움 (클립보드 복사 가능).

**왜 필요한가**: 사용자가 결정 1 으로 "괄호 안에 URL 넣기" 힌트를 뺀 결과,
이제 모델은 URL 을 paraphrase 만 해야 함. 사용자가 실제 링크가 필요할 땐
"링크는 위에 카드에서 확인하세요" 같이 안내할 도구가 필요.

**제안 시그니처**:

```ts
{ name: "picky_show_link_or_path",
  description: "Surface a clickable/copyable artifact (URL, file path, session id, command) on screen so the user can interact with it without you having to read it aloud.",
  parameters: { kind: "url" | "path" | "command" | "id", value: string, label?: string } }
```

**구현 노트**:

- 결과 chip 은 `realtimeArtifactPosted` 이벤트로 Picky 에 push
- 화면 위 transient (10초) 또는 dock card 에 append 둘 다 가능 — 사용자 결정 필요
- 클릭 시 적절한 핸들러 (URL → 브라우저, path → Reveal in Finder, command → 클립보드)
- 음성 응답 자체에는 "복사할 링크를 카드로 띄웠어요" 같은 한 문장만

**위험**: 화면 가림. dock 카드가 누적되면 정리 필요.

---

## 2. 우선순위 B — 분명히 좋지만 비용 검토 필요

### 2.1 `picky_get_current_time_context`

**한 줄**: 현재 timezone, 시간, 요일, 사용자 마지막 활동 시간 등을 단발 조회.

**왜 필요한가**: 모델은 학습 시점 cutoff 가 있고 Realtime API 가 시간을
자동 주입해주지 않음. "지금 몇 시야?", "어제 뭐 했어?" 류 질문이 hallucination
또는 Pickle 위임으로 빠짐.

**제안 시그니처**:

```ts
{ name: "picky_get_current_time_context",
  description: "Look up the user's local date/time, timezone, and how long it has been since their last Picky turn.",
  parameters: { format?: "short" | "rfc3339" } }
```

**구현 노트**:

- agentd 가 매 reply 시작에 timezone hint 를 instructions 에 박는 방법도 있음. 도구 vs 정적 hint trade-off.
- 정적 hint 가 더 싸지만 응답 자연스러움은 도구 호출 쪽이 위.

**위험**: instructions 에 한 줄 박는 게 더 효율적일 수 있음. 도구로 만들면 매 호출마다 토큰.

---

### 2.2 `picky_inspect_active_pickle`

**한 줄**: 사용자가 "지금 어떻게 돼가?" 라고 물을 때, 특정 pickle 의 최근 활동/마지막 tool 호출/예상 남은 시간을 요약.

**왜 필요한가**: 현재 `picky_pickle_sessions` 는 list 만 줌. 사용자가 호버 중인 pickle 에 대한 상세 진행 상황은 메인이 모름. Pickle 카드를 직접 읽으려면 위임이 필요한데, 위임은 또 다른 Pickle 을 띄움 (재귀).

**제안 시그니처**:

```ts
{ name: "picky_inspect_active_pickle",
  description: "Get a short status summary of a running Pickle without spawning another one. Use only when the user explicitly asks about progress.",
  parameters: { sessionId: string, includeRecentToolCalls?: boolean (default true, max 5) } }
```

**구현 노트**:

- agentd 의 SessionSupervisor 가 이미 in-memory 로 갖고 있는 `recentToolCalls`, `lastActivityAt`, `currentStep` 등을 노출
- 결과는 plain text, 토큰 100개 미만
- pickleAgent 의 active log 를 직접 읽지 말 것 (cwd 권한 / I/O race)

**위험**: 모델이 매 turn 마다 호출하면 시끄러움. instruction 에 "explicitly asked" 강조.

---

### 2.3 `picky_quick_clipboard_get` / `picky_quick_clipboard_put`

**한 줄**: 사용자가 "복사해서 보여줄게" 또는 "그거 클립보드에 넣어줘" 라고 할 때 곧장 처리.

**왜 필요한가**: 이건 Picky 메인이 직접 답해야 자연스러운 시나리오. Pickle 위임이 오버킬.

**제안 시그니처**:

```ts
{ name: "picky_quick_clipboard_get",
  description: "Read the user's clipboard (plain text only, capped at 2000 chars).",
  parameters: { maxChars?: number } }
{ name: "picky_quick_clipboard_put",
  description: "Put a short string on the user's clipboard. Confirm with the user before using on long content.",
  parameters: { text: string (max 4000 chars) } }
```

**구현 노트**:

- Swift 측 `NSPasteboard.general` 직접 접근
- `put` 은 모델이 임의로 쓰지 않도록 prompt 에 "user must explicitly ask" 강조
- 이미지 / 파일 clipboard 는 범위 밖

**위험**:

- 보안: clipboard 에 비밀번호 등이 있으면 모델 context 로 흘러감. `get` 시 길이 cap + 패턴 redact 필요 (예: bearer token 모양은 마스킹)

---

## 3. 우선순위 C — 가능성은 있으나 신중

### 3.1 `picky_set_voice_persona`

**한 줄**: 사용자가 "좀 더 차분하게 말해줘", "남자 목소리로" 같이 음성 톤 변경을 요청할 때.

**왜 필요한가**: 현재 voice 는 settings 의 `openAIRealtime.voice` 값 고정. 음성 발화 중 voice 를 바꾸려면 session.update 가 필요.

**제안 시그니처**:

```ts
{ name: "picky_set_voice_persona",
  description: "Change the assistant's voice for the rest of this session. Allowed: alloy, ash, ballad, coral, echo, fable, onyx, nova, sage, shimmer, verse, marin, cedar.",
  parameters: { voice: string, speakingStyle?: "calm" | "neutral" | "energetic" } }
```

**구현 노트**:

- Realtime API 의 session.update 로 voice 변경 가능 (단, 현재 진행 중인 audio response 는 영향 없음)
- speakingStyle 은 instructions append 로 흉내. 진정한 control 은 voice 자체만.
- 세션 내 일시적 변경. Settings 의 default voice 는 건드리지 않음.

**위험**:

- 모델 남용 가능 (모델이 자기 voice 를 임의로 변경하면 사용자 혼란)
- 사용자가 음성 변경을 명시적으로 요청한 경우에만 호출하도록 prompt 강화

---

### 3.2 `picky_screenshot_now`

**한 줄**: 모델이 "방금 화면 캡처를 다시 봐줘" 가 필요할 때 사용자 현재 화면을 새로 캡처.

**왜 필요한가**: 사용자가 "지금 이 화면 봐" 라고 했는데 context 가 안 들어왔거나 stale 한 경우. 현재는 사용자가 다시 PTT/Quick Input 으로 context 를 다시 첨부해야 함.

**제안 시그니처**:

```ts
{ name: "picky_screenshot_now",
  description: "Capture the user's current screen and feed it as a new image into the conversation. Use ONLY when the user explicitly asks Picky to look at something on screen.",
  parameters: { scope?: "focused" | "all-displays" } }
```

**구현 노트**:

- Swift 측 `PickyVoiceContextCaptureCoordinator.screenCapture(...)` 재사용
- 이미지 입력은 Realtime API 의 `input_image` content part 로 conversation.item.create
- 새 input audio buffer 는 생성하지 않고 같은 turn 안에서 사용
- 비용: 이미지 1장당 토큰 큼 (수천 토큰). 빈번 호출 금지 prompt 필요

**위험**:

- 사용자 동의 없는 임의 캡처 = 프라이버시. 모델이 "확인" 없이 호출하지 않게 강제 필요
- 이미지 토큰 비용 / quota 부담

---

### 3.3 `picky_set_response_modality`

**한 줄**: 사용자가 "조용히 글로만 답해줘" / "다시 말해줘" 등 modality 토글을 요청할 때.

**왜 필요한가**: 지금은 narration 토글이 Settings 영구 설정. "이번 답만 글로" 가 안 됨.

**제안 시그니처**:

```ts
{ name: "picky_set_response_modality",
  description: "Switch the next assistant response to text-only or audio-or-text. The change applies for the next turn only and reverts afterwards.",
  parameters: { modality: "text" | "audio", scope?: "next-turn" | "session" } }
```

**구현 노트**:

- Realtime API 의 `response.modalities` 는 response 단위로 지정 가능
- Picky 의 `setNarrationEnabled` 와 충돌하지 않도록 "이번 턴만" 은 영구 설정 변경 X
- 사용자가 명시적으로 요청한 경우만

**위험**: 모델이 자기 판단으로 modality 바꾸기 시작하면 일관성 깨짐

---

## 4. 우선순위 D — 잠재력 있지만 별도 PR 권장

### 4.1 `picky_remember_for_user`

사용자 메모리에 짧은 사실 저장 ("내 프로젝트 이름은 picky", "내 GitHub는 …").
별도 storage (예: `~/Library/Application Support/Picky/user-memory.jsonl`) 필요.
**보안/프라이버시 검토 필요**.

### 4.2 `picky_quick_web_lookup`

짧은 단일 fact 만 외부 API (DuckDuckGo Instant Answer 등) 로 fetch.
큰 검색은 Pickle 의 WebSearch tool 로. **외부 의존 + rate limit 부담**.

### 4.3 `picky_open_app_or_file`

사용자 명령으로 앱/파일 열기. macOS `NSWorkspace.open(_:)`.
**보안 모델 / 사용자 confirm 흐름 필요**.

### 4.4 `picky_send_followup_question_to_pickle`

실행 중인 Pickle 에게 "잠깐 멈추고 이 질문에 답 후 계속" 같은 시그널.
현재 `picky_steer_pickle` 과 의미적으로 가깝지만 "응답 후 원래 작업 재개"
시맨틱이 필요. **Pickle 측 supervision 변경 부담 큼**.

---

## 5. 도입 우선 순서 제안

가장 적은 코드/risk 대비 사용자 가치가 큰 순서:

1. **1.3 `picky_show_link_or_path`** — 결정 1 으로 인해 URL 발화 못 함 → 가장 시급한 보강
2. **1.1 `picky_recall_recent_context`** — Realtime 의 transcript-only 모델의 누락 컨텍스트 회복
3. **2.2 `picky_inspect_active_pickle`** — 사용자 "어떻게 돼가?" 류 빈도 높음
4. **2.3 `picky_quick_clipboard_get/put`** — 단순/높은 가치, redact 만 신경
5. **1.2 `picky_ask_user_confirm`** — UI 추가 필요, 디자인 시간 필요
6. **2.1 `picky_get_current_time_context`** — 도구 vs 정적 hint 결정 후
7. 3.x / 4.x — 별도 PR

각 항목별로 별도 PR 권장. 한 PR 에 여러 도구를 묶으면 prompt budget / 회귀
범위가 커집니다.

---

## 6. 공통 구현 가이드

1. **도구는 모두 `agentd/src/runtime/openai-realtime-main-runtime.ts` 의
   `RealtimeToolName` union 에 추가**, `realtimeTools` 배열에 schema 등록,
   `handleToolCall()` switch 에 처리 케이스 추가.
2. **tool result 는 plain text (또는 short JSON string)**, 이미지/바이너리
   금지. Realtime API 의 function_call_output 은 string only.
3. **prompt 측 (`prompt-builder.ts` + `buildRealtimeInstructions()`) 에
   사용 조건 명시**. "user must explicitly ask" 류 가드를 prompt 에 강하게.
4. **각 도구에 대한 단위 테스트** — `openai-realtime-main-runtime.test.ts`
   기존 패턴 (`FakeRealtimeSocket` + `RecordingRuntime`) 재사용.
5. **사용자 가시적 UI 가 있는 도구 (1.2, 1.3, 3.2)** 는 Swift 측에 새
   envelope + 핸들러 추가. CompanionManager 의 기존 이벤트 디스패치 흐름과
   동일 패턴.
6. **사용량 측면**: 도구 호출당 추가되는 토큰을 측정 가능하게.
   `main_realtime_usage` 이벤트는 이미 lastTurn / session 누적을 노출하므로
   도입 전후 비교 가능.
