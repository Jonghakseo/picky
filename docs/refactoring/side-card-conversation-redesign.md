# Side Card — Conversation Redesign 구현 계획

> 사이드 에이전트 HUD 카드를 "대시보드 모듈" 형태에서 "채팅 스레드" 메타포로 재설계합니다. 동시에 큐(steering / follow-up) UI, mode-aware 표시, 활동 요약 strip, `submit_final_report` 도구, ESC=Stop 키보드 모델을 도입합니다.

상태: **Spec lock-in 완료, 구현 대기**
관련 시안 위젯: 대화 4 phase + ⋯ 메뉴 (대화 v3 final)
대화 트랜스크립트: 본 문서가 그 결과물

---

## 0. 배경 / 동기

### 현재 카드의 문제 (진단 요약)
- 시각 밴드 9~10개 (header / cwd / branch / links / divider / REQUEST / WORKING / queue×2 / hints / actions×6) → 위계가 평탄
- 모든 정보가 동시에 노출 → "지금 뭐 하고 있나"를 한 번에 못 잡음
- "REQUEST · WORKING · REPORT READY" 3-row event 형식 + 시간 컬럼 = Outlook 같은 journal UI → 진행 상황 보기엔 부자연스러움
- 액션 버튼 6개 (Report / Copy / Terminal / Notify / Stop / Archive) 가 본문 집중도를 깎음

### 메타포 전환
사이드 에이전트는 "동료에게 시킨 일의 진행 상황". 따라서 **카드 = 채팅 스레드** 가 가장 자연스럽다.
- 유저 메시지(우) + 에이전트 메시지(좌) 흐름
- Phase 별 hero 버블 (typing / report / question / error)
- 큐 = 아직 안 보낸 유저 버블
- 큐 모드는 시각 grouping (단건 vs batch wrap)

---

## 1. 최종 UX 결정 사항 (스펙 Lock-in)

본 절에 적힌 결정은 PR 시 회고 없이 그대로 구현합니다.

> **NOTE**: 본 절의 모든 항목은 spec lock-in 완료 (Cycle 2 + 6 결정 반영). 이전 미결정 표시는 §7.10/§7.13/§7.14/§7.15/§7.16/§7.17 결정으로 모두 해제됨.

### 1.1 카드 구조 (모든 phase 공통)
1. **헤더** — π 뱃지(상태 색) + 제목 + status pill + ⋯ 메뉴
2. **컨텍스트 한 줄** — `📁 cwd · ⎇ branch · 🐙 #issue ...` (현재 3개 meta-row 통합)
3. **대화 영역** — 시간순으로 흐르는 버블들
4. **푸터(composer)** — 둥근 input + voice + send

### 1.2 Phase 별 hero 버블
| Phase | Hero | Pi 색 | composer placeholder | composer 상태 |
|---|---|---|---|---|
| `running` | typing bubble (실시간 thinking) | blue | `Steer this agent · ⌥↵ Follow-up · esc Stop` | active |
| `completed` | bubble-report (final report) | green | `Send a follow-up… · ⌥↵ Follow-up` | active (green send) |
| `waiting_for_input` | bubble-question (인라인 form) | amber | 동일 | active (steer 시 question 자동 cancel) |
| `failed` / `blocked` | bubble-error (에러 + 복구 chip) | red / amber | `원인 알려주거나 다른 방법 제안…` | active |
| `queued` | typing bubble("준비 중…") | blue | running 동일 | active |
| `cancelled` | system bubble("Cancelled by user") | gray | running 동일 | active |

### 1.3 큐 (Steering / Follow-up)
- **두 큐 모두 노출**, kind는 색·라벨로 구분 (`⚡ Steer` blue, `⤵ Follow-up` green)
- **각 큐의 mode 별도 표시** (Pi 의 `steeringMode` / `followUpMode` 그대로 준용, Picky 측에서 변경 UI 미제공)
  - `one-at-a-time`: 각 pending 버블이 분리되어 표시되며 mode 뱃지로만 구분
  - `all`: 같은 kind의 pending 버블들을 **dashed batch wrap** 으로 그룹핑, 헤더에 `idle 시점에 모두 (all)` 안내
- 빈 큐 → 두 섹션 / batch wrap 모두 미렌더 (자리도 차지하지 않음)
- **큐 비우기**: 큐는 단일 항목 제거 UI 미제공 (Pi SDK atomic remove API 부재). 사용자가 큐 전체를 비우려면 그룹 헤더의 "Clear all" 버튼 사용. 그룹별 (Steering / Follow-up) 별도 비우기.

### 1.4 키보드 (Pi 컨벤션 준용)
| 키 | 동작 | 발동 조건 |
|---|---|---|
| `↵` | Steer (interrupt) | composer focus + 텍스트 있음 |
| `⌥↵` | Follow-up (queue) | 동일 |
| `esc` | Stop session (abort) | composer 비어있음 + status가 abort 가능 (`running` / `queued` / `waiting_for_input`) |

### 1.5 ⋯ 메뉴
| 그룹 | 항목 | 단축키 | 활성 조건 |
|---|---|---|---|
| QUICK | Open Pi terminal | `⌘T` | `piSessionFilePath` 존재 + `!status.blocksTerminalOverlay` |
| QUICK | Open report | `⌘R` | `reportArtifact` 또는 `finalReport` 존재 |
| QUICK | Copy resume command | **없음** | `piSessionFilePath` 존재 |
| SETTINGS | Notify on completion (toggle) | 없음 | 항상 |
| SESSION | Stop session | `esc` | abort 가능한 status |
| SESSION | Archive | **없음** | 항상 |

> **단축키 정책**: Archive / Copy resume command 는 자주 쓰지 않고 실수로 누르면 위험 → 메뉴 전용. Stop은 `esc` 단축키 + 메뉴 둘 다.

### 1.6 활동 요약 strip
- 위치: 첫 user 메시지 직후 또는 final report 직전 (대화 흐름의 "여기까지 이만큼 일했음" 위치)
- 내용: 4개 chip — `✏ edit N` (blue) · `⌨ bash N` (amber) · `⌁ thinking N` (gray) · `⊞ 기타 N` (purple)
- 카운트 분류:
  - `edit` = `edit` + `write` + `multiedit` 도구 호출 합계
  - `bash` = `bash` 도구 호출 횟수
  - `thinking` = thinking step 횟수 (도구 호출 아님)
  - `기타` = 위 3개 외 모든 도구 호출 (`read`, `grep`, MCP, custom 등)
- **strip 전체가 클릭 가능** → Pi terminal overlay 열기 (별도 expand 없음)
- hover 시 outline 강조
- **삽입 책임**: Swift 측이 카드 렌더 시점에 `session.activitySummary` 와 `session.messages` 를 보고 deterministic 위치에 `PickyActivitySummaryView` 1개를 삽입한다. agentd 는 message stream 에 strip 메시지를 emit 하지 않는다.
- **위치 규칙**: 첫 user_text 메시지 직후. final report 가 있으면 final report 직전(즉, 첫 user_text와 final report 사이). 둘 다 충족 안 되는 phase(예: queued)에선 strip 미렌더.
- **렌더 조건**:
  - 모든 카운트 합 = 0 → strip 미렌더 (위치 자체 비움)
  - 한 카테고리라도 ≥ 1 → 4 chip 모두 표시 (값이 0인 chip 도 노출)
  - pinned 세션 → 항상 미렌더 (외부 Pi 작업이라 카운트 의미 없음)
  - `queued` phase + 첫 tool 이벤트 전 → 미렌더
  - 위 조건은 `PickyActivitySummaryView` 에서 판단; agentd 는 항상 카운터 emit.

### 1.7 Final report (`submit_final_report` 도구)
- Picky가 직접 시작한 사이드 에이전트는 **마지막에 반드시 `submit_final_report` 도구를 호출**해야 끝날 수 있음 (시스템 프롬프트로 강제)
- 도구 인자가 카드의 rich agent 버블로 직렬 렌더
- 인자 스키마:
  ```ts
  submit_final_report({
    summary: string,                              // 1-2문장 헤드라인
    body: string,                                 // markdown body (변경/검증 등 자유 형식)
    status: "success" | "partial" | "blocked",    // status pill 색상 결정
    artifacts?: { kind: string, title: string, url?: string }[]
  })
  ```
