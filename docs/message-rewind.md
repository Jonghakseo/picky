# Pickle 메시지 되돌리기 (pi `/tree`) 설계

Status: implemented. 이 문서는 초기 설계를 보존하며, 아래 최종 구현 메모가 설계 당시의 파일 기반 저널 재구성 및 미래형 표현보다 우선한다.

Pickle HUD에서 대화를 과거 사용자 메시지 지점으로 되돌리고 그 지점부터 다시 이어가는 기능. pi
에이전트의 `/tree`(트리 인플레이스 분기)를 Picky의 대화 카드 UX로 옮긴 것.

## 최종 구현 메모

- 후보 목록은 런타임 핸들의 `listRewindTargets()`에서 읽고 `rewindTargetsSnapshot` 이벤트로 반환한다.
- `rewindToEntry` 뒤에는 런타임의 `getActiveBranchTranscript()`를 기준으로 `rewindRemovedMessageIds`가 HUD 저널에서 제거할 메시지를 계산한다. `pi-session-syncer.ts` 파일 재독해 경로는 사용하지 않는다.
- agentd는 `removeMessages`를 먼저 실행해 메시지별 `sessionMessageRemoved` 이벤트를 보낸다. 앱은 이 이벤트들로 후행 대화를 제거한다. 그 뒤 `sessionRewound`가 `editorText`와 `removedIds`를 전달하며, 앱은 `editorText`만 사용해 작성창 초안을 복원한다. 초기 시안의 “이전 분기 흐리게/접힘” UI는 구현되지 않았다.
- 최종 구현 진입점은 `agentd/src/application/session-rewind.ts`, `Picky/PickySessionViewModel+Rewind.swift`, `agentd/src/protocol.ts`, `Picky/PickyAgentProtocol.swift`다.

## 확정된 결정

- **UX 경로: A (런타임 기반 피커)** — 대화 메뉴에서 진입하고, Pi 런타임의 `getUserMessagesForForking()`이 반환한 사용자 메시지 목록에서 대상을 선택한다. entryId가 Pi 세션 트리에서 직접 오므로 라이브 HUD 저널과 Pi 엔트리 간 별도 매핑이 필요 없다.
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
이 말풍선 → pi 엔트리 ID" 매핑이 없다. 경로 A는 피커 목록을 **Pi 런타임의 active path에서 직접** 받아 이
제약을 우회한다.

초기 설계는 `pi-session-syncer.ts`의 파일 재독해와 `syncTerminalSession` 재사용을 제안했다. 최종 구현은 런타임 핸들의 active branch transcript를 직접 읽고, 마지막 유지 메시지를 anchor로 HUD 저널의 후행 메시지 ID를 계산한다. Anchor를 찾지 못하면 잘못된 삭제보다 무삭제를 선택한다.

## 데이터 흐름

```
HUD 되돌리기 피커에서 대상 선택 (entryId)
  → rewindSession {sessionId, entryId} 커맨드            (protocol.ts 신규)
  → Supervisor.rewindToEntry                              (session-supervisor.ts)
      · 스트리밍 중이면 abort 먼저, 큐 정리
  → RuntimeSessionHandle.rewindToEntry(entryId)              (pi-sdk-runtime.ts → Pi navigateTree)
  → active branch 대조, 제거할 HUD message ID 계산           (application/session-rewind.ts)
  → removeMessages → sessionMessageRemoved 이벤트들          (HUD 후행 메시지 제거)
  → sessionRewound 이벤트                                    (작성창에 editorText 복원)
```

## 레이어별 변경

### 1. 런타임 어댑터 — `agentd/src/runtime/types.ts`, `pi-sdk-runtime.ts`

`RuntimeSessionHandle`에 추가 (얇은 래퍼, 내부 Pi session이 이미 `sessionManager`/`navigateTree`
노출):

- `listRewindTargets(): RewindTarget[]` → `session.getUserMessagesForForking()` 래핑
- `rewindToEntry(entryId): Promise<{ editorText?; cancelled }>` → `session.navigateTree(entryId)` 호출
  (summarize 미사용)
- `mock-runtime.ts`에 테스트용 인메모리 트리 구현 추가

### 2. 슈퍼바이저 — `agentd/src/session-supervisor.ts`

