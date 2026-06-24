# Pickle 메시지 되돌리기 (pi `/tree`) 설계

Pickle HUD에서 대화를 과거 사용자 메시지 지점으로 되돌리고 그 지점부터 다시 이어가는 기능. pi
에이전트의 `/tree`(트리 인플레이스 분기)를 Picky의 대화 카드 UX로 옮긴 것.

## 확정된 결정

- **UX 경로: A (파일 기반 피커)** — 대화 메뉴에서 진입, pi 세션 파일의 사용자 메시지 목록에서 대상을
  선택. entryId가 pi 파일에서 직접 오므로 100% 정확하고 라이브 저널 ↔ pi 엔트리 매핑 plumbing이 불필요.
- **분기 요약 제외** — `navigateTree`의 `summarize` 옵션(버려지는 분기를 LLM으로 요약)은 v1에서 사용
  하지 않는다. 단순 되돌리기만 제공.
- 인라인 말풍선 호버 되돌리기(경로 B)는 비목표. entryId 태깅이 준비되면 후속으로 검토.

## 동작 원리

pi 세션은 단일 `.jsonl` 안에서 `id`/`parentId`로 연결된 트리다. `/tree`는 새 파일을 만들지 않고 트리
안에서 leaf(현재 위치)를 과거 노드로 이동시키는 인플레이스 분기다. 기존 분기는 파일에 보존된다.

SDK가 필요한 고수준 API를 이미 노출한다
(`agentd/node_modules/@earendil-works/pi-coding-agent/dist/core/agent-session.d.ts`):

- `session.sessionManager` — `getEntries()`, `getTree()`, `branch(id)` 등 트리 접근
- `session.navigateTree(targetId, opts)` — `/tree`의 실제 동작. 되돌린 사용자 메시지 텍스트를
  `editorText`로 반환. v1은 `opts.summarize`를 넘기지 않는다.
- `session.getUserMessagesForForking()` → `[{ entryId, text }]` — 되돌리기 후보 목록

## 핵심 제약: 라이브 저널에 pi 엔트리 ID가 없음

라이브 `RuntimeEvent`(`agentd/src/runtime/types.ts:35`)는 pi 엔트리 ID를 싣지 않고, HUD 저널
메시지(`agentd/src/session-message-builder.ts`)는 `msg-command-<uuid>` 같은 자체 ID를 쓴다. 즉 "화면의
이 말풍선 → pi 엔트리 ID" 매핑이 없다. 경로 A는 피커 목록을 **pi 파일 active path에서 직접** 만들어 이
제약을 우회한다.

`agentd/src/application/pi-session-syncer.ts`의 `readPiTerminalSessionMessages`가 이미 pi 파일의 active
path를 읽어 `getUserMessagesForForking`과 동일한 정보를 추출하고,
`syncTerminalSession`(`agentd/src/session-supervisor.ts:2160`)이 텍스트+순서 매칭으로 저널을 재구성하는
검증된 메커니즘이 있다. 되돌리기 후 저널 재구성은 이 코드를 재사용한다.

## 데이터 흐름

```
HUD 되돌리기 피커에서 대상 선택 (entryId)
  → rewindSession {sessionId, entryId} 커맨드            (protocol.ts 신규)
  → Supervisor.rewindToEntry                              (session-supervisor.ts)
      · 스트리밍 중이면 abort 먼저, 큐 정리
  → runtime.navigateTree(entryId) → sessionManager.branch (pi-sdk-runtime.ts 래퍼 / pi SDK)
  → 저널 재구성 + editorText 복원                          (pi-session-syncer.ts, emitRemoved)
  → sessionRewound 이벤트 → HUD 갱신                       (PickySessionViewModel)
      · 이전 분기 보관(흐리게/접힘), 작성창에 editorText 채움
```

## 레이어별 변경

### 1. 런타임 어댑터 — `agentd/src/runtime/types.ts`, `pi-sdk-runtime.ts`

`RuntimeSessionHandle`에 추가 (얇은 래퍼, `this.runtime.session`이 이미 `sessionManager`/`navigateTree`
노출):

