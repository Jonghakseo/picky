# INPUT: 입력 대상을 지정하고 요청을 전달한다

사용자가 메인 Picky 또는 특정 Pickle을 수신자로 선택하고, 다른 작업을 보거나 입력 중 상태가 바뀌어도 의도한 곳으로 요청을 전달하는 여정이다.

이 문서는 [작성·유지보수 원칙](../README.md)을 적용한 첫 초안이다. 기존 문서·코드·테스트를 대조했으며 실제 앱 시연이나 테스트 실행은 하지 않았다. 모든 시나리오는 현재 `부분 검증` 근거만 연결돼 있고, 이 문서를 위한 UI E2E는 아직 없다. `근거 일치`와 `구현 관찰`은 계약의 근거 상태이지 실행 결과가 아니다.

## 범위와 용어

- Mac의 Pickle 대상 지정·해제, 전역 Push-to-Talk(PTT), Quick Input, 전달 중 취소와 실패 후 재시도를 다룬다.
- **메인**은 Picky의 메인 대화다. 명시적으로 지정한 Pickle이 없으면 전역 입력은 메인으로 간다.
- **한 번 지정**은 다음 화면 맥락 입력을 해당 Pickle로 보내는 지정이다. **고정**은 여러 입력에 같은 Pickle을 사용하는 지정이다.
- **입력별 수신자**는 해당 입력을 시작할 때 확보한 대상이다. 사용자가 나중에 지정한 다음 입력의 대상과 다를 수 있다.
- Pickle 카드에서 직접 입력하는 composer는 경계 확인만 포함한다. composer 마이크는 전사 내용을 초안에 넣는 별도 입력이며 전역 PTT와 같지 않다.
- 메인의 Task/Pickle 선택, PWA·CLI, 음성 인식 품질, 실제 권한 승인, 재시작 후 복구, 응답의 어노테이션 품질은 별도 여정으로 남긴다.

## 정상 사용법

자세한 조작법은 [사용자 매뉴얼][manual]의 4.2, 4.3, 5, 14.4절을 따른다.

1. 추가 지시를 받을 Pickle A를 연다.
2. 헤더 배지를 누르거나 `Cmd + K`, Dock 메뉴로 다음 입력의 대상을 지정한다. 연속해서 보내려면 배지를 길게 누르거나 Dock 메뉴에서 입력 대상을 고정한다.
3. PTT를 누르고 말하거나 Quick Input을 연다. Quick Input에서는 A의 이름이 보이고 메인 대화 이력은 숨겨진다.
4. 음성을 마친 뒤 PTT를 놓거나, Quick Input에서 요청을 작성해 전송한다.
5. 기본 전달 방식은 Follow-up이다. 실행 중인 A에는 후속 입력으로 들어간다. 설정을 Steer로 바꾸면 현재 실행에 방향을 바꾸는 입력으로 전달한다.
6. A의 대기 입력 또는 대화에서 요청을 확인한다. 메인이나 Pickle B에 잘못 추가되지 않아야 한다.
7. 한 번 지정은 전달 후 해제되고, 고정은 다음 입력에도 유지된다. 고정 해제 또는 다른 Pickle 지정은 명시적으로 한다.

7번의 "전달 후"는 현재 앱의 로컬 전송 완료 처리와 데몬의 실제 접수가 같다는 뜻이 아니다. 성공 판정 차이는 아래 `INPUT-D02`에 기록한다.

## 대상이 결정되는 시점

| 입력 경로 | 수신자가 결정되는 시점 | 함께 고정되는 정보 | 근거 |
| --- | --- | --- | --- |
| 전역 PTT | PTT를 누를 때 | Pickle ID, 한 번 지정/고정, 지정 세대, Follow-up/Steer | [음성 대상 정책][voice-target], [CompanionManager][companion]의 `handleShortcutTransition` |
| Quick Input | 입력창의 새 표시를 시작할 때 | 메인 또는 Pickle ID와 표시 이름 | [입력창 모델][quick-view]의 `beginPresentation`, [패널 관리자][quick-panel] |
| Quick Input 실패 복원 | 실패한 입력창의 수신자를 다시 사용 | 초안과 수신자, 전송 때 보관한 잉크 | [패널 관리자][quick-panel]의 `panelDidFinishSending`, [CompanionManager][companion]의 `handleQuickInputSubmit` |
| Pickle composer | 해당 카드의 명시적 세션으로 전송 | 화면 맥락 대상 지정과는 별개 | [세션 ViewModel 테스트][session-tests]의 composer 경계 검사 |