- **`suggested_next` 필드는 도입하지 않음** (의사결정 결과 — 시안 단계에서 제거)
- **예외**: `pinSideSession`(Pi extension handoff)으로 pin 된 카드는 Picky 에이전트가 실행되지 않으므로 `submit_final_report` 도 없음. 이 경우 `finalReport` 는 `nil`, fallback으로 `finalAnswer` 텍스트("Pinned from an idle Pi session...")를 일반 `agent_text` 버블로 렌더 (§1.8 참조)

### 1.8 핸드오프 / 외부 입력 소스 분리

사이드 카드 세션이 만들어지거나 메시지가 추가되는 경로는 다음 6가지. 모두 `PickySessionMessage` 시퀀스로 평탄화되지만, 빌더는 source 별로 다르게 매핑한다:

| 소스 | 트리거 | 카드 표현 |
|---|---|---|
| 사용자 직접 steer | composer `↵` | `user_text` 버블, 마커 없음 |
| 사용자 직접 follow-up | composer `⌥↵` | `user_text` 버블, 마커 없음 (queue → delivered 되면 일반 user_text로 합류) |
| 사용자 askUserQuestion 응답 | question bubble Submit | `user_text` 버블, 마커 없음 (`extension ui answer: ` 로그 prefix 변환) |
| Main agent `picky_handoff` (세션 생성) | main agent → 도구 호출 | 첫 `user_text` 버블 + 작은 "by main agent" subtle 라벨 (`main-agent handoff: ` 로그 prefix 변환) |
| Main agent `picky_side_steer` (기존 세션 steer) | main agent → 도구 호출 | `user_text` 버블 + "by main agent" subtle 라벨 |
| Pi extension `pinSideSession` (외부 import) | Pi 터미널 `/handoff-to-picky` | 1회성 — 첫 `user_text`(handoff goal) + `system` 버블("Pinned from Pi terminal · 이 카드는 외부 Pi 세션 스냅샷입니다") |

구체 동작:

- **사용자 vs 메인 에이전트 구분**: bubble 내용은 같은 `user_text` kind 로 통일하되, `originatedBy: "user" | "main_agent" | "pi_extension"` 메타 필드로 분기. UI 는 `main_agent` / `pi_extension` 일 때만 작은 라벨 노출 (예: bubble 우측 하단에 "by main agent" 9pt). 일반 사용자 메시지에는 라벨 없음.
- **Pinned 세션 (pin_side_session)**: status가 처음부터 `completed`. activity summary 모두 0. message 시퀀스는 `[user_text(handoff goal), system("Pinned from Pi terminal"), agent_text(finalAnswer)]` 3개로 끝. composer 는 active (steer/follow-up 가능). 사용자가 첫 follow-up 입력 시 agentd 가 `piSessionFilePath` 에서 `runtime.resume()` 시도하여 진짜 Pi 세션 reattach. 실패 시 user-visible error bubble 로 안내 ("Pi 세션 reattach 실패: 외부 Pi terminal 에서 이어가세요").
- **Main agent handoff 시 first user_text**: `instructions` 가 본문, `userMessage`(있으면) 는 별도 노출 안 함 (main agent가 사용자에게 따로 전달하는 콘텐츠임).
- **waiting_for_input 중 steer 처리**: 사용자 또는 main agent 가 `⚡ Steer` 보내면 활성 `pendingExtensionUiRequest` 자동 cancel (`answerExtensionUi` 와 별도 경로). question bubble 은 시각적으로 cancelled 상태로 전환(회색 + 취소선) 후 그 아래 새 `user_text` + agent 응답 흐름. follow-up 도 동일.

### 1.9 보이스 입력
- composer 내 `🎙` 버튼이 push-to-talk 트리거 (기존 voice steering target 동작 재활용)
- 텍스트와 동등한 1급 시민

### 1.10 미니 상태 처리
- **Queued**: typing bubble 한 개("준비 중…"), thinking 텍스트는 없을 수 있음
- **Cancelled**: 마지막 메시지 위에 small system bubble (`Cancelled by user`)
- **Blocked (runtime detached)**: error 버블 패턴 동일, amber 톤 + `⌨ Resume from terminal` 복구 chip

---

## 2. 도메인 모델 변경

### 2.1 신규 타입 (agentd 측, Zod schema)

`agentd/src/protocol.ts`에 추가:

```ts
// 큐 mode
export const PickyQueueModeSchema = z.enum(["one-at-a-time", "all"]);
export type PickyQueueMode = z.infer<typeof PickyQueueModeSchema>;

// 큐 항목
export const PickyQueueItemSchema = z.object({
  text: z.string(),
  enqueuedAt: isoTimestamp,
});
export type PickyQueueItem = z.infer<typeof PickyQueueItemSchema>;

// 활동 카운터
export const PickyActivitySummarySchema = z.object({
  edit: z.number().int().min(0),
  bash: z.number().int().min(0),
  thinking: z.number().int().min(0),
  other: z.number().int().min(0),
});
export type PickyActivitySummary = z.infer<typeof PickyActivitySummarySchema>;

// final report
export const PickyFinalReportSchema = z.object({
  summary: z.string(),
  body: z.string(),
  status: z.enum(["success", "partial", "blocked"]),
  artifacts: z.array(z.object({
    kind: z.string(),
    title: z.string(),
    url: z.string().url().optional(),
  })).default([]),
});
export type PickyFinalReport = z.infer<typeof PickyFinalReportSchema>;

// 세션 메시지 (대화 스트림)
export const PickySessionMessageSchema = z.object({
  id: z.string(),
  kind: z.enum([
    "user_text",      // 유저가 보낸 메시지 (steer/followUp 결과로 deliver됨)
    "agent_text",     // 에이전트 일반 응답 (final report 외)
    "agent_thinking", // typing 버블 (현재 thinking text), 일시적
    "agent_question", // pendingExtensionUiRequest 변환
    "agent_report",   // submit_final_report 결과
    "agent_error",    // 에러 메시지
    "system",         // "Cancelled by user" 같은 시스템 알림
  ]),
  createdAt: isoTimestamp,
  originatedBy: z.enum(["user", "main_agent", "pi_extension"]).optional(), // user_text kind일 때만 의미 있음 (기본 user)
  // kind별 payload
  text: z.string().optional(),
  question: PickyExtensionUiRequestSchema.optional(),
  cancelledAt: isoTimestamp.optional(),  // agent_question 만 사용
  report: PickyFinalReportSchema.optional(),
  errorContext: z.string().optional(),
  errorMessage: z.string().optional(),
});
export type PickySessionMessage = z.infer<typeof PickySessionMessageSchema>;
```

### 2.2 `PickyAgentSession` 확장

```ts
export const PickyAgentSessionSchema = z.object({
  // ... 기존 필드 그대로
  // 신규
  messages: z.array(PickySessionMessageSchema).default([]),
  queuedSteers: z.array(PickyQueueItemSchema).default([]),
  queuedFollowUps: z.array(PickyQueueItemSchema).default([]),
  steeringMode: PickyQueueModeSchema.default("one-at-a-time"),
  followUpMode: PickyQueueModeSchema.default("one-at-a-time"),
  activitySummary: PickyActivitySummarySchema.default({ edit: 0, bash: 0, thinking: 0, other: 0 }),
  finalReport: PickyFinalReportSchema.optional(),
});
```

> 기존 `lastSummary`, `thinkingPreview`, `finalAnswer`, `tools`, `pendingExtensionUiRequest`, `logs`는 `messages` 빌더의 입력으로만 사용. 외부 노출은 점진적으로 제거 (3단계 참조).

### 2.3 신규 명령 (CommandEnvelope)

`agentd/src/protocol.ts`의 `CommandEnvelopeSchema` 에 discriminated 추가:

```ts
CommandBaseSchema.extend({
  type: z.literal("clearQueue"),
  sessionId: z.string(),
  kind: z.enum(["steering", "followUp", "all"]),  // 그룹 선택 또는 전체
}),
```