- `listRewindTargets(): RewindTarget[]` → `session.getUserMessagesForForking()` 래핑
- `navigateTree(entryId): Promise<{ editorText?; cancelled }>` → `session.navigateTree(entryId)` 호출
  (summarize 미사용)
- `mock-runtime.ts`에 테스트용 인메모리 트리 구현 추가

### 2. 슈퍼바이저 — `agentd/src/session-supervisor.ts`

- `listRewindTargets(sessionId)` — pi 파일 또는 핸들에서 후보 목록 반환
- `rewindToEntry(sessionId, entryId)`:
  1. 스트리밍 가드 — `isStreaming`이면 abort 후 settle 대기 (handoff 패턴 재사용)
  2. 대기 중 steering/followUp 큐 정리
  3. `handle.navigateTree(entryId)` 호출
  4. 저널 재구성 — `readPiTerminalSessionMessages`로 새 active path를 읽어 되돌림 지점 이후 저널
     메시지를 `emitRemoved`로 제거 (`syncTerminalSession`의 텍스트+순서 매칭 로직 재사용)
  5. `editorText`를 담아 `sessionRewound` 이벤트 emit

### 3. 프로토콜 — `agentd/src/protocol.ts` (비파괴적 추가)

- 커맨드: `listRewindTargets {sessionId}`, `rewindSession {sessionId, entryId}`
- 이벤트: `rewindTargets {sessionId, targets[]}`, `sessionRewound {sessionId, editorText?, removedIds[]}`

### 4. 앱/클라이언트 — `Picky/PickyAgentProtocol.swift`, `PickyAgentClient.swift`, `PickySessionViewModel.swift`

- 신규 커맨드/이벤트 인코딩·디코딩
- `sessionRewound` 수신 시: 후행 말풍선 로컬 정리 + 작성창에 `editorText` 채움 + 분기 표시 갱신

### 5. HUD UI — `Picky/HUD/Conversation/`

- `PickyConversationMenu.swift`에 "메시지 되돌리기…" 항목 추가. pi 세션 파일이 필요하므로
  `canSyncFromPi`와 동일한 게이트를 적용
- 되돌리기 피커 시트 신규 뷰 — 사용자 메시지 목록(텍스트 미리보기 + 상대 시간), 단일 선택, 되돌리기/취소
- 되돌린 후 이전 분기를 흐리게/접힘 처리, 작성창에 복원된 텍스트 표시

## UI 시안 (3-state)

- **상태 A — 진입점**: 대화 메뉴의 "↩ 메시지 되돌리기…" 항목 (말풍선 호버 `↩`는 경로 B의 후속 UX)
- **상태 B — 피커**: pi 파일의 사용자 메시지 목록에서 단일 선택. "이후 대화는 분기로 보관" 안내
- **상태 C — 되돌린 후**: 이전 분기는 보관·흐리게, 작성창에 되돌린 메시지 텍스트 복원, "전송" / "이전
  분기로 되돌아가기"

## 엣지 케이스

- 스트리밍/큐 진행 중 → abort + 큐 정리 후 진행 (확인 다이얼로그)
- 터미널 오버레이 열린 상태 → `invalidateRuntimeHandleAfterTerminalSync` 재사용해 충돌 방지
- mock 런타임 / 세션 파일 없음 → 메뉴 비활성화
- compaction 엔트리가 경로에 있어도 `buildSessionContext`가 처리하므로 안전
- 후보가 1개(첫 메시지)뿐이면 되돌릴 의미가 없으므로 비활성 처리

## 테스트

- agentd: `pi-sdk-runtime.test.ts`(navigateTree 래퍼), `session-supervisor.test.ts`(저널 재구성/제거),
  `protocol.test.ts`(라운드트립)
- Swift: `PickySessionViewModelTests`(rewound 상태 전이)

## 비목표 (후속)

- 인라인 말풍선 호버 되돌리기(경로 B) — 라이브 저널에 `piEntryId` 태깅 plumbing 선행 필요
- 버려지는 분기 LLM 요약(`summarize`)
- `/tree` TUI 수준의 전체 분기 트리 시각화 및 분기 간 전환