Quick Input의 전달 방식은 전송 시 설정을 읽는다. PTT처럼 지정 세대와 전달 방식을 입력창에 함께 고정하는 것은 아니다. 두 입력 경로를 하나의 snapshot 계약으로 단정하지 않는다.

## 공통 준비와 판정 기준

향후 실행할 때는 격리된 앱·데몬과 임시 저장소를 사용한다. 서로 다른 이름의 Pickle A/B, 메인 대화, 고유한 요청 문구를 준비한다. 정상 흐름은 입력 가능한 완료 상태 또는 실행 중 상태에서 시작한다. 실패·취소·보관 상태의 입력 허용 정책을 정상 흐름과 섞지 않는다.

각 전달 시나리오는 다음을 끝까지 확인해야 한다.

1. 화면에 보인 수신자와 실제로 요청을 받은 세션이 일치한다.
2. 올바른 세션의 대기 입력/대화와 저장 결과에 해당 요청이 있고, 다른 세션에는 없다.
3. 대상 지정, 초안, 오류 표시가 다음 입력을 잘못 유도하지 않는다.
4. 취소된 입력이나 이전 입력의 늦은 완료가 새 전송을 만들거나 새 지정을 지우지 않는다.

앱의 `send` 성공이나 Follow-up/Steer 명령 기록만으로 2번을 통과 처리하지 않는다. [서버][server]의 명령 접수, [SessionSupervisor][supervisor]의 `followUp`/`steer`, 세션 저장과 v2 projection, 최종 카드 표시를 연결해야 한다. 메인 경로는 [MainAgentCoordinator][main-coordinator]와 메인 대화 표시를 연결한다. 기존 테스트 중 어디까지 통과시키는지는 아래에 따로 적는다.

## 시나리오

### INPUT-001: 지정하지 않은 전역 입력은 메인으로 간다

- **조건·행동:** 대상을 지정하지 않은 상태에서 A 카드를 열거나 그 위에 포인터를 놓는다. PTT 또는 Quick Input으로 요청한다.
- **기대 결과:** 요청은 메인 대화로 간다. 열린 카드, 선택된 카드, hover만으로 A가 수신자가 되지 않는다.
- **우선순위·계약:** P0, 근거 일치. 매뉴얼 4.2와 5절.
- **기존 검증:** [Companion 테스트][companion-tests]의 `pttWithoutArmedTargetSubmitsToMainAgent`, [수신자 정책 테스트][recipient-tests]의 `resolvesMissingOrBlankTargetToMainRecipient`.
- **남은 검증:** 실제 포인터·키 입력에서 시작해 메인 대화에 저장·표시되고 A/B에는 추가되지 않는지 확인한다.

### INPUT-002: 한 번 지정한 Pickle로 요청을 보낸다

- **조건·행동:** A를 한 번 지정하고 PTT 또는 Quick Input으로 요청한다. 기본 Follow-up과 설정된 Steer를 각각 확인한다.
- **기대 결과:** 요청과 허용된 화면 맥락은 A로 전달된다. Follow-up은 후속 입력, Steer는 실행 방향 변경 입력으로 처리된다. 로컬 전달 처리가 끝나면 한 번 지정이 해제된다. 메인/B에는 보내지 않는다.
- **우선순위·계약:** P0, 근거 일치. 매뉴얼 4.3절. 실제 접수 성공 기준은 INPUT-D02와 함께 본다.
- **기존 검증:** [Companion 테스트][companion-tests]의 `productionPTTWithScreenContextTargetSendsFollowUpWhenConfigured`, `productionPTTWithScreenContextTargetSendsSteerWhenConfigured`, `quickInputWithScreenContextTargetSendsFollowUpWithContextAndClearsTargetByDefault`, `quickInputWithScreenContextTargetSendsSteerWhenConfigured`.
- **남은 검증:** 실제 UI로 지정하고 전송한 뒤, 데몬의 대기 입력·처리 결과와 카드의 지정 해제까지 확인한다. 명령 종류만 맞는 것으로 끝내지 않는다.