### 2.4 신규 이벤트 (EventEnvelope)

```ts
EventBaseSchema.extend({
  type: z.literal("sessionMessageAppended"),
  sessionId: z.string(),
  message: PickySessionMessageSchema,
  seq: z.number().int(),     // per-session monotonic
}),
EventBaseSchema.extend({
  type: z.literal("sessionMessageReplaced"),
  sessionId: z.string(),
  messageId: z.string(),
  message: PickySessionMessageSchema,
  seq: z.number().int(),     // per-session monotonic
}),
EventBaseSchema.extend({
  type: z.literal("sessionMessageRemoved"),
  sessionId: z.string(),
  messageId: z.string(),
  seq: z.number().int(),     // per-session monotonic
}),
EventBaseSchema.extend({
  type: z.literal("sessionQueueUpdated"),
  sessionId: z.string(),
  steering: z.array(PickyQueueItemSchema),
  followUp: z.array(PickyQueueItemSchema),
  steeringMode: PickyQueueModeSchema.optional(),
  followUpMode: PickyQueueModeSchema.optional(),
}),
EventBaseSchema.extend({
  type: z.literal("sessionActivityUpdated"),
  sessionId: z.string(),
  activitySummary: PickyActivitySummarySchema,
}),
```

> `sessionQueueUpdated` 의 mode 필드는 mode 변경이 감지된 경우에만 포함. 변동 없으면 생략하며, Swift는 `nil` 수신 시 기존 값을 유지한다.

### 2.5 Swift 미러 (`Picky/PickyAgentProtocol.swift`)

- `PickyQueueMode`, `PickyQueueItem`, `PickyActivitySummary`, `PickyFinalReport`, `PickySessionMessage` 모두 `Codable` struct/enum으로 미러
- `PickySessionMessage` 에 `originatedBy: PickyMessageOrigin?` 추가 (`user_text` kind일 때만 의미 있음, 기본은 user; pinned 세션의 첫 `user_text` 와 `system` 표시에 `piExtension` 사용)
- `PickyAgentSession` 에 동일 필드 추가 (default 값 포함)
- `PickyAgentEvent` enum 에 5개 신규 case 추가, decoding 분기 추가 (`sessionMessageRemoved` 포함). 메시지 이벤트 3종은 `seq`, `sessionQueueUpdated` 는 optional `steeringMode` / `followUpMode` 를 `decodeIfPresent` 로 미러링한다.
- **Decoding 정책**: 모든 신규 필드는 `decodeIfPresent` + Swift-side default 로 처리. `PickyAgentSession` 의 `init(from:)` 을 명시적으로 작성(synthesized `Codable` 사용 안 함). 누락 시 빈 배열 / `.oneAtATime` / `nil` / `.zero` 등으로 안전 fallback.

---

## 3. agentd 백엔드 작업

### 3.1 `submit_final_report` 도구 정의 + 주입

**파일**: `agentd/src/tools/submit-final-report.ts` (신규)

- Pi SDK `ToolDefinition` 형식으로 정의 (`agentd/src/runtime/pi-sdk-runtime.ts` 의 도구 등록 흐름 참조)
- 인자 스키마는 `PickyFinalReportSchema` 와 동일 (재사용)
- 호출 시 동작:
  1. supervisor에 `setFinalReport(sessionId, report)` 호출 (`finalReport` 저장, Step 1 호환을 위해 `finalAnswer = report.summary` 도 patch)
  2. session.status patch 는 turn-end 까지 지연 (§7.15 Option C)
  3. 도구 결과로 `"Final report recorded"` 같은 짧은 ack 반환

**주입 위치**: `agentd/src/runtime/pi-sdk-runtime.ts` 에서 side session 생성 시 `customTools` 배열에 추가. 시스템 프롬프트(`agentd/src/prompt-builder.ts` 또는 `contracts/prompts/`) 강제 지시는 Step 2 에서 ConversationCard 와 함께 활성화한다.

> **Step 1 호환 NOTE**: Step 1 에서는 도구 정의만 추가한다. 도구가 호출되면 `finalReport` 와 함께 `finalAnswer = report.summary` 도 동시 patch 하여 기존 UI 회귀를 방지한다.

> **Lifecycle (turn-end)**: 도구 호출 시점엔 `finalReport` 필드만 supervisor 에 patch (status 변경 없음). 도구 result 는 모델로 다시 들어감(모델이 도구 후 텍스트 emit 가능 — 일반 `agent_text` 로 함께 표시). turn 종료(Pi SDK status 이벤트가 idle/completed 로 전환) 시점에 supervisor 가 status = `report.status === "blocked" ? "blocked" : "completed"` 로 patch. 한 turn 안에 도구가 두 번 호출되면 last-wins-within-turn(마지막 report 가 최종).

### 3.2 활동 카운터 (tool 분류)

**파일**: `agentd/src/session-supervisor.ts`

- `private toolCategorizer(toolName: string): "edit" | "bash" | "other"` 헬퍼
  - `["edit", "write", "multiedit"]` → `"edit"`
  - `["bash"]` → `"bash"`
  - 그 외 (read, grep, MCP `*`, 커스텀 등 모두) → `"other"`
- `runtime-event-handler` (또는 동등 위치)에서 tool_call 이벤트 감지 시 supervisor에 `incrementActivity(sessionId, category)` 호출
- thinking step 감지: assistant message에 thinking 블록이 있을 때마다 `incrementActivity(sessionId, "thinking")`
  - Pi SDK 가 thinking 시작/종료 이벤트를 별도로 emit 하는지 확인 필요 (없으면 turn 단위로 thinking 1로 집계)
- 카운터 값 변경 시 `sessionActivityUpdated` 이벤트 emit

### 3.3 큐 노출 + 모드

**파일**: `agentd/src/runtime/pi-sdk-runtime.ts` + `session-supervisor.ts`

- **선행 작업**: `RuntimeSessionHandle` 인터페이스(`agentd/src/runtime/types.ts`)에 다음 멤버 추가가 필요:
  - `clearQueue(): { steering: string[]; followUp: string[] }`  // 동기, Pi SDK 시그니처 그대로
  - `getSteeringMessages(): readonly string[]`
  - `getFollowUpMessages(): readonly string[]`
  - `get steeringMode(): PickyQueueMode`
  - `get followUpMode(): PickyQueueMode`
  - `PiSdkRuntimeSession` 구현(`runtime/pi-sdk-runtime.ts`)은 위 메서드/getter를 `agentSession`에 위임. `MockRuntime`(`runtime/mock-runtime.ts`)도 테스트용 스텁 추가.
- runtime adapter 가 `agentSession.queue_update` 이벤트 + `getSteeringMessages()` / `getFollowUpMessages()` / `steeringMode` / `followUpMode` getter를 supervisor에 노출
- supervisor 는 Pi SDK `queue_update` 이벤트를 받아 `queuedSteers` / `queuedFollowUps` 를 갱신. 각 항목은 `{ text, enqueuedAt }` (`enqueuedAt` 은 supervisor 수신 시각). Pi SDK 가 항목 ID 를 노출하지 않으므로 supervisor 도 ID 매핑 안 함.
- **확인 완료**: Pi SDK에 mode 변경 전용 이벤트 없음 (`AgentSessionEvent` 유니온 검토). 감지 전략:
  1. 초기 세션 bind 시 한 번 읽어 snapshot 에 포함
  2. `queue_update` 이벤트 수신 시마다 `handle.steeringMode` / `followUpMode` 를 읽어 이전 값과 비교, 변경 시 mode 도 함께 `sessionQueueUpdated` 이벤트에 포함하여 emit
  3. 사용자가 외부 Pi terminal에서 mode 변경 후 큐 조작이 없으면 다음 enqueue/drain 까지 카드 mode 표시가 stale 할 수 있음 — 허용 가능한 lag 으로 간주
- 변경 시 `sessionQueueUpdated` 이벤트 emit

### 3.4 큐 조작 RPC

**파일**: `agentd/src/server.ts` + `session-supervisor.ts`