- `listRewindTargets(sessionId)` — 런타임 핸들의 `listRewindTargets()`에서 후보 목록 반환
- `rewindToEntry(sessionId, entryId)`:
  1. 스트리밍 가드 — `isStreaming`이면 abort 후 settle 대기 (handoff 패턴 재사용)
  2. 대기 중 steering/followUp 큐 정리
  3. `handle.rewindToEntry(entryId)` 호출
  4. `getActiveBranchTranscript()`의 마지막 유지 메시지를 anchor로 `rewindRemovedMessageIds`가 제거할 HUD 저널 message ID를 계산
  5. `messageBuilder.removeMessages`가 message별 `sessionMessageRemoved` 이벤트를 emit
  6. `editorText`와 `removedIds`를 담아 `sessionRewound` 이벤트 emit

### 3. 프로토콜 — `agentd/src/protocol.ts` (비파괴적 추가)

- 커맨드: `listRewindTargets {sessionId}`, `rewindSession {sessionId, entryId}`
- 이벤트: `rewindTargetsSnapshot {sessionId, requestId?, targets[]}`, `sessionRewound {sessionId, editorText?, removedIds[]}`

### 4. 앱/클라이언트 — `Picky/PickyAgentProtocol.swift`, `PickyAgentClient.swift`, `PickySessionViewModel.swift`

- 신규 커맨드/이벤트 인코딩·디코딩
- `sessionMessageRemoved` 수신 시: 해당 후행 말풍선을 HUD 저널에서 제거
- `sessionRewound` 수신 시: `removedIds`는 재삭제에 사용하지 않고 작성창에 `editorText`만 복원

### 5. HUD UI — `Picky/HUD/Conversation/`

- `PickyConversationMenu.swift`에 "메시지 되돌리기…" 항목 추가. pi 세션 파일이 필요하므로
  `canSyncFromPi`와 동일한 게이트를 적용
- 되돌리기 피커 시트 신규 뷰 — 사용자 메시지 목록(텍스트 미리보기 + 상대 시간), 단일 선택, 되돌리기/취소
- 되돌린 후 제거된 후행 메시지를 HUD에서 정리하고 작성창에 복원된 텍스트 표시. 이전 분기 흐리게/접힘 표시는 구현되지 않음

## UI 시안 (3-state)

- **상태 A — 진입점**: 대화 메뉴의 "↩ 메시지 되돌리기…" 항목 (말풍선 호버 `↩`는 경로 B의 후속 UX)
- **상태 B — 피커**: 런타임이 반환한 사용자 메시지 목록에서 단일 선택
- **상태 C — 되돌린 후**: 후행 메시지가 제거되고 작성창에 되돌린 메시지 텍스트가 복원됨. 이전 분기 시각화나 분기 전환 UI는 없음

## 엣지 케이스

- 스트리밍/큐 진행 중 → abort와 settle 대기 후 큐를 비우고 진행
- `piSessionFilePath` 없음 → 대화 메뉴와 `/tree` autocomplete 진입점 비활성화
- rewind 제출 실패 → 피커는 이미 닫힌 상태이며 `PickySessionViewModel+Rewind`가 전역 `lastError`에 오류를 기록
- active branch anchor를 HUD 저널에서 찾지 못함 → 잘못된 삭제 대신 제거 ID 없음
- 후보가 없거나 현재 위치만 있음 → 선택 가능한 되돌리기 대상 없음

## 테스트

- agentd: `runtime/pi-sdk-runtime-rewind.test.ts`(Pi branch transcript 순서/필터링), `session-supervisor-rewind.test.ts`(active branch 대조, message 제거, draft 복원), `protocol.test.ts`(라운드트립)
- Swift: `PickyAgentClientTests`(커맨드/이벤트 codec), `PickySessionViewModelTests`(`sessionMessageRemoved` 후 `sessionRewound` 상태 전이)

## 비목표 (후속)

- 인라인 말풍선 호버 되돌리기(경로 B) — 라이브 저널에 `piEntryId` 태깅 plumbing 선행 필요
- 버려지는 분기 LLM 요약(`summarize`)
- `/tree` TUI 수준의 전체 분기 트리 시각화 및 분기 간 전환