### INPUT-003: 고정한 대상은 연속 입력에 유지된다

- **조건·행동:** A를 고정하고 요청을 두 번 보낸다. 이후 고정을 해제하거나 B를 새 대상으로 지정하고 새 입력을 시작한다.
- **기대 결과:** 처음 두 요청은 A로 간다. 해제 후 새 전역 입력은 메인으로, B 지정 후 새 입력은 B로 간다. A 고정이 화면에서만 사라지고 실제 전달에 남지 않는다.
- **우선순위·계약:** P1, 근거 일치. 매뉴얼 4.3, 14.4절. 실패 시 고정 유지 여부는 INPUT-D01로 분리한다.
- **기존 검증:** [Companion 테스트][companion-tests]의 `quickInputWithStickyScreenContextTargetKeepsTargetArmedAfterFollowUp`, [세션 ViewModel 테스트][session-tests]의 `toggleStickyScreenContextTargetClearsCurrentStickyTarget`, `armingAnotherPickleReplacesStickyTarget`, [대상 컨트롤러 테스트][target-tests]의 `sessionIDDisarmKeepsAStickyTargetArmed`.
- **남은 검증:** 여러 차례 실제 전달, 대상 표시, 고정 해제 후 전달 결과를 하나의 사용자 흐름으로 연결한다.

### INPUT-004: 음성 입력 도중 대상이 바뀌어도 진행 중인 입력은 바뀌지 않는다

- **조건·행동:** A를 지정한 채 PTT를 누른다. 전사 또는 맥락 캡처가 끝나기 전에 B를 다음 입력 대상으로 지정한다.
- **기대 결과:** 진행 중인 음성 입력은 시작할 때의 A와 전달 방식을 사용한다. A 입력의 완료가 새로 지정한 B를 해제하지 않는다.
- **우선순위·계약:** P0, 구현 관찰. [음성 대상 정책][voice-target]과 [CompanionManager][companion]의 입력별 snapshot 경로.
- **기존 검증:** [음성 대상 테스트][voice-target-tests]의 `armedTargetSnapshotsDispatchSemantics`, [대상 컨트롤러 테스트][target-tests]의 `sessionIDDisarmIgnoresAnotherSession`. 실제 A→B 전환 전체를 검증하는 근거는 아직 연결하지 않았다.
- **남은 검증:** 실제 PTT 시작부터 A/B 변경, 전사 완료, A에 저장·표시, B 지정 유지까지 연결한다. 정책 테스트를 이 흐름의 통과로 세지 않는다.

### INPUT-005: Quick Input은 입력창에서 확인한 수신자로 보낸다

- **조건·행동:** A를 대상으로 Quick Input을 연다. 전송 전 또는 캡처 중에 전역 대상을 B로 바꾼 뒤 요청을 보낸다.
- **기대 결과:** 요청은 입력창이 보관한 A로 간다. 반대로 메인 수신자로 연 입력창도 나중에 A를 지정했다는 이유만으로 A에 보내지 않는다. 입력창을 닫고 새로 열면 현재 대상을 사용한다.
- **우선순위·계약:** P0, 근거 일치. 매뉴얼 5절.
- **기존 검증:** [입력창 테스트][quick-tests]의 `submitDeliversTheRecipientCapturedForThisPresentation`, [Companion 테스트][companion-tests]의 `quickInputRecipientSnapshotSendsToOriginalPickleAfterTargetChanges`.
- **남은 검증:** 화면 수신자 표시, 새로 열기, 실제 데몬 수신·저장을 연결한다. 같은 A를 다시 지정한 경우는 INPUT-D03으로 분리한다.

### INPUT-006: Quick Input 전달 실패 후 같은 초안과 수신자로 재시도한다