**`clearQueue(sessionId, kind)`**:
1. `kind === "steering"` → `agentSession.clearQueue()` 호출 후 `followUp` 큐만 다시 enqueue (Pi SDK 가 둘 다 같이 비움)
2. `kind === "followUp"` → 동일 패턴, steering 만 다시 enqueue
3. `kind === "all"` → `agentSession.clearQueue()` 호출, 재 enqueue 없음

**재 enqueue 시 NOTE**: Pi SDK `clearQueue()` 결과 텍스트는 이미 expand 된 상태 → `steer()` / `followUp()` 의 expand 로직이 재적용되어도 `/skill:` / `/template` 패턴이 없으므로 실질 이중확장 없음.

단일 항목 제거 RPC 미제공 (§7.13/§7.16 결정).

### 3.5 세션 메시지 스트림 빌더

**파일**: `agentd/src/session-message-builder.ts` (신규)

**선행 작업: Append-only message journal**

Builder 의 입력은 supervisor 가 유지하는 in-memory append-only journal. 각 entry 는:
- `seq: number` (monotonic, 세션 내 고유)
- `id: string` (stable, message ID 가 됨)
- `kind`, payload, source 메타

Journal 은 다음 source 에서 entry 를 받아 즉시 push:
- Pi SDK assistant_message 이벤트 → agent_text/agent_thinking
- tool_call 이벤트 → activitySummary 갱신 (journal entry 아님)
- extensionUiRequest → agent_question
- submit_final_report 도구 호출 → agent_report
- user steer/followUp deliver → user_text
- cancelled / failed 진입 → system / agent_error

Journal 은 디스크 영속화 1차 출시에선 미수행(in-memory only) — daemon restart 시 logs 기반으로 best-effort 복원. 영속화는 §7 열린 질문.

- `PickyAgentSession` 의 기존 필드/이벤트들을 입력으로 받아 `PickySessionMessage[]` 생성
- 입력 → 출력 매핑 표:

| 입력 | 출력 메시지 | originatedBy | 비고 |
|---|---|---|---|
| Pi SDK `user_message` 전송 (composer steer) | `user_text` | `user` | 로그 prefix `steer: ` 매칭 |
| Pi SDK `user_message` 전송 (composer follow-up) | `user_text` | `user` | 로그 prefix `follow-up: ` 매칭 |
| Pi SDK `user_message` 전송 (extension UI answer) | `user_text` | `user` | 로그 prefix `extension ui answer: ` 매칭 |
| Pi SDK `user_message` 전송 (main-agent handoff/steer) | `user_text` | `main_agent` | 로그 prefix `main-agent handoff: ` 매칭 |
| `pinSideSession` 의 handoff goal (transcript 첫 줄) | `user_text` | `pi_extension` | 세션 생성 시 1회성 |
| `pinSideSession` 의 "Pinned from idle Pi session" | `system` | — | 세션 생성 시 1회성 |
| `pendingExtensionUiRequest` 활성화 | `agent_question` | — | 단일 메시지, ID는 request.id 그대로 사용 |
| RuntimeEvent `assistant_delta` 누적 | `agent_text` | — | Builder 내부에서 delta 누적 → 다음 boundary(status 이벤트 `running→idle`/`waiting_for_input`/`failed`/`cancelled`, 또는 다음 user_text 도착, 또는 tool_call 시작) 에서 누적분을 단일 `agent_text` 로 commit + `sessionMessageAppended` emit. 한 turn 내 tool→text→tool 패턴이면 여러 개의 `agent_text` 메시지 가능. |
| RuntimeEvent `assistant_thinking_delta` 누적 | `agent_thinking` | — | 같은 message ID 로 매 delta 마다 `sessionMessageReplaced` emit. idle/completed/waiting_for_input 진입 시 `sessionMessageRemoved` emit. |
| `submit_final_report` 도구 호출 | `agent_report` | — | `finalReport` 필드도 동시 patch. turn-end 시점에 status patch. 도구 호출 자체는 finalReport 만 저장(Step 2 부터 강제, Step 1 에선 정의만). |
| Runtime error / failed status 진입 | `agent_error` | — | `errorMessage` + `errorContext` payload |
| `cancelled` status 진입 | `system` | — | `"Cancelled by user"` |

- 출력: 시간순 배열, deduplicated, 각 메시지 안정적인 ID 보유
- 변경 시 `sessionMessageAppended` (단일 추가), `sessionMessageReplaced` (typing 갱신 등), `sessionMessageRemoved` (typing 제거) 이벤트 emit
- 첫 sessionSnapshot 에서는 전체 messages 배열을 함께 보냄

> **typing 메시지 처리 노트**: `agent_thinking` 은 thinking text가 갱신될 때마다 같은 message ID로 `sessionMessageReplaced` emit. idle/completed/waiting_for_input 진입 시 `sessionMessageRemoved` emit. 클라이언트는 둘 다 처리해야 함.

> **활동 strip 노트**: 활동 strip은 메시지가 아니라 Swift 측 derived view. agentd 는 `activitySummary` 카운터만 노출.

> **로그 prefix 의 역할**: live path 에서 builder 의 SoT 는 append-only journal **유일**. 기존 로그 prefix (`steer: ` / `follow-up: ` / `main-agent handoff: ` / `extension ui answer: `) 는 daemon restart / migration 시점의 best-effort 복원 경로에서만 사용(journal 미존재 시). 양 환경에서 동일 prefix 상수 모듈을 공유.

**클라이언트 reducer 규칙**:
- `appended`: messageId 가 이미 있으면 무시(idempotent), 없으면 추가
- `replaced`: 해당 messageId 가 없으면 무시, 있으면 payload 교체
- `removed`: 해당 messageId 가 없으면 무시(no-op), 있으면 제거
- `seq` 가 마지막 처리값보다 작거나 같으면 stale event 로 간주, 무시
- `sessionSnapshot` 수신 시 해당 세션의 모든 in-flight 이벤트를 무효화하고 `snapshot.messages` 로 reset

**서버 emit 규칙**:
- 각 이벤트 emit 시 supervisor 가 per-session 카운터 증가시켜 `seq` 채움
- removed 후 동일 messageId 로 replace 절대 금지(제거된 메시지는 영원히 제거)

### 3.6 follow-up vs steer 분기 (이미 존재하는 코드 정리)

**현재**: `agentd/src/session-supervisor.ts:709` `if (this.isSideSession(sessionId)) return this.steerSideSession(...)` — side session에선 followUp이 항상 steer로 routing 됨.

**변경 후**: side session도 두 경로 분리.
- `followUp(...)` → `agentSession.followUp(text)` (queue, drain at idle)
- `steer(...)` → `agentSession.steer(text)` (queue, drain after current turn)

`steerSideSession` 의 기존 동작(`clearSideCompletionTracking`, pinned 해제) 은 양 경로 모두에서 수행하도록 헬퍼로 추출.

**waiting_for_input 자동 cancel**: `steer` / `followUp` 진입 시 `pendingExtensionUiRequest` 가 있으면 supervisor 가 먼저 `cancelExtensionUi` 처리(`pendingExtensionUiRequest = undefined`, status = running, `agent_question` 메시지에 `cancelledAt` 추가) 후 본 흐름 진행.

### 3.7 ⋯ 메뉴 데이터 노출

대부분 기존 필드로 충분:
- `Open Pi terminal` → 기존 `openTerminalOverlay` RPC 재사용
- `Open report` → `reportArtifact` 또는 `finalReport` 존재 여부로 활성화 판단
- `Copy resume command` → `piSessionFilePath`
- `Notify on completion` → `notifyMainOnCompletion` toggle, 기존 `setNotifyMainOnCompletion` RPC 재사용
- `Stop session` → 기존 `abort` RPC 재사용
- `Archive` → 기존 `setSessionArchived` RPC 재사용

신규 작업 없음.

### 3.8 Pinned 세션 reattach 흐름

pinned 세션은 생성 시 runtime handle 없이 status=completed. 사용자가 follow-up 입력 시:

1. supervisor 의 `followUp` / `steer` 진입 → handle 없음 감지
2. 기존 `tryResumeRuntimeHandle` (`session-supervisor.ts`) 재사용 — `piSessionFilePathFromLogs(session.logs)` 또는 pin 시 저장한 `piSessionFilePath` 필드 사용
3. resume 성공 → handle 등록 + 일반 follow-up 흐름 진행
4. resume 실패 → status 변경 없이 `agent_error` 메시지 추가 + composer 다음 입력 활성 유지

---

## 4. Picky Swift / SwiftUI 작업

### 4.1 ViewModel 확장

**파일**: `Picky/PickySessionViewModel.swift`

`SessionCard` struct 에 신규 필드 추가:
```swift
var messages: [PickySessionMessage] = []
var queuedSteers: [PickyQueueItem] = []
var queuedFollowUps: [PickyQueueItem] = []
var steeringMode: PickyQueueMode = .oneAtATime
var followUpMode: PickyQueueMode = .oneAtATime
var activitySummary: PickyActivitySummary = .zero
var finalReport: PickyFinalReport?
```

신규 computed:
```swift
/// total queue count (헤더 sub용)
var totalQueuedCount: Int { queuedSteers.count + queuedFollowUps.count }
```

신규 RPC 호출 메서드:
```swift
func clearQueue(sessionID: String, kind: PickyQueueKind) async throws { ... }
```

`steer` / `followUp` 호출 분리 — 현재 `followUp(text:sessionID:)` 단일 메서드를 두 갈래로:
```swift
func steer(text: String, sessionID: String? = nil) async throws { ... }   // .steer envelope
func followUp(text: String, sessionID: String? = nil) async throws { ... } // .followUp envelope (그대로)
```

### 4.2 신규 SwiftUI 뷰 트리

**디렉터리**: `Picky/HUD/Conversation/` (신규)

| 파일 | 역할 |
|---|---|
| `PickyConversationCardView.swift` | 카드 컨테이너 (header + list + composer) |
| `PickyConversationHeaderView.swift` | π badge, title, status pill, ⋯ 메뉴 trigger |
| `PickyConversationContextLineView.swift` | cwd · branch · gh links 한 줄 |
| `PickyConversationListView.swift` | ScrollView + 메시지 ForEach |
| `Bubbles/PickyUserBubbleView.swift` | 유저 메시지 (우) |
| `Bubbles/PickyAgentBubbleView.swift` | 에이전트 일반 메시지 (좌) |
| `Bubbles/PickyTypingBubbleView.swift` | thinking 버블 (애니메이션 dots) |
| `Bubbles/PickyPendingBubbleView.swift` | 큐 항목 (steer/followUp 색 분리, hover × / latest outline 없음) |
| `Bubbles/PickyBatchGroupView.swift` | `all` mode 그룹 wrapper |
| `Bubbles/PickyActivitySummaryView.swift` | 4-chip strip, click → terminal |
| `Bubbles/PickyFinalReportBubbleView.swift` | rich report (summary + body markdown + artifacts) |
| `Bubbles/PickyQuestionBubbleView.swift` | `agent_question` 인라인 form (기존 `PickyPendingInputView` 흡수, `cancelledAt` 있으면 회색 + 취소선 + Submit/Cancel 비활성) |
| `Bubbles/PickyErrorBubbleView.swift` | error + 복구 chip |
| `Composer/PickyConversationComposerView.swift` | input + voice + send + key handler |
| `Menu/PickyConversationMenu.swift` | ⋯ 메뉴 popover (NSMenu 또는 Menu 뷰) |


큐 UI 세부:
- `PickyPendingBubbleView` 에서 hover × 버튼과 latest outline 로직은 구현하지 않는다.
- 큐 그룹 헤더(`group-head`) 에 "Clear all" 작은 버튼을 추가한다(steer / followUp 별).
- `PickyConversationComposerView` 키 핸들러에는 `⌥↑` 분기를 두지 않는다.

### 4.3 키보드 핸들링

**파일**: `Composer/PickyConversationComposerView.swift`

- `TextField` 의 `.onKeyPress(.return)` / `.onKeyPress(.escape)` 에 modifier 검사
- 분기:
  ```swift
  switch (key, modifiers, isTextEmpty) {
    case (.return, [],          _):     submitSteer()
    case (.return, .option,     _):     submitFollowUp()
    case (.escape, [],         true):   abortSession()  // 아무 modifier 없을 때만
    default: nil  // 기본 동작 통과
  }
  ```
- ESC 시 status가 abort 가능한 phase 인지 추가 검사. 안 되는 phase 면 무시.

### 4.4 ⋯ 메뉴 구현

- SwiftUI `Menu { ... } label: { Image("ellipsis") }` 또는 NSMenu 직접 (호버 popover 동작에 따라)
- 단축키 매핑:
  - `Open Pi terminal` → `.keyboardShortcut("t", modifiers: .command)`
  - `Open report` → `.keyboardShortcut("r", modifiers: .command)`
  - `Stop session` → 단축키는 composer의 ESC가 처리, 메뉴 항목엔 `esc` 라벨만 표시
  - **Archive / Copy resume / Notify toggle 은 단축키 없음** (사용자 요청)
- `disabled` modifier 로 조건부 비활성화

### 4.5 기존 → 신규 매핑

`Picky/HUD/PickyHUDView.swift` 의 `PickySessionCardView` 는 deprecated → 새 `PickyConversationCardView` 가 대체. expand/collapse 흐름 (`PickyHUDExpansion`, `PickyHUDDockLayout`) 은 그대로 사용 가능.

`PickyHUDView` 의 `activeSession` 로직, hover preview, pin 동작은 변경 없음. 카드 내부만 교체.

### 4.6 보이스 입력 통합

기존 `BuddyDictationManager` + `CompanionManager` 의 voice steering target 흐름을 composer의 🎙 버튼에 연결:
- 🎙 mousedown → push-to-talk 시작
- 🎙 mouseup → 종료, 인식된 텍스트가 composer input 에 채워짐 (자동 send 아님, 한 번 더 검토 후 send)
- 또는 자동 send 옵션을 settings 에 추가 검토

> 음성 → 자동 steer/followUp 전송 정책은 별도 결정 필요 (4.7 열린 질문)

---

## 5. 마이그레이션 / 제거 대상

### 5.1 제거할 코드 (deprecated → delete)

| 위치 | 제거 사유 |
|---|---|
| `Picky/HUD/PickyHUDView.swift` `PickySessionCardView` 전체 | 신규 `PickyConversationCardView` 가 대체 |
| `Picky/HUD/PickyHUDLayoutPolicy.swift` `PickyHUDExpandedContentPolicy` | event row 정책. 새 메시지 모델은 builder가 결정 |
| `Picky/HUD/PickyHUDLayoutPolicy.swift` `PickyHUDSummaryEventPolicy` | 동일 |
| `Picky/HUD/PickyHUDLayoutPolicy.swift` `PickyHUDCurrentWorkPolicy` | activeTool 제거됨, thinking은 typing bubble로 |
| `Picky/PickyPendingInputView` (`PickyHUDView.swift` 내) | `PickyQuestionBubbleView` 로 흡수 |
| `Picky/HUD/PickyHUDView.swift` `eventRow / detailSection / metaRow` 등 헬퍼 | 신규 컴포넌트 사용 |
| `agentd/src/session-supervisor.ts` `if (this.isSideSession(sessionId)) return this.steerSideSession(...)` (followUp 우회) | side session도 followUp/steer 분리 |

### 5.2 보존할 코드

- `PickyHUDDockLayout`, `PickyHUDExpansion` — 도크/카드 expand 흐름은 그대로
- `PickyHUDDockRailView` (도크 아이콘 rail) — 변경 없음
- `PickyAgentClient`, `PickyAgentDaemonLauncher`, 프로토콜 envelope 구조 — 확장만, 제거 없음
- `lastSummary`, `thinkingPreview`, `finalAnswer`, `tools`, `pendingExtensionUiRequest`, `logs` — 1차 출시까지는 유지 (메시지 builder 입력으로 사용), 2차에서 deprecation 검토

### 5.3 핸드오프 영역 — 변경 없음

다음 코드는 본 리팩터 범위 **밖**. 인터페이스 호환성을 깨지 않는다:

- `pi-extensions/picky-handoff/index.ts` — Pi 터미널 측 `handoff-to-picky` 명령. `pinSideSession` RPC 를 호출하는 클라이언트.
- `agentd/src/application/handoff-tool.ts` — main agent 도구 3종 (`picky_handoff`, `picky_side_sessions`, `picky_side_steer`). 기존 `PickyAgentSession` 형식을 입출력으로 사용.

변경 영향:

- 두 핸드오프 모두 기존 `pinSideSession` / `createTask` / `steer` / `followUp` RPC 를 그대로 사용하므로 명령 envelope 불변 (확장만).
- 다만 **봇 출력에 `messages` / `queuedSteers` / `queuedFollowUps` / `activitySummary` / `finalReport` 필드가 새로 노출**됨에 따라:
  - `picky_side_sessions` / `picky_side_steer` 의 `summarizeSideSession` 결과에 신규 필드를 함께 포함할지 결정 필요. 1차에선 추가 안 함 (main agent context window 절약). 2차에서 finalReport 요약 정도만 포함 검토.
  - `pi-extensions/picky-handoff` 는 outbound 만 하므로 응답 schema 변경 영향 없음.

---

## 6. 단계별 출시 계획

대규모 변경이므로 3단계로 분할. 각 단계가 PR 1~2개에 해당.

### Step 1 — 백엔드 데이터 모델 정비 (UI 변경 없음)
- [ ] 신규 Zod schema (`PickyQueueMode`, `PickyQueueItem`, `PickyActivitySummary`, `PickyFinalReport`, `PickySessionMessage`) 추가
- [ ] `PickySessionMessage` 에 `originatedBy: "user" | "main_agent" | "pi_extension"` 메타 필드 포함
- [ ] `PickyAgentSession` 필드 확장 (default 값으로 backwards-compat)
- [ ] 신규 RPC 명령(`clearQueue`) + 이벤트 정의 + parsing
- [ ] `submit_final_report` 도구 정의 + Picky가 시작한 side session 에만 customTools 로 등록(시스템 프롬프트 강제 주입은 Step 2 와 같이 진행). Step 1 단계에서는 도구가 호출되어도 기존 카드는 `lastSummary` / `finalAnswer` 만 읽으므로 시각 변화 없음. 도구 결과는 `finalReport` 필드에만 저장하고, 기존 카드는 fallback 으로 `finalAnswer = report.summary` 도 동시 patch 하여 회귀 방지.
- [ ] 활동 카운터 + `sessionActivityUpdated` 이벤트 emit (pinned 세션은 항상 0)
- [ ] RuntimeSessionHandle 확장 + PiSdkRuntimeSession 구현 + MockRuntime 스텁
- [ ] 큐 노출 + `sessionQueueUpdated` 이벤트 emit
- [ ] `clearQueue` RPC(그룹별 / 전체) 구현
- [ ] append-only message journal + `session-message-builder` 모듈 + 단위 테스트 (6가지 source 모두 커버)
- [ ] 로그 prefix 상수 (`steer: ` / `follow-up: ` / `main-agent handoff: ` / `extension ui answer: `) 를 양측 공유 모듈로 분리
- [ ] follow-up vs steer 분기 분리 (side session, `session-supervisor.ts:709`)
- [ ] Swift 미러 타입 + Codable 보강
- [ ] `agentd/src/protocol.ts` 의 `PROTOCOL_VERSION` 을 새 날짜로 bump (예: `"2026-XX-YY"`). 모든 신규 envelope 이 이 version 사용.
- [ ] `PickyAgentClient` 가 `hello` 수신 시 `supportedProtocolVersions` 에 자체 client version 포함 여부 검사. 미포함 시 daemon 종료 후 재실행(`PickyAgentDaemonLauncher` 가 새 binary 로 spawn).
- [ ] daemon 측: command parsing 이 이미 `z.literal(PROTOCOL_VERSION)` 이므로 mismatch 시 자동 거부. 별도 로직 불필요.
- [ ] 테스트: `agentd/src/session-supervisor.test.ts`, `runtime/pi-sdk-runtime.test.ts`, 신규 `session-message-builder.test.ts`
  - 특히 `pinSideSession` → 메시지 시퀀스가 `[user_text(goal), system("Pinned"), agent_text(finalAnswer)]` 으로 변환되는지
  - `picky_handoff` 로 생성된 세션의 첫 user_text 가 `originatedBy: "main_agent"` 인지

**검증**: 기존 UI는 그대로 동작해야 함 (regression). 신규 필드는 비어있을 뿐, 카드 깨짐 없음. Pi extension `handoff-to-picky` 명령도 그대로 동작.

### Step 2 — 신규 ConversationCardView 구현 (feature flag 뒤)
- [ ] 시스템 프롬프트에 `submit_final_report` 강제 호출 지시 추가(Step 1 에서는 정의만, 강제는 ConversationCard 와 함께 활성화)
- [ ] `Picky/HUD/Conversation/` 하위 컴포넌트 작성
- [ ] `PickyConversationCardView` 가 `PickySessionCardView` 와 공존
- [ ] `PickySettingsStore`에 `useConversationCard: Bool = false` 플래그 추가
- [ ] `PickyHUDView` 가 플래그에 따라 둘 중 하나 렌더
- [ ] 키보드 핸들링 (steer / followUp / esc)
- [ ] ⋯ 메뉴 구현 + 단축키
- [ ] 활동 strip → terminal overlay 연결
- [ ] 빈 큐 / 빈 message 등 edge case 렌더 검증
- [ ] 테스트: `PickyTests/PickyConversationCardViewTests.swift`, snapshot 4 phase

**검증**: 플래그 ON 으로 새 카드 사용, OFF 로 기존 카드 사용. 사용자가 직접 토글하며 비교 가능.

### Step 3 — 기본 활성화 + 기존 코드 제거
- [ ] `useConversationCard` default → `true`
- [ ] 한 release 사이클 동안 안정성 확인
- [ ] 기존 `PickySessionCardView` 와 관련 helper 모두 삭제
- [ ] `lastSummary` / `thinkingPreview` / `finalAnswer` 등의 직접 사용처가 message builder 외에 없는지 점검
- [ ] AGENTS.md 의 "code navigation index" 업데이트 (삭제된 파일/추가된 디렉터리 반영)

---

## 7. 열린 질문 / 향후 결정

다음은 이 PR 범위 외 열린 항목과, traceability 를 위해 보존하는 결정 완료 항목:

1. **음성 입력 자동 send 정책** — 인식된 텍스트를 자동으로 steer 보낼지, 한 번 더 검토 후 보낼지. 기본값은 검토 후 보내는 쪽으로 시작 권장.
2. **Pi SDK thinking step 카운트 정확도** — Pi SDK가 thinking 단계를 별도 이벤트로 emit하는지 확인. 안 한다면 turn 단위 + heuristic 으로 집계.
3. **Final report 미호출 시 fallback** — Picky가 시작한 에이전트가 `submit_final_report` 없이 종료/실패할 경우 (예: timeout, runtime crash). 현재 fallback은 `agent_text` 마지막 메시지 + status pill 만. pinned 세션은 이 fallback과 동일 처리지만, Picky가 시작한 세션의 fallback에는 "submit_final_report 호출 없이 종료됨" 같은 경고 라벨을 붙일지.
4. **메시지 페이지네이션** — 매우 긴 세션(수백 메시지)의 경우. 1차에선 모두 렌더, 향후 가상 스크롤 또는 "Load earlier" 버튼 검토.
5. **큐 pop 텍스트 복원 여부 ✓ 결정 완료** — §7.13/§7.16 결정으로 `⌥↑` Pop 을 구현하지 않으므로 입력 영역 텍스트 복원 정책도 두지 않는다.
6. **Mode badge 클릭 → settings 안내** — 사용자가 mode tag 클릭 시 "Pi terminal에서 변경하세요" 같은 hint 띄울지.
7. **카드 폭 제약** — `PickyHUDDockLayout.detailWidth = 446` 기준. 메시지 버블 max-width 비율 결정. 위젯 시안은 85% 기준이지만 SwiftUI 환경에서 측정 후 미세 조정.
8. **"by main agent" 라벨 노출 강도** — `originatedBy === "main_agent"` 인 user_text bubble 에 라벨을 항상 노출할지, hover 시에만 노출할지. 항상 노출이 디버깅에 유리하지만 시각 잡음 ↑.
9. **Main-agent steer로 들어온 메시지의 큐 표시** — main agent가 `picky_side_steer` 호출 시 큐에 enqueue 되는지, 즉시 deliver 되는지 확인. 큐 거치면 pending bubble 도 "by main agent" 라벨 필요.
10. **§7.10 Pinned 세션 composer 동작 ✓ 결정 완료 (B)** — `pinSideSession` 은 runtime handle 없이 status=completed 로 카드 생성. 후속 입력은 reattach 방식으로 처리한다. 옵션 히스토리:
    - **Option A** (안전): composer 비활성 + "Pi terminal 에서 이어가기 →" 안내 chip. Pi terminal overlay 열기 only.
    - **Option B** (reattach, 채택): 사용자가 follow-up 입력 시 agentd 가 pi session file 에서 reattach 시도, 성공하면 진짜 실행. 실패 시 user-visible error bubble.
    - 확정 영향: §1.8 의 pinned composer 문구, §3.8 reattach 흐름.