- **조건·행동:** A 수신자로 텍스트와 잉크를 준비하고 접수 전 확정 실패를 일으킨다. 복원된 입력창에서 내용을 수정하거나 잉크를 추가해 재시도한다.
- **기대 결과:** 오류와 함께 초안·수신자·잉크가 복원된다. 재시도도 A로 간다. 입력창을 닫고 새로 열 때는 현재 대상을 사용하며 이전 실패의 A를 몰래 재사용하지 않는다.
- **우선순위·계약:** P0, 근거 일치. 매뉴얼 5절. 대상 배지의 유지 여부는 INPUT-D01, 접수 여부가 불명확한 실패는 INPUT-D02에 남긴다.
- **기존 검증:** [입력창 테스트][quick-tests]의 `failedSendRestoresPickleRecipientUntilAnExplicitMainPresentation`, [Companion 테스트][companion-tests]의 `failedQuickInputRestartsTextInkWithSubmittedCaptureAndRetryUsesCombinedStrokes`.
- **남은 검증:** 오류와 복원된 화면을 실제 입력으로 확인하고, 재시도 결과가 A의 저장·대화에 나타나는지 확인한다.

### INPUT-007: Quick Input 캡처 중 취소하면 뒤늦게 전달하지 않는다

- **조건·행동:** A 대상 Quick Input의 맥락 캡처를 지연시킨다. 사용자가 전송을 취소한 뒤 캡처를 완료시킨다.
- **기대 결과:** 취소된 입력의 Follow-up/Steer가 새로 발송되지 않는다. 메인이나 다른 Pickle로 우회하지 않는다.
- **우선순위·계약:** P0, 근거 일치. 매뉴얼 5절의 전달 중 취소 계약.
- **기존 검증:** [Companion 테스트][companion-tests]의 `cancelDuringArmedPickleCapturePreventsLateFollowUpDispatch`.
- **남은 검증:** 실제 취소 조작과 화면 복귀, 데몬에 요청이 저장되지 않음을 확인한다. 이미 접수한 요청의 취소는 이 시나리오와 같지 않다.

### INPUT-008: Quick Input에서 전달을 마친 Pickle은 메인 중단과 독립적이다

- **조건·행동:** A로 Quick Input 전달을 마친 뒤 메인 Stop, 메인의 Escape 두 번 누르기 또는 새 PTT를 사용한다. A의 작업 완료 이벤트를 보낸다.
- **기대 결과:** 전달된 A 작업은 메인 취소로 중단되지 않는다. A가 완료되면 저장된 projection과 카드 모두 완료를 표시한다. A를 중단하려면 A의 Stop을 사용한다.
- **우선순위·계약:** P0, 근거 일치. 매뉴얼 5절. PTT의 진행 중 응답 취소에는 그대로 일반화하지 않는다(INPUT-D04).
- **기존 검증:** [Companion 테스트][companion-tests]의 `deliveredQuickInputSurvivesMainTurnCancellation`, `deliveredQuickInputSurvivesNextPushToTalkPress`, `handedOffPickleCompletesThroughV2AfterGlobalEscape`.
- **검증 범위·남은 부분:** 마지막 테스트는 실제 router/v2 적용을 거쳐 projection 저장과 카드 모델까지 확인한다. 외부 client는 fake이고 실물 키 입력·화면·데몬 디스크 저장까지 증명하지는 않는다.

### INPUT-009: 음성 대상이 사라지면 메인으로 바꿔 보내지 않는다

- **조건·행동:** A를 지정해 PTT를 시작한 뒤, 전사가 끝나기 전에 A 제거가 확인된 v2 bootstrap 완료 이벤트를 받는다. 늦은 전사·캡처 결과를 도착시킨다.
- **기대 결과:** 진행 중 입력을 무효화하고 대상이 사라졌음을 알린다. A/B 또는 메인으로 뒤늦게 보내지 않는다. 무관한 세션 제거와 중복 제거 이벤트는 현재 입력을 무효화하지 않는다.
- **우선순위·계약:** P0, 구현 관찰. [이벤트 생명주기][agent-events]의 `applyAgentClientEvent`, `invalidateVoiceTargets`.
- **기존 검증:** [Companion 테스트][companion-tests]의 `projectionBootstrapEventInvalidatesCapturedPTTTargetWithoutRoutingTranscriptToMain`, `unrelatedAndDuplicateProjectionRemovalPreserveCapturedPTTTarget`.
- **남은 검증:** 실제 projection 전달·복구 경로와 오류 표시를 연결한다. 단순한 통신 지연이나 임시 빈 목록을 세션 제거와 동일하게 취급하지 않는다. Quick Input의 대상 제거 시점별 동작은 별도 확인이 필요하다.