11. **`picky_side_sessions` 응답 필드 확장 시점** — main agent가 카드 신규 정보(messages 요약, finalReport 등)에 접근하면 더 정확한 steering 가능. 1차 미포함 / 2차 검토.
12. **Append-only message journal 영속화 시점** — 1차는 in-memory only + daemon restart 시 logs 기반 best-effort 복원. 긴 세션/재시작 후 메시지 순서 보장을 위해 디스크 journal 을 언제 도입할지 결정 필요.
13. **§7.13 큐 단일 항목 제거의 race 정책 ✓ 결정 완료 (B)** — Pi SDK 가 atomic 단일 제거 API 미제공. 옵션 히스토리:
    - **Option A** (best-effort + UI 피드백): pop/remove 시도, content diff 로 confirm, 실패하면 toast/inline error 노출하고 큐 새로고침
    - **Option B** (기능 미루기, 채택): 단일 제거 UI 제거, `clearQueue()`(전체 비우기) 만 제공
    - **Option C** (Pi SDK 기여): Pi SDK 에 atomic remove API 추가 PR + 머지까지 1차 출시 보류
    - 확정 영향: §1.3, §3.4, Step 1 체크리스트.
14. **§7.14 waiting_for_input 중 외부 steer/follow-up 의 처리 ✓ 결정 완료 (Option 2)** — `pendingExtensionUiRequest` 활성 중 사용자 / main agent 가 steer 보낼 때의 옵션 히스토리:
    1. 기존 question 은 그대로 두고 steer 가 추가로 enqueue?
    2. steer 가 question 을 cancel 하고 새 흐름 시작? (채택)
    3. steer 가 question 의 답변으로 routing? (호환되는 형식일 때만)
    4. waiting 중 steer 자체를 거부하고 user 에게 안내?
    - **현재 구현 상태 (Step 1 완료 시점)**: 결정은 Option 2 (question 자동 cancel) 로 확정됐지만, Step 1 백엔드에서는 미구현 — `cancelExtensionQuestion` 헬퍼만 존재 (dead code). 실제 호출은 Step 2 UI 구현 시 함께 진행.
    - 확정 영향: §1.2 waiting_for_input 행, §1.8, §3.6, Step 2 키 핸들링.
15. **§7.15 submit_final_report lifecycle ✓ 결정 완료 (C)** — 도구 호출은 일반 tool 처럼 turn 안에서 result 가 다시 모델로 들어감. 모델이 도구 호출 후 텍스트 emit / 도구 두 번 호출 / final assistant text 전에 호출할 수 있음. 옵션 히스토리:
    - **Option A** (first-wins): 첫 호출 시 즉시 status=completed 로 patch + agent_report 메시지 추가. 이후 동일 도구 호출은 "already recorded" ack 반환, 메시지 추가 안 함.
    - **Option B** (last-wins): 같은 ID 의 agent_report 를 매 호출마다 replace. status patch 도 매번.
    - **Option C** (turn-end, 채택): 도구 호출 시 report 만 저장, status patch 는 turn 완료 시점에. 도구 후 텍스트는 일반 agent_text 로 함께 표시.
    - 확정 영향: §3.1, §3.5 매핑 표.
16. **§7.16 큐 ID 합성 매핑의 정확도 ✓ 결정 완료 (B)** — Pi SDK 는 큐를 `string[]` 로만 노출하고 enqueue 시점/ID 미제공. supervisor 가 LCS / tail-append 가정으로 stable ID 부여하면 다음 시나리오에서 latest 식별 / 단일 제거가 부정확:
    - 동일 텍스트 중복 enqueue
    - 외부 Pi terminal 에서 enqueue(Picky 모르는 사이)
    - `clearQueue → 재 enqueue` 진행 중 외부 변동
    - steer / followUp 큐 교차 enqueue 의 글로벌 시간순 식별
    - Pi SDK 내부 `_steeringMessages.indexOf(messageText).splice` 동작 검증 결과 — 동일 텍스트 시 첫 일치 항목 제거. 즉 splice 와 매칭 못하면 정확도 보장 X.
    - 옵션 히스토리:
      - **Option A** (제한된 best-effort): 단일 제거 / `⌥↑` pop 을 "Picky-originated + 비중복 + ambiguity 없음" 일 때만 활성화. 그 외엔 chip × 비활성, `⌥↑` no-op + toast.
      - **Option B** (단일 제거 미루기, 채택): UI 에서 단일 × / `⌥↑` 제거. clearQueue(전체 비우기) 만 제공. spec §1.4 의 `⌥↑` 키 매핑도 같이 제거.
      - **Option C** (Pi SDK 기여): atomic remove API + 항목 ID 노출을 Pi SDK 에 PR. 머지 후 진행, 그 전까지 Option B 임시 적용.
    - 확정 영향: §1.3, §1.4, §3.3, §3.4, Step 1 체크리스트.
17. **§7.17 신구 클라이언트 / 데몬 호환 전략 ✓ 결정 완료 (A)** — 현재 `CommandEnvelope` / `EventEnvelope` 가 단일 `protocolVersion: literal(PROTOCOL_VERSION)` 에 묶여 있음. 신규 RPC / 이벤트 추가 시 호환 전략:
    - **Option A** (protocolVersion bump + 차단, 채택): `PROTOCOL_VERSION` 을 `"2026-XX-YY"` 로 올리고, mismatch 시 daemon 거부 + Picky 가 자동 재실행 / 사용자 안내. 기존 daemon binary 와의 host-app 호환성 깨짐.
    - **Option B** (capability hello 필드): protocolVersion 유지. `hello` 이벤트에 `capabilities: z.array(z.string()).optional()` 추가, daemon 이 지원 capability 명단 emit(`["conversationMessages", "queueManagement"]` 등). Swift client 가 capability 검사로 신규 RPC / UI 만 활성화. additive change 라 기존 binary 호환.
    - **Option C** (daemon 측 dual-schema): daemon 이 구버전 command schema 도 병행 지원 + EventEnvelope 도 구버전 emit fallback.
    - 확정 영향: §2.4, §2.5, §6 Step 1, §8.

---

## 8. 테스트 전략

### Unit / 통합
- `session-message-builder.test.ts`: 다양한 입력 조합(과거 logs, pendingExtensionUiRequest, finalReport)에 대해 결정적 출력
- daemon protocol: `protocolVersion` mismatch 시나리오에서 daemon 재실행 트리거 + 사용자 안내 toast 노출 검증
- `session-supervisor.test.ts` 추가 케이스:
  - `clearQueue` 가 kind별로 steering / followUp / all 큐를 비우는지
  - `submit_final_report` 도구 호출 시 finalReport 저장, turn-end 시 status patch
  - `incrementActivity` 가 카테고리별 정확히 누적하는지
- `pi-sdk-runtime.test.ts`: `steeringMode` / `followUpMode` getter 미러링, queue_update 이벤트 forwarding
- queue mode 가 외부 Pi terminal 에서 변경되면 다음 `queue_update` 시 mode 필드 포함 검증
- 메시지 이벤트 reducer: `append → replace ×N → remove`, `remove unknown messageId` no-op, removed 이후 stale replace 무시, rapid thinking flicker(replace ×100) 시 마지막 상태만 반영, `sessionSnapshot` 수신 후 직전 in-flight 이벤트 무시

### Swift
- `PickySessionViewModelTests`: `clearQueue` RPC 호출 → 카드 상태 갱신, 신규 필드 빠진 구버전 `sessionSnapshot` JSON decoding 성공
- `PickyConversationCardViewTests` (신규): 4 phase 스냅샷 + composer `↵` / `⌥↵` / `esc` RPC 발사 + Clear all 버튼 + question cancelled 렌더 + 메뉴 enable/disable + pinned/main_agent 라벨 노출
- `PickyAgentClientTests`: 신규 RPC envelope round-trip + 구버전 server hello 시 protocolVersion mismatch 재실행 처리

### 수동 회귀
- HUD 도크 expand/collapse 동작
- voice steering target 호버 → 카드 mic 표시
- Pi terminal overlay 실행 후 활동 strip 다시 카운트 정확히 갱신
- queue mode 가 Pi terminal에서 변경된 뒤 다음 `queue_update` 시 카드 mode badge 반영

---

## 9. 작업 체크리스트 (요약)

### Step 1 (백엔드)
- [ ] Zod schema 추가 (`PickyQueueMode`, `PickyQueueItem`, `PickyActivitySummary`, `PickyFinalReport`, `PickySessionMessage`)
- [ ] `PickyAgentSession` 필드 확장
- [ ] RPC: `clearQueue`
- [ ] Event: `sessionMessageAppended`, `sessionMessageReplaced`, `sessionMessageRemoved`, `sessionQueueUpdated`, `sessionActivityUpdated`
- [ ] 도구: `submit_final_report` 정의 + 주입(Step 2 에서 시스템 프롬프트 명시)
- [ ] 활동 카운터 + 분류기 (`edit/bash/thinking/other`)
- [ ] RuntimeSessionHandle 확장 + PiSdkRuntimeSession 위임 + MockRuntime 스텁
- [ ] 큐 노출 + mode mirror (`steeringMode/followUpMode`)
- [ ] 큐 조작: 단일 제거 없이 `clearQueue` 만 제공
- [ ] append-only journal + `session-message-builder` 신규 모듈 + 테스트
- [ ] side session followUp/steer 분리 (`session-supervisor.ts:709` 변경)
- [ ] Swift 미러 타입 + `decodeIfPresent` 기반 decoding + protocolVersion mismatch 재실행 처리

### Step 2 (UI, feature flag)
- [ ] `Picky/HUD/Conversation/*` 컴포넌트 작성 (15개 파일 내외)
- [ ] `PickySettingsStore.useConversationCard` 플래그
- [ ] `PickyHUDView` 분기 렌더
- [ ] composer 키 핸들링 (`↵` / `⌥↵` / `esc`)
- [ ] ⋯ 메뉴 (`⌘T` / `⌘R` 단축키, Archive/Copy/Notify는 메뉴 only)
- [ ] 활동 strip → terminal overlay 연결
- [ ] voice 버튼 → push-to-talk 연결
- [ ] PickyTests 스냅샷 4 phase

### Step 3 (정리)
- [ ] 플래그 default ON
- [ ] 기존 `PickySessionCardView` + helper 제거
- [ ] AGENTS.md 인덱스 업데이트

---

## 부록 A. 시안 위젯 참조

본 계획은 다음 시안 위젯을 명세로 삼습니다 (대화 트랜스크립트):

- 대화 v3 final — 4 phase + ⋯ 메뉴
  - Running (큐 채워짐, latest outline, batch wrap)
  - Done (활동 strip + final report, suggested next 없음)
  - Waiting (askUserQuestion 인라인 form)
  - Failed (에러 + 복구 chip, archive 없음)
  - ⋯ 메뉴 (Archive/Copy resume/Notify는 단축키 없음)

> **NOTE**: 시안의 latest outline / chip × / `⌥↑` 마커는 §7.13/§7.16 결정으로 미구현. 시안과 실 구현 차이는 큐 그룹 헤더의 "Clear all" 버튼 추가.

## 부록 B. 의사결정 로그

| 결정 | 근거 |
|---|---|
| 채팅 메타포 채택 | "동료에게 시킨 일" 멘탈 모델과 일치, 큐/스티어/팔로업/thinking이 모두 자연스럽게 풀림 |
| Steering / Follow-up 위치 (Follow-up 위, Steering 아래) | 입력창에 가까울수록 빨리 빠진다는 시간축 통일 |
| 큐 단일 제거 UI = 제거 (B+B 묶음 결정) | `clearQueue`(전체 비우기) 만 제공. `⌥↑`/× 모두 미구현. Pi SDK atomic remove 추가 시 재검토. |
| 모드 변경 UI 미제공 | Pi 책임. Picky는 표시만 |
| `idle` / `next` timing 라벨 제거 | 큐 row 시각 잡음 감소 |
| `activeTool` 표시 제거 | thinking 자체로 충분 |
| `submit_final_report` 도구 강제 (Picky 시작 세션만) | 종료 시점 + 구조화된 결과 보장. pinned 세션은 외부 Pi 작업이라 예외 |
| `suggested_next` 제거 | 사용자 결정 (시안 단계 후) |
| Archive / Copy resume command 단축키 미부여 | 자주 안 쓰고 실수로 누르면 위험 |
| ESC = Stop | composer 비어있을 때만 발동 (텍스트 입력 중엔 무시) |
| 활동 strip 클릭 → Terminal overlay | 자세한 흐름은 터미널이 SoT, 카드는 요약만 |
| user_text bubble 통일 + `originatedBy` 메타 분기 | 사용자 직접 입력과 main agent / Pi extension 입력을 같은 시각 패턴으로 흐르되, 출처가 필요하면 라벨로 구분 |
| 핸드오프 도구(`pi-extensions/picky-handoff`, `application/handoff-tool.ts`) 비변경 | 인터페이스 호환성 유지. 응답 schema 확장만 검토 (2차) |
| 활동 strip 삽입 = Swift 책임 | strip은 message stream이 아니라 `activitySummary` 기반 derived view 로 중복/순서 불일치 방지 |
| 큐 항목 ID 미도입 | 단일 제거 UI를 제거했으므로 Pi SDK `string[]` snapshot 에 supervisor stable ID를 합성하지 않음 |
| 메시지 삭제 = `sessionMessageRemoved` 이벤트 | `agent_thinking` 제거를 append/replace 만으로 표현하지 않기 위함 |
| client/daemon 호환 = A (PROTOCOL_VERSION bump + mismatch 시 daemon 재실행) | `hello.capabilities` 필드 미도입. 신규 envelope 은 새 protocol version 으로만 처리 |
| sessionQueueUpdated 에 mode 필드 optional 포함 | Pi SDK mode 변경 이벤트가 없어 다음 queue_update 시 mode 변경을 함께 전달하기 위함 |
| submit_final_report Step 1 에선 정의만, 강제는 Step 2 | 기존 UI 유지 단계에서 도구 강제 호출로 final 렌더링이 깨지는 회귀 방지 |
| submit_final_report lifecycle = C (turn-end) | 도구 호출 시 report 저장만, status patch 는 turn 완료 시. 한 turn 내 last-wins. |
| 메시지 이벤트에 per-session seq + reducer idempotency 규칙 | rapid thinking replace/remove 및 reconnect stale event 에서 클라이언트 상태 일관성 보장 |
| Pinned 세션 composer 동작 = B (reattach) | `piSessionFilePath` 기반 `runtime.resume()` + 실패 시 error bubble |
| waiting 중 외부 steer = 2 (question 자동 cancel + 새 흐름) | question bubble 은 cancelled 시각 표시 유지 |
| 미결정 항목 해제 | §7.10/§7.13/§7.14/§7.15/§7.16/§7.17 사용자 결정 반영으로 spec lock-in 완료 |