### INPUT-010: 이전 음성 입력의 완료가 새 지정을 지우지 않는다

- **조건·행동:** A를 한 번 지정해 음성 입력을 시작한다. 전달 또는 실패 처리가 끝나기 전에 지정을 해제하고 같은 A를 다시 지정한다. 이전 입력의 완료나 전사 오류를 도착시킨다.
- **기대 결과:** 새 A 지정은 유지된다. 세션 ID가 같아도 이전 입력이 새 입력의 지정을 소비하지 않는다.
- **우선순위·계약:** P0, 구현 관찰. [대상 컨트롤러][target-controller]의 snapshot 기반 해제와 지정 세대 비교.
- **기존 검증:** [Companion 테스트][companion-tests]의 `rearmingSamePickleDuringVoiceTurnPreservesNewerTargetRevision`, `dictationErrorDoesNotClearSamePickleRearmedAtNewerRevision`.
- **남은 검증:** 실제 배지·단축키 재지정과 늦은 완료 후 표시를 연결한다. Quick Input에도 같은 세대 보호가 있다고 가정하지 않는다(INPUT-D03).

### INPUT-011: 카드에서 직접 보내는 입력은 전역 화면 맥락 지정을 소비하지 않는다

- **조건·행동:** A를 화면 맥락 대상으로 지정한 상태에서 카드 composer로 일반 Follow-up 또는 Steer를 보낸다.
- **기대 결과:** 해당 카드의 명시적 세션으로 전달한다. 전역 대상 지정만을 이유로 화면 맥락을 자동 첨부하거나 지정을 해제하지 않는다.
- **우선순위·계약:** P1, 구현 관찰. 전역 입력과 카드 입력의 경계다.
- **기존 검증:** [세션 ViewModel 테스트][session-tests]의 `screenContextTargetDoesNotAttachToComposerFollowUp`, `screenContextTargetDoesNotAttachToComposerSteer`.
- **남은 검증:** 실제 composer 입력과 지정 표시 유지, 첨부 없는 요청의 데몬 저장을 연결한다. composer 마이크 전사의 검증은 별도다.

## 아직 결정하거나 확인할 사항

### INPUT-D01: 실패 시 대상 지정은 언제 유지해야 하는가

현재 구현은 실패 종류에 따라 다르다.

- Quick Input의 캡처·전송 실패는 한 번 지정을 해제하지만 고정은 유지한다. 복원된 입력창의 수신자는 전역 지정과 별도로 보존한다.
- PTT의 전사 시작/전사 실패 경로는 해당 입력의 한 번 지정과 고정을 모두 해제할 수 있다. 이전 지정 세대의 실패는 새 지정을 해제하지 않는다.
- PTT의 캡처·전송 실패는 해당 한 번 지정을 해제하고 고정은 유지한다. discarded 입력은 지정을 유지한다.

근거는 [CompanionManager][companion]의 `handleDictationSessionEvent`, `sendPickleMessageFromInput`, `handleVoiceSubmissionFailure`와 [음성 캡처 effect][voice-capture]다. 이 차이를 사용자에게 보장할지, 실패 복구 규칙을 통일할지 결정해야 한다. 지금은 서로 같은 실패 정책으로 문서화하거나 코드를 변경하지 않는다.

### INPUT-D02: 무엇을 전달 성공으로 볼 것인가

Quick Input은 `sendAwaitingError`로 명령 확인 또는 오류를 기다리지만, 1초 동안 오류가 없으면 호환성상 성공으로 처리한다. PTT의 지정 대상 전달은 `agentClient.send`가 반환하면 앱 내부 접수 처리를 한다. 둘 다 해당 요청이 데몬에 저장되고 화면에 표시됐다는 직접 증거는 아니다.

앱의 성공 표시 기준을 어디까지 강화할지, 접수 확인이 유실된 입력을 재시도할 때 중복을 어떻게 방지할지 정해야 한다. 그전에도 E2E 판정은 실제 수신 세션·저장·화면까지 확인한다. 침묵을 영속 저장 성공으로 가정하거나, 무조건 재시도하는 계약을 추가하지 않는다.

### INPUT-D03: Quick Input의 고정 범위도 PTT와 같아야 하는가

Quick Input은 수신자 ID와 이름을 고정하지만 전달 방식은 전송 시 읽고, 지정 해제는 세션 ID를 기준으로 한다. PTT는 전달 방식과 지정 세대까지 보관한다.

입력창을 열어둔 사이 Follow-up/Steer를 바꾸거나 같은 A를 해제 후 다시 지정했을 때, 어느 시점의 의도를 따라야 하는지 확인해야 한다. INPUT-005의 A→B 테스트로 같은 A 재지정까지 검증했다고 주장하지 않는다.

### INPUT-D04: PTT 응답 중단도 Quick Input 전달 완료와 독립적인가

Quick Input 완료 후 작업 독립성은 매뉴얼과 INPUT-008의 기존 테스트에 명시돼 있다. 반면 [Companion 테스트][companion-tests]의 `voiceInputAbortAlsoAbortsInFlightPickleFollowUpTarget`은 진행 중 음성 응답 대상에 세션 abort를 보내는 경로를 검사한다.

이 테스트는 이전 음성 입력이 대기 중인 상태를 구성한 부분 검증이다. 실제 PTT의 접수·응답 단계별로 중단 범위를 확인하고, Quick Input과 의도적으로 달라야 하는지 정해야 한다. 현재 근거만으로 모든 전역 입력이 전달 직후 메인 취소와 독립적이라고 선언하지 않는다.

## 시각·상호작용 관찰 지점

다음은 자동화 전 시각 검사 후보이며, 기준 이미지나 애니메이션 통과 증거가 아니다.

| 연결 시나리오 | 확인할 장면·전환 | 필요한 증거 |
| --- | --- | --- |
| INPUT-001, 002, 005 | 메인/A/B 수신자 표시, 긴 Pickle 이름, Pickle 수신자에서 메인 이력 숨김 | 결정적인 정적 렌더 + 실제 수신 결과 |
| INPUT-003, 010 | 한 번 지정/고정/해제와 늦은 완료 후 배지 표시 | 실제 이벤트를 거친 화면 전환 |
| INPUT-006 | 실패 후 같은 초안·수신자·잉크 복원, 재시도 중 레이아웃 | 실패 전후 이미지, 포커스·입력 확인, 전환 중 프레임 |
| INPUT-007, 008 | 전달 중 취소와 전달 완료 후 Stop의 다른 범위 | 실제 조작, 명령·저장·상태 기록 |

light/dark, 좁은 폭, 긴 이름은 표시 위험이 있는 장면에만 적용한다. 위치 점프·깜빡임의 허용 기준은 실제 전환을 조사한 뒤 정하고, 임의의 픽셀·시간 상수를 제품 계약으로 만들지 않는다. WindowServer 검증은 [격리 규칙](../../docs/test-desktop-isolation.md)을 따른다.

[manual]: ../../docs/user-manual.md
[companion]: ../../Picky/Companion/CompanionManager.swift
[voice-target]: ../../Picky/Companion/PickyVoiceInputTarget.swift
[target-controller]: ../../Picky/Sessions/PickyScreenContextTargetController.swift
[quick-view]: ../../Picky/QuickInput/QuickInputPanelView.swift
[quick-panel]: ../../Picky/QuickInput/QuickInputPanelManager.swift
[voice-capture]: ../../Picky/Companion/CompanionManager+VoiceContextCaptureEffect.swift
[agent-events]: ../../Picky/Companion/CompanionManager+AgentEventLifecycle.swift
[server]: ../../agentd/src/server.ts
[supervisor]: ../../agentd/src/session-supervisor.ts
[main-coordinator]: ../../agentd/src/application/main-agent-coordinator.ts
[companion-tests]: ../../PickyTests/PickyCompanionManagerTests.swift
[session-tests]: ../../PickyTests/PickySessionViewModelTests.swift
[quick-tests]: ../../PickyTests/QuickInputPanelViewModelTests.swift
[recipient-tests]: ../../PickyTests/PickyQuickInputRecipientPolicyTests.swift
[voice-target-tests]: ../../PickyTests/PickyVoiceInputTargetTests.swift
[target-tests]: ../../PickyTests/PickyScreenContextTargetControllerTests.swift
