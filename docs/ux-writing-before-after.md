# UX writing 점검과 수정

2026-09-25 · Picky · 한국어·영어

---

기존 번역 목록 **1,350개**를 검수하고 화면에 직접 적힌 문구를 함께 확인했다. 최종 변경은 기존 키 **408개**, 신규 키 **228개**다. 아래 표는 최종 저장된 번역과 변경 전 원본을 비교해 생성했다. 한국어 앱에서 영어로만 보이던 문구도 포함한다.

## 검수 기준과 범위

- 사용자가 지금 알아야 할 상태, 다음 행동, 전송·삭제 범위를 먼저 알린다.
- Pickle은 제품 이름으로 유지한다. 일반 안내의 세션·런타임·TUI는 대화·작업·터미널로 바꾸되, API·경로·Git·모델 설정의 기술 용어는 유지한다.
- 도크, 대화, 질문, 입력창, 작업 상태, 설정, 권한, 로그인, 온보딩, Hub, 예약, 통계, 플러그인, 피드백, 터미널, 네이티브 메뉴와 접근성 문구를 점검했다.
- 외부 AI·도구가 작성한 내용, 원시 오류 상세, 로그·명령어·모델명은 임의로 번역하지 않았다. 별도 프로세스인 watchdog 진단 경고와 시스템 소유 화면의 전체 현지화는 이번 변경에 포함하지 않았다.

## 교차검증 반영

수정 후보를 challenger 3명이 병렬 검토했다. 대화 후보 163개, 설정·Hub 후보 240개, 신규 문구 후보 217개와 코드 diff를 나눠 확인했다. 다음 지적은 최종 문구 또는 표시 조건에 반영했다.

| 항목 | 검증에서 발견한 문제 | 반영 내용 |
|---|---|---|
| 화면 전송 | 표시가 없어도 직접 포함한 화면은 전송될 수 있음 | 자동 전송 제한과 직접 포함 예외를 함께 설명 |
| 통계 초기화 | 분류 기능이 켜져 있으면 기존 작업도 다시 분류됨 | 분류 결과만 삭제되며 재분류될 수 있음을 명시 |
| 입력 대상 | 다른 카드를 여는 것만으로 고정 대상이 바뀌지 않음 | 입력 대상 배지를 클릭하라고 안내 |
| 보관 삭제 | 진행 중인 보관 작업은 서버에서 삭제를 거부함 | 삭제 가능한 상태로 제한하고 진행 중인 작업은 유지 |
| 작업 중단 | 텍스트는 입력란으로 복원되지만 화면 첨부는 복원 불가 | 중단 메뉴와 버튼 도움말에 차이 명시 |
| 오류 복구 | 재전송과 이어가기가 같은 버튼 문구를 사용 | 미전달 경합 오류는 다시 시도, 나머지는 이어가기 |
| 권한 요청 | 브라우저 권한 버튼은 시스템 설정을 열지 않음 | 앱 내 접근 요청에 맞춰 버튼과 설명 분리 |
| 플러그인 제거 | 설치됨 버튼이 제거 확인창을 열었음 | 기본 버튼에도 제거 행동을 표시 |
| 첨부 오류 | 최대 크기 포함 여부와 추가 전 총량이 부정확 | 이하 경계값 및 추가했을 때의 합계로 수정 |
| 터미널 | 닫을 때 동기화 성공을 보장할 수 없음 | 동기화를 시도한다고 안내하고 실패시 복구 방법 유지 |
| 진단 정보 | 로그에 민감한 내용이 남을 수 있음 | 별도 대화 파일 제외와 로그 잔존 가능성을 구분 |
| 생각 상태 | 생각 중을 생각 과정 제목으로 바꾸면 상태 의미가 달라짐 | 진행 상태용 번역 키를 별도로 사용 |

## 검증 결과

- `scripts/check-localizations.sh`: 1,578개 키의 영어·한국어 번역 누락 없음.
- 전체 카탈로그의 양 언어 자리표시자 호환성, 기존 키의 인자 계약, 새 Swift 사용처의 키 존재 검사 통과.
- TSV가 변경된 636개 키의 before/after를 두 언어로 빠짐없이 담는지 원본·최종 카탈로그와 대조해 통과.
- Xcode 16.3, `/private/tmp/PickyAgentDD`에서 관련 8개 suite의 **522개 테스트 통과**. 앱·테스트 타깃 컴파일 포함.
- 확인된 동작은 오류 복구의 재시도/이어가기 구분, 질문 대기 입력 안내, 브라우저 권한 요청, 네이티브 메뉴, 터미널 lifecycle, 활성 보관 작업 삭제 제한, 연결 실패시 목록 유지, 실제 v2 이벤트 이후 보관 목록·저장 상태 유지다.
- 실행 결과: `/tmp/PickyAgentDD/Logs/Test/Test-Picky-2026.09.25_15-26-22-+0900.xcresult`.
- 실행 중인 앱은 재시작하지 않았다. 화면 캡처나 실제 권한 요청을 통한 수동 UI 검증은 하지 않았다.

## 기존 문구 변경 전체

식별자는 `Picky/Resources/Localizable.xcstrings`의 키다. `%@`, `%lld` 등은 실행 중 이름·숫자로 바뀌는 자리표시자이며 인자 계약을 유지했다.

<details>
<summary>한국어 before/after (408개 키)</summary>

| 식별자 | Before | After |
|---|---|---|
| `dictation.noSpeech` | 음성이 감지되지 않았어요. 버튼을 누른 상태에서 조금 더 길게 말해 주세요. | 음성이 감지되지 않았어요. 음성 입력을 시작한 뒤 다시 말해 주세요. |
| `directMessage.followUpDelivered` | 선택한 Pickle에 follow-up 메시지를 예약했어요. | 선택한 Pickle의 대기열에 후속 요청을 추가했어요. |
| `dock.contextMenu.archive` | 아카이브 | 보관 |
| `dock.contextMenu.pinInput` | Picky 입력을 이 피클에 고정 | Picky 입력을 이 Pickle에 고정 |
| `dock.contextMenu.sendNextInput` | 다음 Picky 입력을 이 피클로 보내기 | 다음 Picky 입력을 이 Pickle로 보내기 |
| `dock.drag.archive.label` | 아카이브 | 보관 |
| `dock.recentFolders.empty` | 아직 최근 폴더가 없습니다. 작업 폴더를 선택해 첫 피클을 시작하세요. | 최근 작업 폴더가 없어요. 폴더를 선택해 Pickle을 시작하세요. |
| `dock.recentFolders.newGroup.hint` | 이름과 선택적 초기 피클로 독 그룹 만들기 | 그룹 이름을 정하고, 원하면 Pickle을 추가하세요 |
| `dock.recentFolders.pin.hint` | 이 폴더를 목록 상단에 고정합니다 | 이 폴더를 목록 상단에 고정해요 |
| `dock.recentFolders.remove.hint` | 폴더 자체는 삭제하지 않습니다 | 폴더 자체는 삭제하지 않아요 |
| `dock.recentFolders.reorder.hint` | 드래그하여 고정 폴더 순서를 변경합니다 | 드래그해 고정 폴더의 순서를 바꾸세요 |
| `dock.recentFolders.unpin.hint` | 이 폴더를 최근 폴더로 되돌립니다 | 이 폴더를 최근 폴더 목록으로 옮겨요 |
| `dock.startPickle` | 피클 시작 | Pickle 시작 |
| `dock.startPickleIn` | %@에서 피클 시작 | %@에서 Pickle 시작 |
| `enum.armedPickleDispatchMode.followUp` | Follow-up | 응답 후 전달 |
| `enum.armedPickleDispatchMode.steer` | Steer | 작업 중 전달 |
| `error.directMessage.contextEmpty` | 메시지를 전송하지 못했어요: 캡처된 컨텍스트가 비어있어요. | 메시지와 함께 보낼 화면·작업 정보를 가져오지 못했어요. 다시 요청해 주세요. |
| `error.directMessage.startFailed` | 새 메시지 세션을 시작하지 못했어요: %@ | 새 대화를 시작하지 못했어요: %@ |
| `extensions.cron.action.setupDaemon` | 데몬 설정 | 예약 자동 실행 설정 |
| `extensions.cron.jobs.back` | Extensions | 플러그인 |
| `extensions.cron.jobs.missing.description` | Cron 데몬을 설정하거나 Pi에서 작업을 만든 뒤 새로고침하세요. | Cron 백그라운드 실행을 설정하거나 Pi에서 작업을 만든 뒤 새로고침해 주세요. |
| `extensions.cron.jobs.unreadable.description` | Cron 작업 저장소 권한을 확인한 뒤 다시 불러오세요. | Cron 작업 저장소 권한을 확인한 뒤 새로고침해 주세요. |
| `extensions.cron.remove.confirm.message` | Picky가 Cron 제거를 실행하고 macOS LaunchAgent가 내려갔는지 확인한 다음 npm 패키지를 제거해요. | Cron 백그라운드 서비스를 중지·제거하고, 중지 여부를 확인한 뒤 플러그인을 제거해요. |
| `extensions.cron.remove.confirm.title` | Cron과 데몬을 제거할까요? | Cron과 백그라운드 서비스를 제거할까요? |
| `extensions.curated.askUserQuestion.description` | Pi가 확인이 필요할 때 radio·checkbox·text 질문을 한 폼으로 구조화해서 받을 수 있어요. | Pi가 확인할 내용이 있으면 단일 선택·복수 선택·텍스트 입력 질문을 한 화면에 보여줘요. |
| `extensions.curated.autoName.description` | 첫 사용자 메시지를 바탕으로 Pi 세션 이름을 자동 지정해 여러 작업을 쉽게 구분할 수 있어요. | 첫 메시지를 바탕으로 Pi 대화 이름을 자동으로 정해 여러 작업을 쉽게 구분할 수 있어요. |
| `extensions.curated.comingSoon` | 곧 추가돼요 — 유용한 Picky 플러그인들을 큐레이션해서 소개할 예정이에요. | 유용한 Picky 플러그인을 모아 소개할 예정이에요. |
| `extensions.curated.cron.description` | 로컬 Pi 작업을 예약해요. 설치·업데이트 시 지속 실행되는 macOS LaunchAgent를 설정하고, Cron 제거 시 해당 데몬도 함께 제거해요. | Mac의 백그라운드 서비스로 Pi 작업을 예약해요. Cron을 설치하면 서비스가 설정되고, Cron을 제거하면 서비스도 제거돼요. |
| `extensions.curated.delayedAction.description` | `/delay` 명령어 또는 `delay` tool로 지정한 시간 뒤 후속 프롬프트를 예약할 수 있어요. | `/delay` 명령어 또는 `delay` 도구로 지정한 시간 뒤 보낼 후속 메시지를 예약해요. |
| `extensions.curated.heading` | 큐레이션 플러그인 | 추천 플러그인 |
| `extensions.curated.memoryLayer.description` | Pi가 세션 간 재사용할 수 있는 로컬 장기 메모리를 저장·검색·목록 조회·삭제해요. | Pi가 다른 대화에서도 참고할 수 있도록 이 Mac에 기억을 저장하고, 검색·조회·삭제해요. |
| `extensions.curated.subagent.description` | run·batch·chain 워크플로우로 코딩·조사 작업을 서브에이전트에 위임합니다. | run·batch·chain 방식으로 코딩·조사 작업을 서브에이전트에 맡겨요. |
| `extensions.curated.todoWriteOverlay.description` | `todo_write` 도구로 세션별 구조화된 할 일을 만들고 갱신하며 진행 상황을 우측 상단 오버레이로 확인할 수 있어요. | `todo_write` 도구로 대화별 할 일을 만들고 수정하며, 화면 오른쪽 위에서 진행 상황을 확인해요. |
| `feedback.sendFailure.diagnostics` | 진단 번들을 준비하지 못했어요. 진단 파일 없이 다시 시도해 보세요. | 진단 파일을 준비하지 못했어요. 진단 파일 첨부를 끄고 다시 시도해 주세요. |
| `feedback.sent` | 보냈어요 — 고마워요! | 보냈어요. 고마워요! |
| `footer.dock.hide` | Dock 숨기기 | 도크 숨기기 |
| `footer.dock.show` | Dock 표시 | 도크 표시 |
| `footer.quit.body` | Picky가 메뉴바에서 종료되며, 진행 중인 로컬 세션이 중단될 수 있어요. | Picky를 종료하면 메뉴 막대에서도 사라져요. 진행 중인 작업이 중단될 수 있어요. |
| `footer.restart.body` | 재시작이 필요한 설정을 적용하기 위해 Picky를 종료한 뒤 다시 열어요. 진행 중인 로컬 세션이 중단될 수 있어요. | 설정을 적용하기 위해 Picky를 종료한 뒤 다시 열어요. 진행 중인 작업이 중단될 수 있어요. |
| `group.delete.confirm.archive` | 피클 보관 | Pickle 보관 |
| `group.delete.confirm.message` | 이 그룹 안의 모든 피클이 보관됩니다. 보관 목록에서 다시 복원할 수 있습니다. | 이 그룹의 모든 Pickle을 보관해요. 보관 목록에서 다시 복원할 수 있어요. |
| `group.delete.confirm.title` | "%@" 그룹을 삭제하고 피클을 보관할까요? | "%@" 그룹을 삭제하고 Pickle을 보관할까요? |
| `group.folder.accessibility.value` | 피클 %1$lld개, 안 읽음 %2$lld개 | Pickle %1$lld개, 안 읽음 %2$lld개 |
| `group.list.accessibility.label` | %1$@, 피클 %2$lld개 | %1$@, Pickle %2$lld개 |
| `group.list.action.archive` | 아카이브 | 보관 |
| `group.list.fallbackTitle` | 피클 | Pickle |
| `group.list.newPickle.accessibilityLabel` | 그룹에 피클 생성 | 그룹에 Pickle 생성 |
| `group.list.newPickle.hint` | 이 그룹에 피클을 만듭니다 | 이 그룹에 Pickle을 만들어요 |
| `group.list.status.blocked` | 차단됨 | 진행 불가 |
| `group.menu.delete` | 그룹 삭제 + 피클 보관 | 그룹 삭제 및 Pickle 보관 |
| `group.menu.ungroup` | 그룹 해제 (피클 유지) | 그룹 해제 (Pickle 유지) |
| `hub.appearance.dark` | 다크 외형 | 다크 모드 |
| `hub.appearance.light` | 라이트 외형 | 라이트 모드 |
| `hub.calendar.estimated` | 반복 예정 | 예상 실행 |
| `hub.calendar.estimatedLegend` | 점선 · 반복 예정 | 점선 · 예상 실행 |
| `hub.calendar.history.note` | 과거는 최근 실행 기록만 표시합니다. 점선은 Cron과 동일하게 이 Mac의 시간대로 계산한 예상 시각입니다. | 과거 일정에는 확인 가능한 실행 기록을 표시해요. 점선은 Cron과 같은 이 Mac의 시간대로 계산한 예상 실행 시각이에요. |
| `hub.calendar.historyTruncated` | 실행 기록이 많아 일부만 읽었습니다. 주간 보기로 범위를 줄여 주세요. | 실행 기록이 많아 일부만 불러왔어요. 주간 보기로 범위를 줄여 주세요. |
| `hub.calendar.install.action` | Cron 설치 | 예약 기능(Cron) 설치 |
| `hub.calendar.install.note` | 설치 후 적용이 필요하면 안내합니다. 진행 중인 작업을 자동으로 중단하지 않습니다. | 설치 후 적용이 필요하면 안내해요. 진행 중인 작업을 자동으로 중단하지는 않아요. |
| `hub.calendar.install.title` | 예약 캘린더를 사용하려면 Cron 플러그인이 필요해요 | 예약 작업을 보려면 예약 기능을 설치하세요 |
| `hub.calendar.noOccurrences` | 이 기간에 표시할 예약이 없습니다. | 이 기간에 표시할 예약이 없어요. |
| `hub.calendar.projected` | 반복 규칙으로 계산한 예정 | 예상 실행 시각 |
| `hub.calendar.promptMissing` | 등록된 지침 파일을 찾을 수 없습니다. | 등록된 지침 파일을 찾을 수 없어요. |
| `hub.calendar.promptTooLarge` | 지침 파일이 너무 커서 표시할 수 없습니다. | 지침 파일이 너무 커서 표시할 수 없어요. |
| `hub.calendar.promptUnreadable` | 지침 파일을 읽을 수 없습니다. | 지침 파일을 읽을 수 없어요. |
| `hub.calendar.promptUnsafe` | Cron 폴더 밖의 파일이나 연결 파일은 열지 않습니다. | Cron 폴더 밖의 파일이나 심볼릭 링크는 열지 않아요. |
| `hub.calendar.scheduleTimezone` | 저장된 시간대 (Cron 계산에 미사용): %@ | 저장된 시간대: %@ (Cron은 이 Mac의 시간대를 사용해요) |
| `hub.calendar.truncated` | 예약이 많아 일부만 표시합니다. 주간 보기나 필터로 범위를 줄여 주세요. | 예약이 많아 일부만 표시해요. 주간 보기나 필터로 범위를 줄여 주세요. |
| `hub.calendar.unsupported.message` | 플러그인과 Picky 버전을 확인해 주세요. 예약 파일은 변경하지 않았습니다. | 플러그인과 Picky 버전을 확인해 주세요. 예약 파일은 변경하지 않았어요. |
| `hub.calendar.unsupportedRules` | 일부 반복 규칙은 미리 계산할 수 없습니다. 해당 작업은 기록된 다음 실행과 최근 결과만 표시합니다. | 일부 반복 규칙은 미리 계산할 수 없어요. 해당 작업은 기록된 다음 실행 시각과 확인 가능한 실행 기록만 표시해요. |
| `hub.conversation.composer.hint` | Enter로 보내고 Shift+Enter로 줄바꿈합니다. | Enter로 보내고 Shift+Enter로 줄을 바꿔요. |
| `hub.conversation.newSession` | 새 세션 | 새 대화 |
| `hub.dashboard.guides.empty` | 다음 앱 업데이트에서 가이드를 확인할 수 있어요. | 아직 표시할 가이드가 없어요. |
| `hub.dashboard.insight.classifying` | 분류 준비 중 | 아직 분류된 작업이 없어요 |
| `hub.dashboard.insight.classifyingCount` | 분류 준비 중 · %lld개 Pickle | 미분류 Pickle %lld개 |
| `hub.dashboard.insight.deepestPickle` | 가장 깊게 진행한 Pickle | 후속 지시·위임이 가장 많은 Pickle |
| `hub.dashboard.insight.delegationCount` | Picky 위임 %lld | Picky 위임 %lld회 |
| `hub.dashboard.insight.focusedProject` | 가장 집중한 프로젝트 | Pickle이 가장 많은 프로젝트 |
| `hub.dashboard.insight.followUpCount` | 후속 지시 %lld | 후속 지시 %lld회 |
| `hub.dashboard.plugins.empty` | 추천 플러그인을 불러오는 중이에요. | 표시할 추천 플러그인이 없어요. |
| `hub.dashboard.share.title` | 피키 공유하기 | Picky 공유하기 |
| `hub.guides.empty.message` | 다음 Picky 업데이트에 새 가이드와 제품 소식이 여기에 표시됩니다. | 새 가이드와 제품 소식을 이곳에서 확인할 수 있어요. |
| `hub.guides.video.error.message` | 연결을 확인한 뒤 다시 시도하거나 YouTube에서 영상을 여세요. | 인터넷 연결을 확인한 뒤 다시 시도하거나 YouTube에서 영상을 열어 주세요. |
| `hub.menu.appearance` | 외형 | 화면 모양 |
| `hub.page.dashboard.subtitle` | 돌아보고, 발견하고, 다음 작업을 시작하세요. | 작업 기록을 확인하고 새 작업을 시작하세요. |
| `hub.page.quickStart.subtitle` | 정해진 흐름으로 새 Pickle 작업을 시작하세요. | 원하는 작업을 골라 새 Pickle을 시작하세요. |
| `hub.plugins.card.setupDaemon` | 데몬 설정 | 예약 자동 실행 설정 |
| `hub.plugins.card.viewJobs` | 작업 보기 | 예약 작업 보기 |
| `hub.plugins.detail.remove.prompt` | 정말 삭제할까요? | 이 플러그인을 삭제할까요? |
| `hub.plugins.feedback.installed` | %1$@을(를) 설치했습니다. | %1$@ 설치를 완료했어요. |
| `hub.plugins.feedback.removed` | %1$@을(를) 삭제했습니다. | %1$@ 삭제를 완료했어요. |
| `hub.plugins.feedback.settingUp` | Cron 데몬 설정 중… | 백그라운드 예약 실행 설정 중… |
| `hub.plugins.feedback.setup` | %@ 데몬 설정을 확인했습니다. | %@ 백그라운드 예약 실행 설정을 확인했어요. |
| `hub.plugins.feedback.updated` | %1$@을(를) 업데이트했습니다. | %1$@ 업데이트를 완료했어요. |
| `hub.plugins.reload.confirm.message.both` | Picky와 실행 중인 Pickle %lld개가 중단될 수 있어요. | Picky와 실행 중인 Pickle %lld개가 중단될 수 있어요. |
| `hub.plugins.reload.confirm.message.main` | Picky의 진행 중인 음성 작업이 중단될 수 있어요. | Picky의 진행 중인 음성 작업이 중단될 수 있어요. |
| `hub.plugins.reload.confirm.message.pickles` | 실행 중인 Pickle %lld개가 중단될 수 있어요. | 실행 중인 Pickle %lld개가 중단될 수 있어요. |
| `hub.plugins.reload.message` | 변경한 플러그인을 사용하려면 Picky와 실행 중인 Pickle을 다시 불러오세요. | 플러그인 변경 사항을 적용하려면 Picky 대화와 열려 있는 Pickle을 다시 불러와야 해요. |
| `hub.plugins.reload.title` | 플러그인 변경 사항을 적용하려면 다시 불러오기가 필요해요 | 플러그인 변경 사항 적용 |
| `hub.plugins.useCase.cron.2` | Picky를 열지 않고 반복 보고서를 자동화할 때 | 정해진 일정에 따라 반복 보고서를 자동으로 만들 때 |
| `hub.plugins.useCase.memoryLayer.1` | 프로젝트 규칙을 세션이 바뀌어도 유지할 때 | 새 대화에서도 프로젝트 규칙을 유지할 때 |
| `hub.plugins.useCase.subagent.1` | 큰 작업을 병렬 워커로 나눌 때 | 큰 작업을 여러 에이전트에게 나눠 맡길 때 |
| `hub.quickStart.chooseWorkflow` | 워크플로우 선택 | 작업 선택 |
| `hub.quickStart.error.notProjected` | 새 Pickle이 제때 나타나지 않았어요. picky-agentd가 실행 중인지 확인하고 다시 시도하세요. | 새 Pickle을 표시하는 데 시간이 걸리고 있어요. 다시 시도해 주세요. |
| `hub.quickStart.footer` | 워크플로우를 시작하면 새 Pickle이 열리고 Pi가 필요한 정보를 한 번에 하나씩 묻습니다. 중간에 나가도 같은 Pickle에서 이어갈 수 있어요. | 작업을 시작하면 새 Pickle이 열리고 필요한 정보를 하나씩 물어봐요. 나중에 같은 Pickle에서 이어갈 수 있어요. |
| `hub.quickStart.resume.pending` | 첫 지시 수락을 확인하지 못했습니다. 다시 보내기 전에 이 Pickle을 열어 확인하세요. | 첫 지시가 전달됐는지 확인하지 못했어요. 다시 보내기 전에 이 Pickle을 열어 확인해 주세요. |
| `hub.quickStart.starting` | %@ 워크플로우를 시작하고 있어요 | %@ 시작 중 |
| `hub.quickStart.success.message` | 새 작업을 열었습니다. Pi가 첫 질문을 준비하고 있어요. | 새 Pickle이 열렸어요. 첫 질문을 준비하고 있어요. |
| `hub.quickStart.success.showWorkflows` | 다른 워크플로우 보기 | 다른 작업 보기 |
| `hub.quickStart.workflow.files.description` | 로컬 폴더를 원하는 기준에 맞춰 정리하는 작업을 시작합니다. | 원하는 기준에 맞춰 이 기기의 폴더를 정리해요. |
| `hub.quickStart.workflow.guide.description` | 현재 사용하는 앱을 Picky와 함께 한 단계씩 익혀봅니다. | 현재 사용하는 앱을 Picky와 함께 한 단계씩 익혀요. |
| `hub.quickStart.workflow.landing.description` | 질의응답 기반 워크플로우로 제품이나 서비스를 소개하는 웹페이지를 만듭니다. | 질문에 답하며 제품이나 서비스를 소개하는 웹페이지를 만들어요. |
| `hub.quickStart.workflow.native.description` | 로컬 환경에서 구동되는 네이티브 앱을 대화로 만들어봅니다. | 대화하며 이 기기에서 실행할 앱을 만들어요. |
| `hub.settings.appearance.detail` | Picky의 밝은 또는 어두운 모양을 선택합니다. | Picky의 라이트 모드 또는 다크 모드를 선택하세요. |
| `hub.settings.autoUpdates.detail` | 새 버전이 있는지 주기적으로 확인합니다. | 새 버전이 있는지 주기적으로 확인해요. |
| `hub.settings.checkUpdates.detail` | 새 업데이트가 있는지 지금 확인합니다. | 새 업데이트가 있는지 지금 확인해요. |
| `hub.settings.classification.accessibilityHint` | 통계 스냅샷을 확인한 뒤에만 변경할 수 있습니다. | 통계를 불러온 뒤 변경할 수 있어요. |
| `hub.settings.classification.detail` | 선택 기능이며 기본적으로 꺼져 있습니다. | 선택 기능이며 기본적으로 꺼져 있어요. |
| `hub.settings.classification.disclosure` | 켜면 Picky는 분류 대상 Pickle의 제목, 짧은 사용자 메시지 발췌 최대 5개, 도구 이름과 횟수, 활동 횟수, 변경 파일 수, 서브에이전트 수를 설정한 모델 범위에서 허용된 인증 모델 제공자에게 보냅니다. 모델 할당량을 사용하거나 제공자 비용이 발생할 수 있습니다. 끄면 새 작업을 분류용으로 전송하지 않습니다. 기존 분류 결과와 로컬 통계는 유지됩니다. | 켜면 분류 대상 Pickle의 제목, 짧은 사용자 메시지 발췌 최대 5개, 도구 이름과 사용 횟수, 활동 횟수, 변경 파일 수, 서브에이전트 수를 설정한 모델 범위에서 허용된 인증된 AI 제공업체에 보내요. 모델 사용 한도를 소모하거나 비용이 발생할 수 있어요. 끄면 새 작업을 분류용으로 보내지 않아요. 기존 분류 결과와 이 Mac의 통계는 유지돼요. |
| `hub.settings.classification.title` | 모델 작업 분류 | AI 작업 분류 |
| `hub.settings.fontScale.detail` | Picky 전체에 적용할 글자 크기를 조정합니다. | Picky 전체에 적용할 글자 크기를 조정해요. |
| `hub.settings.group.general.subtitle` | 표시와 업데이트 | 언어, 화면 모양, 업데이트 |
| `hub.settings.notification.detail` | Picky가 알릴 시점을 선택합니다. | Picky가 알릴 시점을 선택하세요. |
| `hub.settings.onboarding` | 온보딩 다시 보기 | 처음 사용 안내 다시 보기 |
| `hub.settings.onboarding.detail` | 처음 사용 안내를 처음 단계부터 다시 확인합니다. | 처음 사용 안내를 첫 단계부터 다시 확인해요. |
| `hub.settings.onboarding.dialog.message` | 처음 사용 안내의 진행 상태가 처음 단계로 돌아갑니다. | 지금 바로 처음부터 안내 데모를 시작해요. 데모 중에는 눌러서 말하기와 빠른 입력을 사용할 수 없어요. |
| `hub.settings.onboarding.dialog.title` | 온보딩을 다시 시작할까요? | 처음 사용 안내를 다시 시작할까요? |
| `hub.settings.permission.detail` | 이 권한은 시스템 설정에서 관리할 수 있습니다. | 이 권한은 시스템 설정에서 관리할 수 있어요. |
| `hub.settings.pinnedFolders.detail` | Pickle 폴더 선택기 위쪽에 유지할 폴더입니다. | Pickle 작업 폴더를 고를 때 목록 위쪽에 표시할 폴더예요. |
| `hub.settings.privacy.notice` | 대화, Pickle 기록, 설정은 기본적으로 이 Mac의 Picky 앱 데이터에 보관됩니다. 선택한 AI·음성 제공업체를 사용할 때 요청 텍스트, 음성 또는 선택한 화면 맥락이 해당 제공업체로 전송될 수 있습니다. | 대화, Pickle 기록, 설정은 기본적으로 이 Mac에 보관돼요. AI·음성 제공업체를 사용하면 요청 텍스트, 음성 또는 선택한 화면 맥락이 해당 제공업체로 전송될 수 있어요. |
| `hub.settings.recentFolders.detail` | 최근 Pickle을 시작할 때 사용한 폴더입니다. | 최근 Pickle을 시작할 때 사용한 폴더예요. |
| `hub.settings.reportFontScale.detail` | 생성된 보고서 창에 적용합니다. | 생성된 보고서 창에 적용해요. |
| `hub.settings.restart.message` | 변경 사항을 적용하려면 다시 시작이 필요해요. | 변경 사항을 적용하려면 Picky를 다시 시작해야 해요. |
| `hub.settings.shellCommand` | 셸 명령 도구 | picky 명령 관리 |
| `hub.settings.shellCommand.detail` | Picky의 명령줄 도우미를 설치하거나 다시 설치합니다. | 터미널에서 쓰는 picky 명령을 설치·재설치하거나 제거해요. |
| `hub.settings.statisticsReset` | 통계 데이터 초기화 | 작업 분류 초기화 |
| `hub.settings.statisticsReset.action` | 통계 데이터 초기화 | 작업 분류 초기화 |
| `hub.settings.statisticsReset.detail` | 저장된 통계 분류를 초기화하며, 이 작업은 되돌릴 수 없습니다. | 저장된 분류를 삭제해요. AI 작업 분류가 켜져 있으면 다시 분류될 수 있어요. 작업 기록과 AI 사용량은 유지돼요. |
| `hub.settings.statisticsReset.dialog.confirm` | 통계 데이터 초기화 | 작업 분류 초기화 |
| `hub.settings.statisticsReset.dialog.message` | 저장된 통계 분류가 삭제되며, 초기화한 데이터는 복구할 수 없습니다. | 저장된 작업 분류를 삭제해요. AI 작업 분류가 켜져 있으면 기존 Pickle도 다시 분류될 수 있어요. 작업 기록, AI 사용량, 분류 설정은 유지돼요. |
| `hub.settings.statisticsReset.dialog.title` | 통계 데이터를 초기화할까요? | 작업 분류를 초기화할까요? |
| `hub.settings.statisticsReset.pending` | 통계 데이터를 초기화하는 중… | 작업 분류를 초기화하는 중… |
| `hub.settings.statisticsReset.success` | 통계 데이터를 초기화했습니다. | 작업 분류를 초기화했어요. |
| `hub.settings.terminalFontScale.detail` | 명령과 도구 출력에 적용합니다. | 명령과 도구 출력에 적용해요. |
| `hub.settings.updateChannel.detail` | 안정판 또는 미리 보기 업데이트를 받습니다. | 안정판 또는 미리 보기 업데이트를 선택하세요. |
| `hub.settings.watchdog.detail` | 앱 응답이 지연될 때 진단 신호를 남깁니다. | 앱 응답이 지연되면 진단 기록을 남겨요. |
| `hub.stats.error.disconnected` | 통계를 불러오는 중 picky-agentd 연결이 끊어졌어요. | 연결이 끊겨 통계를 불러오지 못했어요. 다시 시도해 주세요. |
| `hub.stats.usage.costNotice` | 비용은 추정하지 않습니다. 연결된 제공업체에서 비용을 확인하세요. | 비용은 추정하지 않아요. 연결된 제공업체에서 확인해 주세요. |
| `hub.stats.usage.empty.message` | 연결된 제공업체의 사용량이 이곳에 표시됩니다. | 선택한 기간과 프로젝트에 기록된 AI 사용량이 없어요. Picky 작업에서 기록된 사용량이 생기면 이곳에 표시돼요. |
| `hub.stats.work.classifying` | %lld개 Pickle은 아직 분류 중이에요. | 아직 분류되지 않은 Pickle이 %lld개 있어요. |
| `hub.stats.work.empty.message` | 선택한 기간과 프로젝트에서 작업 기록을 찾지 못했습니다. 대시보드에서 새 작업을 시작해보세요. | 선택한 기간과 프로젝트에 작업 기록이 없어요. 대시보드에서 새 작업을 시작해 보세요. |
| `hub.stats.work.records.caption` | 후속 지시, Picky 위임, 검토는 완료 수가 아니라 각 Pickle 안의 상호작용 횟수입니다. | 후속 지시, Picky 위임, 검토는 완료한 작업 수가 아니라 각 Pickle에서 주고받은 횟수예요. |
| `hud.activity.summary.toolsUsed.many` | 도구 %lld회 사용 | 도구 %lld회 사용 |
| `hud.activity.summary.toolsUsed.one` | 도구 %lld회 사용 | 도구 %lld회 사용 |
| `hud.archiveToast.title` | 세션을 아카이브했어요 | Pickle을 보관했어요 |
| `hud.archivedList.confirmDelete` | 한 번 더 누르면 삭제 | 한 번 더 클릭하면 삭제 |
| `hud.archivedList.confirmDeleteAllMessage` | 이 작업은 되돌릴 수 없어요. 모든 아카이브 Pickle이 Picky와 로컬 에이전트 세션 저장소에서 함께 제거돼요. | 보관된 Pickle 중 완료·실패·중지·진행 불가 상태만 영구 삭제해요. 실행 중이거나 실행·입력 대기 중인 Pickle은 남겨 둬요. 삭제는 되돌릴 수 없어요. |
| `hud.archivedList.confirmDeleteAllTitle` | 아카이브된 Pickle %lld개를 영구 삭제할까요? | 진행 중이 아닌 Pickle %lld개를 삭제할까요? |
| `hud.archivedList.deleteAll` | 전체 삭제 | 진행 중이 아닌 Pickle 삭제 |
| `hud.archivedList.empty` | 아카이브된 Pickle이 없어요. | 보관된 Pickle이 없어요. |
| `hud.archivedList.title` | 아카이브된 Pickle | 보관된 Pickle |
| `hud.artifacts.accessibilityLabel` | 세션 파일 작업물 | Pickle의 파일 결과물 |
| `hud.artifacts.empty` | Pi가 파일 저장 도구로 저장한 문서·데이터·이미지가 여기에 모여요 | 이 Pickle이 저장한 파일은 여기에 표시돼요. |
| `hud.changes.accessibilityLabel` | 세션 변경사항 | Pickle 변경사항 |
| `hud.changes.diffTruncated` | diff 출력이 잘렸습니다 | 변경 내용이 길어 일부만 표시해요 |
| `hud.changes.empty` | 이 보기에는 변경사항이 없습니다 | 이 보기에는 변경사항이 없어요 |
| `hud.changes.error` | 변경사항 오류: %@ | 변경사항을 불러오지 못했어요: %@ |
| `hud.changes.fileSummary` | %@, 추가 %lld개, 삭제 %lld개 | %@, %lld줄 추가, %lld줄 삭제 |
| `hud.changes.filesTruncated` | 추가 변경 파일은 표시되지 않습니다 | 변경된 파일 중 일부만 표시해요 |
| `hud.changes.notGitRepository` | 이 폴더는 Git 저장소가 아닙니다 | 이 폴더는 Git 저장소가 아니에요 |
| `hud.compact.done.body` | 이전 컨텍스트를 요약했어요. 에이전트가 더 깔끔한 대화로 이어갈 수 있어요. | 이전 대화를 요약했어요. 요약한 내용을 바탕으로 대화를 이어가요. |
| `hud.compact.done.title` | 세션이 압축됐어요 | 대화를 압축했어요 |
| `hud.composer.placeholder.compacting` | 압축 후 보낼 메시지를 대기열에 추가… | 대화 압축이 끝난 뒤 보낼 메시지… |
| `hud.composer.placeholder.recovery` | 복구 지시를 보내거나 터미널 열기 | 다시 요청하거나 Pi 터미널 열기 |
| `hud.composer.placeholder.resume` | 지시를 보내 에이전트 재개… | 메시지를 보내 작업 이어가기… |
| `hud.composer.placeholder.steer` | 에이전트에 개입 · ⌥↵ 후속 요청 · esc 중지 | 작업 지시 추가 · ⌥↵ 후속 요청 · esc 중지 |
| `hud.composer.runtime.accessibilityLabel` | 작성기 런타임 설정 | 모델 및 추론 설정 |
| `hud.composer.runtime.defaultThinking` | 현재 추론 레벨을 새 Pickle 기본값으로 설정 | 현재 추론 수준을 새 Pickle 기본값으로 설정 |
| `hud.composer.runtime.failed` | 런타임 설정 실패: %@ | 모델 또는 추론 설정을 변경하지 못했어요: %@ |
| `hud.composer.runtime.model.accessibilityHint` | 모델을 선택합니다. Control-P는 다음 모델로, Shift-Control-P는 이전 모델로 변경합니다. | 모델을 선택하세요. Control-P는 다음 모델, Shift-Control-P는 이전 모델로 바꿔요. |
| `hud.composer.runtime.picker.advancedReadOnly` | 이 Pi 모델 범위는 고급 패턴을 사용하므로 여기서는 읽기 전용입니다. | 이 Pi 모델 범위는 고급 패턴을 사용해 여기서 변경할 수 없어요. |
| `hud.composer.runtime.picker.conflict` | 다른 곳에서 모델 범위가 변경되었습니다. 적용하기 전에 최신 상태를 불러오세요. | 다른 곳에서 모델 범위가 변경됐어요. 최신 상태를 불러온 뒤 적용하세요. |
| `hud.composer.runtime.picker.currentOutsideScope` | 현재 모델(%@)은 이 범위 밖에 있습니다. | 현재 모델(%@)은 이 범위에 포함되지 않아요. |
| `hud.composer.runtime.picker.empty` | 사용 가능한 모델이 없습니다 | 사용 가능한 모델이 없어요 |
| `hud.composer.runtime.picker.failed` | 모델을 불러올 수 없습니다: %@ | 모델을 불러오지 못했어요: %@ |
| `hud.composer.runtime.picker.projectOverride` | 이 프로젝트는 전역 모델 범위를 재정의합니다. 전역 편집으로 바뀌지 않습니다. | 이 프로젝트는 별도의 모델 범위를 사용해요. 전역 설정을 바꿔도 이 프로젝트에는 적용되지 않아요. |
| `hud.composer.runtime.picker.unavailableScope` | 모델 범위를 사용할 수 없습니다. 최신 상태를 불러온 후 다시 시도하세요. | 모델 범위를 불러올 수 없어요. 최신 상태를 불러온 뒤 다시 시도하세요. |
| `hud.composer.runtime.thinking.accessibilityHint` | 지원되는 추론 수준을 선택합니다. Shift-Tab으로 수준을 변경합니다. | 지원되는 추론 수준을 선택하세요. Shift-Tab으로 수준을 바꿔요. |
| `hud.composer.send.compacting` | 압축이 끝날 때까지 메시지를 대기열에 추가 | 압축이 끝난 뒤 보낼 메시지를 대기열에 추가 |
| `hud.composer.send.steer` | 개입 메시지 보내기 | 진행 중인 작업에 지시 보내기 |
| `hud.composer.send.unavailable` | 이 세션은 작성기 입력을 받을 수 없습니다 | 이 대화에는 메시지를 보낼 수 없어요 |
| `hud.composer.steerTarget` | 다음 Picky 화면 입력은 이 Pickle로 전달돼요 | 다음 Picky 음성 또는 빠른 텍스트 입력을 이 Pickle로 보내요 |
| `hud.composer.stop.help` | 이 Pickle 중지 | Pickle 작업을 중지해요. 대기 텍스트는 입력란으로 옮기지만, 대기 중인 화면 첨부는 복원할 수 없어요. |
| `hud.composer.submit.steer` | 개입 | 지시 보내기 |
| `hud.context.details.accessibilityHint` | 작업 폴더, Git, 링크를 표시합니다 | 작업 폴더, Git 정보, 링크를 보여줘요 |
| `hud.context.details.accessibilityLabel` | 컨텍스트 상세 | 작업 정보 |
| `hud.contextCompaction.description` | 오래된 대화를 요약해 컨텍스트 여유 공간을 확보합니다. | 이전 대화를 요약해 새 내용을 담을 공간을 확보해요. |
| `hud.contextCompaction.title` | 세션 컨텍스트 | 대화 컨텍스트 |
| `hud.contextCompaction.unavailable` | 현재 작업이 끝나면 압축할 수 있습니다. | 현재 응답이 끝나면 압축할 수 있어요. |
| `hud.conversation.historyStart` | 대화의 시작입니다 | 대화의 시작이에요 |
| `hud.conversation.loadMoreTurns` | 이전 %lld턴 더 보기 · 숨겨진 %lld턴 | 이전 요청 %lld개 더 보기 · %lld개 숨김 |
| `hud.conversation.loadMoreTurns.help` | 이전 턴 보기 | 이전 요청과 응답 보기 |
| `hud.conversation.meta.context.unknown` | 압축 후 다음 모델 응답 전까지 컨텍스트 사용량을 알 수 없습니다 | 대화 압축 후 사용량은 다음 모델 응답이 오면 확인할 수 있어요 |
| `hud.conversation.status.blocked` | 차단됨 | 진행 불가 |
| `hud.conversation.turn.collapse.accessibilityHint` | 턴 접기 | 요청과 응답 접기 |
| `hud.conversation.turn.current.accessibilityLabel` | 현재 턴 | 현재 요청 |
| `hud.conversation.turn.expand.accessibilityHint` | 턴 펼치기 | 요청과 응답 펼치기 |
| `hud.conversation.turn.latest.accessibilityLabel` | 최신 턴 | 최근 요청 |
| `hud.conversation.turn.previous.accessibilityLabel` | 이전 턴 | 이전 요청 |
| `hud.conversation.turn.tool.many` | 도구 %lld개 | 도구 %lld회 사용 |
| `hud.conversation.turn.tool.one` | 도구 %lld개 | 도구 %lld회 사용 |
| `hud.error.header` | 실패 · 런타임 오류 | 요청 처리 오류 |
| `hud.header.archive.accessibilityHint` | Pickle을 중지하지 않고 Dock에서 숨깁니다. 6초 안에 되돌릴 수 있습니다. | Pickle을 중지하지 않고 Dock에서 숨겨요. 6초 안에 되돌릴 수 있어요. |
| `hud.header.archive.accessibilityLabel` | Pickle 아카이브 | Pickle 보관 |
| `hud.header.archive.help` | Pickle 아카이브 (⌘⌫) | Pickle 보관 (⌘⌫) |
| `hud.header.close.accessibilityHint` | Pickle을 중지하지 않고 이 카드를 닫습니다 | Pickle을 중지하지 않고 이 카드를 닫아요 |
| `hud.header.close.accessibilityLabel` | Pickle HUD 닫기 | Pickle 대화 카드 닫기 |
| `hud.header.close.help` | Pickle HUD 닫기 (Esc 또는 ⌘W) | Pickle 대화 카드 닫기 (Esc 또는 ⌘W) |
| `hud.header.target.accessibilityLabel` | 세션 상태: %@ | Pickle 상태: %@ |
| `hud.header.target.armed.accessibilityLabel` | 세션 상태: %@, Pickle 커서 준비됨 | Pickle 상태: %@, 다음 입력 대상 |
| `hud.header.target.armed.help` | Pickle 커서가 준비됐습니다. 다음 Picky 음성 또는 빠른 텍스트 입력이 이 Pickle로 전달됩니다. 취소하려면 클릭하거나 ⌘K를 누르고, 고정하려면 길게 누르세요. | 다음 Picky 음성 또는 빠른 텍스트 입력을 이 Pickle로 보내요. 해제하려면 클릭하거나 ⌘K를 누르세요. 계속 보내려면 길게 눌러 고정하세요. |
| `hud.header.target.locked.accessibilityLabel` | 세션 상태: %@, Pickle 커서 고정됨 | Pickle 상태: %@, 입력 대상 고정됨 |
| `hud.header.target.locked.help` | Pickle 커서가 고정됐습니다. 다시 클릭하거나 다른 Pickle을 준비할 때까지 모든 Picky 음성 또는 빠른 텍스트 입력이 이 Pickle로 전달됩니다. 전환하려면 다른 Pickle을 길게 누르세요. | Picky 음성과 빠른 입력을 계속 이 Pickle로 보내요. 고정을 풀려면 다시 클릭하세요. 대상을 바꾸려면 다른 Pickle의 입력 대상 배지를 클릭하고, 고정하려면 그 배지를 길게 누르세요. |
| `hud.header.target.route.help` | %@. 다음 Picky 화면 컨텍스트 입력을 이 Pickle로 보내려면 클릭하거나 ⌘K를 누르세요. 고정 대상으로 설정하려면 길게 누르세요. | %@. 다음 Picky 음성 또는 빠른 텍스트 입력을 여기로 보내려면 클릭하거나 ⌘K를 누르세요. 계속 보내려면 길게 눌러 고정하세요. |
| `hud.header.target.voice.accessibilityLabel` | 세션 상태: %@, 음성 개입 대상 | Pickle 상태: %@, 음성 지시 대상 |
| `hud.header.target.voice.help` | %@. 음성 개입 대상 | %@. 음성 지시 대상 |
| `hud.inlineTerminal.backToChat.help` | SwiftUI 채팅과 작성기로 돌아가기 (⌘T) | 채팅과 메시지 입력으로 돌아가기 (⌘T) |
| `hud.inlineTerminal.showThisTUI` | 이 TUI 보기 | 이 터미널 보기 |
| `hud.inlineTerminal.singleton.body` | 활성 TUI Pickle을 닫거나 TUI 화면을 여기로 옮겨주세요. | 이곳에서 보려면 ‘이 터미널 보기’를 선택하세요. |
| `hud.inlineTerminal.singleton.title` | TUI는 한 번에 하나의 Pickle에서만 열 수 있어요. | Pi 터미널은 한 번에 하나의 Pickle에서만 볼 수 있어요. |
| `hud.inlineTerminal.tab.tui` | TUI | 터미널 |
| `hud.liveStep.goToQuestion.accessibilityHint` | 키보드 초점을 질문으로 이동합니다 | 키보드 초점을 질문으로 옮겨요 |
| `hud.menu.archive` | 아카이브 | 보관 |
| `hud.menu.sessionInfo` | 세션 정보 | 대화 정보 |
| `hud.menu.showChatUI` | 채팅 UI 보기 | 채팅 보기 |
| `hud.menu.stopSession` | 세션 중단 | 작업 중지 |
| `hud.queue.batch.followUp` | 후속 요청 묶음 · 유휴 상태에 모두 전달 | 후속 요청 묶음 · 현재 작업이 끝나면 모두 전달 |
| `hud.queue.batch.steer` | 개입 묶음 · 다음 턴에 모두 전달 | 작업 지시 묶음 · 다음 응답에 모두 전달 |
| `hud.queue.clear` | 지우기 | 대기 요청 삭제 |
| `hud.queue.clear.help` | 작성기로 복원하지 않고 대기 중인 작업 지우기 | 입력란으로 옮기지 않고 대기 중인 메시지 삭제 |
| `hud.queue.pending.steer` | 개입 대기 | 작업 지시 대기 |
| `hud.queue.restore` | 복원 | 입력란으로 옮기기 |
| `hud.queue.restore.accessibilityLabel` | 대기 중인 메시지 복원 | 대기 중인 메시지를 입력란으로 옮기기 |
| `hud.queue.restore.blockedByScreenContext.accessibilityLabel` | 대기 중인 메시지 복원 불가: 첨부된 화면 이미지 %lld개는 아직 복원할 수 없습니다 | 메시지를 입력란으로 옮길 수 없음: 첨부된 화면 이미지 %lld개 복원 미지원 |
| `hud.queue.restore.blockedByScreenContext.error` | 첨부된 화면 이미지 %lld개는 아직 복원할 수 없어 복원을 사용할 수 없습니다 | 첨부된 화면 이미지 %lld개는 아직 복원할 수 없어 메시지를 입력란으로 옮길 수 없어요. |
| `hud.queue.restore.blockedByScreenContext.help` | 첨부된 화면 이미지 %lld개는 아직 복원할 수 없어 복원을 사용할 수 없습니다 | 첨부된 화면 이미지 %lld개는 아직 복원할 수 없어 메시지를 입력란으로 옮길 수 없어요. |
| `hud.queue.restore.help` | 대기 중인 메시지를 작성기로 복원하고 대기열 지우기 | 대기 중인 메시지를 입력란으로 옮기고 대기열 비우기 |
| `hud.queue.restoring` | 복원 중… | 입력란으로 옮기는 중… |
| `hud.rewind.empty` | 되돌릴 수 있는 사용자 메시지가 없습니다. | 되돌릴 수 있는 사용자 메시지가 없어요. |
| `hud.subagent.invocation.batch` | batch ×%lld | 병렬 ×%lld |
| `hud.subagent.invocation.chain` | chain %1$lld/%2$lld | 순차 %1$lld/%2$lld |
| `hud.subagent.invocation.run` | run | 실행 |
| `hud.todo.collapse` | 작업 진행 목록 축소 | 작업 진행 목록 접기 |
| `hud.todo.toggle.help` | 작업 진행 목록 펼치기 또는 축소하기 | 작업 진행 목록 펼치기 또는 접기 |
| `hud.toolHistory.argumentsUnavailable` | 원본 입력을 아직 확인할 수 없습니다. | 원본 입력을 아직 확인할 수 없어요. |
| `hud.toolHistory.ask.awaiting` | 세션에서 답변을 기다리고 있습니다. | 대화에서 답변을 기다리고 있어요. |
| `hud.toolHistory.ask.dismissed` | 답변 없이 닫은 질문입니다. | 답변을 제출하지 않고 닫은 질문이에요. |
| `hud.toolHistory.ask.unavailable` | 구조화된 답변을 확인할 수 없어 저장된 응답을 표시합니다. | 답변을 항목별로 표시할 수 없어 저장된 응답을 보여드려요. |
| `hud.toolHistory.categoryFilter.accessibilityLabel` | %@ %lld개 호출 | %@, %lld회 호출 |
| `hud.toolHistory.detail.attachmentsOmitted` | 이미지 데이터는 제외했습니다. 텍스트와 저장된 메타데이터를 표시합니다. | 이미지 데이터는 생략하고 텍스트와 확인 가능한 메타데이터만 표시해요. |
| `hud.toolHistory.detail.failed` | 원문을 불러오지 못했습니다. daemon 연결을 확인한 뒤 다시 시도하세요. | 원문을 불러오지 못했어요. 다시 시도하세요. |
| `hud.toolHistory.detail.pending` | 결과가 아직 저장되지 않았습니다. 잠시 후 다시 시도하세요. | 결과가 아직 저장되지 않았어요. 잠시 후 다시 시도하세요. |
| `hud.toolHistory.detail.scope` | 저장된 실행 기록입니다. Pi가 도구 출력 자체를 잘라 저장했을 수 있습니다. | 저장된 실행 기록이에요. Pi가 도구 출력의 일부만 저장했을 수 있어요. |
| `hud.toolHistory.detail.sourceChanged` | 세션이 변경됐습니다. 상세를 닫고 갱신된 이력에서 호출을 선택하세요. | 대화가 변경됐어요. 상세 창을 닫고 새로 불러온 도구 기록에서 다시 선택하세요. |
| `hud.toolHistory.detail.storedPreview` | 저장된 미리보기 · 원문 전체가 아닐 수 있습니다 | 저장된 미리보기 · 원문 일부만 포함할 수 있어요 |
| `hud.toolHistory.detail.storedPreviewTruncated` | 저장된 미리보기 · 일부가 잘려 원문 전체가 아닙니다 | 저장된 미리보기 · 원문 일부가 잘렸어요 |
| `hud.toolHistory.detail.unavailable` | 원본이 없거나 읽을 수 없거나, 호출을 식별할 수 없거나 읽기 제한을 초과했습니다. 미리보기는 계속 볼 수 있습니다. | 원문을 찾거나 읽을 수 없어요. 기록을 식별하지 못했거나 읽기 제한을 초과했을 수도 있어요. 저장된 미리보기가 있으면 아래에 표시해요. |
| `hud.toolHistory.detail.unsupported` | 직접 실행한 셸 명령의 원문 조회는 아직 지원하지 않습니다. | 직접 실행한 셸 명령은 아직 원문을 조회할 수 없어요. |
| `hud.toolHistory.empty` | 아직 기록된 툴 호출이 없어요 | 아직 기록된 도구 호출이 없어요 |
| `hud.toolHistory.file.unavailable` | 파일을 열 수 없습니다 | 파일을 열 수 없어요 |
| `hud.toolHistory.filter.empty` | 필터와 일치하는 툴 호출이 없어요 | 필터와 일치하는 도구 호출이 없어요 |
| `hud.toolHistory.scope.session` | 전체 세션 | 전체 대화 |
| `hud.toolHistory.scope.turn` | 현재 턴 | 이번 응답 |
| `hud.toolHistory.search.accessibilityLabel` | 툴 이력 검색 | 도구 기록 검색 |
| `hud.toolHistory.search.placeholder` | 툴 검색 | 도구 검색 |
| `hud.utilityPanel.accessibilityLabel` | 피클 유틸리티 패널 | Pickle 작업 패널 |
| `hud.utilityPanel.changes.placeholder` | 변경사항이 여기에 표시됩니다 | 변경사항이 여기에 표시돼요 |
| `hud.utilityPanel.tab.artifacts` | 작업물 | 결과물 |
| `hud.utilityPanel.toggle.help` | 유틸리티 패널 표시 또는 숨기기(⌘E) | 작업 패널 표시 또는 숨기기 (⌘E) |
| `messages.empty.body` | Control+Option을 누르고 있거나 아래에 직접 입력해 보세요. 프롬프트와 Picky의 응답이 여기에 표시돼요. | 음성으로 말하거나 아래에 입력하세요. 보낸 메시지와 Picky의 답변이 여기에 표시돼요. |
| `messages.newSession` | 새 세션 | 새 대화 |
| `messages.newSession.starting` | 새 세션 시작 중 | 새 대화 시작 중 |
| `messages.subtitle` | 최근 프롬프트와 응답 100개. | 최근 메시지와 답변, 최대 100개 |
| `notif.session.completed.title` | 분석이 끝났어요 | 작업이 끝났어요 |
| `onboarding.bubble.awaitingArchive` | 이제 데모 Pickle을 **길게 눌러** 아카이브해 보세요. | 이제 데모 Pickle을 **길게 눌러** 보관해 보세요. |
| `onboarding.bubble.awaitingPickleOpen` | **도크의 Pickle을 열어** 서 계속 진행해 주세요. | 계속하려면 **도크의 Pickle을 열어 주세요.** |
| `onboarding.bubble.delegatingToPickle` | '**Hey Pickle** — 이 페이지 요약해서 정리해 줄래요? 표시한 부분 위주로요.' | '**Hey Pickle**, 이 페이지를 요약해서 정리해 줄래요? 표시한 부분 위주로요.' |
| `onboarding.bubble.explainingDelegation` | 이런 페이지는 제가 바로 답할 수도 있고, 도크의 **Pickle** 에 작업을 맡길 수도 있어요. | 이런 페이지는 제가 바로 답할 수도 있고, 도크의 **Pickle**에 작업을 맡길 수도 있어요. |
| `onboarding.bubble.explainingPickle` | Pickle은 도크에서 도는 독립된 **Pi 세션** 이에요 — 긴 작업을 위한 백그라운드 탭 같은 거죠. | Pickle은 도크에서 **독립적으로 작업하는 Pi 대화**예요. 오래 걸리는 일을 맡기고 다른 작업을 계속할 수 있어요. |
| `onboarding.bubble.explainingTriggers` | 저를 부를 때는 **눌러서 말하기(Control+Option)** 또는 **퀵 인풋(Control 더블탭)을** 쓰면 돼요. **이번 데모는 제가 진행할 테니 편하게 보세요.** | 설정한 **눌러서 말하기**나 **빠른 입력** 단축키로 저를 부를 수 있어요. **이번 데모는 제가 진행할 테니 편하게 보세요.** |
| `onboarding.bubble.introducing` | 안녕하세요! 저는 **Picky** 예요. 작업하는 바로 그 자리에서 커서를 따라다니며 도와드릴게요. | 안녕하세요! 저는 **Picky**예요. 커서를 따라다니며 지금 하는 일을 도와드릴게요. |
| `onboarding.bubble.inviteArchive` | Pickle을 다 썼다면 **길게 누르기** 로 아카이브할 수 있어요. | 작업이 끝난 Pickle은 **길게 눌러** 보관할 수 있어요. |
| `onboarding.bubble.inviteClose` | 이제 **도크의 Pickle을 다시 클릭** 해서 닫아주세요. | 이제 **도크의 Pickle을 다시 클릭해서** 닫아 주세요. |
| `onboarding.bubble.openedPickle` | Pickle 안에서는 후속 메시지를 보내거나, **터미널 UI로도 전환(⌘T)** 해서 사용할 수 있어요. | Pickle 안에서 메시지를 더 보내거나 **터미널로 전환(⌘T)**해 작업을 이어갈 수 있어요. |
| `onboarding.bubble.openingPatchNotes` | **Pi 0.73.1 릴리즈 노트** 를 브라우저에서 열고 있어요… | 브라우저에서 **Pi 0.73.1 릴리스 노트**를 열고 있어요… |
| `onboarding.bubble.outro` | 좋아요. Picky 사용법이 궁금하면 언제든 저에게 물어보세요. Picky의 내장 가이드를 바탕으로 알려드릴게요. **눌러서 말하기(Control+Option)** 또는 **퀵 인풋(Control 더블탭)** 으로 저를 불러주세요. | Picky 사용법이 궁금하면 언제든 물어보세요. 내장 가이드를 참고해 알려드릴게요. 설정한 **눌러서 말하기**나 **빠른 입력** 단축키로 저를 불러 주세요. |
| `onboarding.bubble.pickleCompleted` | Pickle이 끝났어요! 도크에서 **Pickle을 클릭** 해서 결과를 확인해 보세요. | Pickle 작업이 끝났어요! 도크에서 **Pickle을 클릭해** 결과를 확인해 보세요. |
| `onboarding.bubble.pickleRunning` | Pickle이 일하는 동안 **표시해 둔 영역** 이 컨텍스트로 같이 따라가는걸 위 미리보기에서 확인할 수 있어요. | 위 미리보기에서 **표시한 영역**이 Pickle에 함께 전달되는 모습을 확인해 보세요. |
| `onboarding.bubble.preWelcome` | 이 온보딩은 **실제 LLM 호출을 하지 않아요**. 편하게 따라와 주세요. | 이 사용 안내 데모에서는 **AI 모델을 실제로 호출하지 않아요**. 편하게 따라와 주세요. |
| `onboarding.bubble.showingCapabilities` | 저는 여러 가지 일을 할 수 있어요. 예를 들면 Pi의 릴리즈 노트를 띄워줄 수 있죠. | 저는 여러 가지 일을 할 수 있어요. 예를 들어 Pi의 릴리스 노트를 열어볼게요. |
| `onboarding.highlight.header` | 이게 컨텍스트로 전송되는 내용이에요 | 작업과 함께 전달되는 내용이에요 |
| `onboarding.skip.button` | 온보딩 건너뛰기 | 사용 안내 건너뛰기 |
| `overlay.captureBorder.contextLabel` | 이 화면이 맥락으로 전달됩니다 | 다음 요청에 이 화면을 포함해요 |
| `overlay.captureBorder.notIncludedLabel` | 이 화면은 맥락에 포함되지 않습니다 | 다음 요청에 이 화면을 포함하지 않아요 |
| `prereq.copy.contextHandoff` | 단축키를 누르면 중립적인 데스크톱 컨텍스트를 캡처해서 로컬 에이전트 클라이언트에 전달해요. | 음성이나 텍스트로 요청하면 화면과 선택한 텍스트 등 작업에 참고할 정보를 수집해 Pi에 전달해요. |
| `prereq.copy.noAccount` | 계정도 결제도 필요 없어요 — 로컬에 설치된 Pi를 사용해요. | Picky는 별도 계정 없이 사용할 수 있어요. 선택한 AI·음성 서비스에는 로그인이나 요금이 필요할 수 있어요. |
| `prereq.copy.runsLocally` | Picky는 로컬에서 동작해요. | Picky는 이 Mac에서 실행돼요. |
| `prereq.heading` | 사전 요건 | 필요한 권한 |
| `prereq.screenRecording.detail.granted` | 단축키를 사용할 때만 스크린샷을 찍어요 | 요청에 참고할 화면을 캡처해요. 전송 조건은 설정에서 바꿀 수 있어요. |
| `settings.builtinTools.tool.readUserGuide.description` | 에이전트가 Picky 사용법 질문에 답하기 전 내장 매뉴얼을 참조하도록 해요. 끄면 일반 지식으로 답해요. | Picky 사용법에 답할 때 내장 가이드를 참고할 수 있게 해요. 끄면 이 도구로 가이드를 읽을 수 없어요. |
| `settings.builtinTools.tool.screenOverlay.description` | Picky가 화면의 위치를 가리키거나 도형을 그려 안내해요. 끄면 화면에 아무것도 표시하지 않아요. | Picky가 화면의 위치를 가리키거나 도형을 그려 안내할 수 있게 해요. 끄면 이 시각적 안내를 표시하지 않아요. |
| `settings.cursor.disabledNote` | Pi 커서가 숨겨져 있는 동안에는 부드러운 따라다니기와 유휴 애니메이션이 비활성화돼요. | Picky 커서를 숨기면 부드러운 커서 추적과 대기 애니메이션도 꺼져요. |
| `settings.cursorBubbles.toggle.userSTT` | 사용자 음성 인식 표시 | 인식한 내 말 표시 |
| `settings.dispatch.idle.note` | 전달 대상으로 지정한 Pickle의 PTT·Quick Input에 적용돼요. 작업 중이 아닌 Pickle은 어느 쪽이든 바로 시작돼요. | 전달 대상으로 지정한 Pickle에 눌러서 말하기·빠른 입력으로 보내는 요청에 적용돼요. 작업 중이 아니면 어느 방식이든 바로 시작해요. |
| `settings.dispatch.steer.detail` | 현재 턴에 전달해 진행 방향을 조정해요. | 작업이 끝나기 전에 요청을 전달해 진행 방향을 조정해요. |
| `settings.field.agentsFile.note` | 메인 에이전트 작업 폴더의 AGENTS.md를 직접 편집해서 Picky 페르소나와 Pickle 라우팅 규칙을 바꿔요. Pi가 매 턴마다 이 파일을 읽으며, 세션 중에 적용하려면 Picky를 초기화하거나 재시작해주세요. | Picky 작업 폴더의 AGENTS.md에서 말투와 Pickle 작업 배분 지침을 편집해요. 현재 대화에 변경사항을 적용하려면 Picky 대화를 초기화하거나 앱을 재시작해 주세요. |
| `settings.field.armedPickleDispatchMode` | Armed Pickle 전달 방식 | 입력 대상 Pickle에 전달하는 방식 |
| `settings.field.armedPickleDispatchMode.note` | Armed Pickle로 보내는 PTT와 Quick Input을 follow-up으로 기다리게 할지, steer로 현재 턴에 끼어들게 할지 선택해요. idle 상태의 Pickle은 어느 쪽이든 바로 시작돼요. | 전달 대상으로 지정한 Pickle에 음성이나 빠른 입력을 보낼 때, 응답이 끝날 때까지 기다릴지 작업 중에 전달할지 선택해요. 작업 중이 아니면 바로 시작해요. |
| `settings.field.attachScreenshotsOnlyWhenInked` | 그렸을 때만 화면 첨부 | 자동 화면 전송 제한 |
| `settings.field.attachScreenshotsOnlyWhenInked.note` | 켜면 클릭&amp;드래그로 화면에 표시한 부분이 있을 때만 스크린샷을 모델로 전달해요. 화면 캡처 자체는 잉크 오버레이 때문에 계속 동작하고, 모델로 보내는 단계만 건너뛰어요. | 켜면 표시한 화면만 자동으로 보내요. 직접 포함한 화면은 표시하지 않아도 전송돼요. 그리기용 화면 캡처는 Mac에서 계속돼요. |
| `settings.field.defaultCwd` | 기본 작업 폴더 | 기본 작업 폴더 |
| `settings.field.dockSize.mediumNote` | M이 현재 Pickle 도크 크기와 같아요. | M은 기본 도크 크기예요. |
| `settings.field.piModel.helpText` | Pi 설정을 따르려면 Automatic을 선택하고, Picky에 고정하려면 모델을 고르세요. 아래의 추론 레벨은 고정 모델과 함께 적용돼요. | Pi 설정을 따르려면 자동을 선택하고, 특정 모델을 사용하려면 목록에서 고르세요. 아래 추론 수준은 선택한 모델과 함께 적용돼요. |
| `settings.field.pickyCwd` | Picky 작업 폴더 | Picky 작업 폴더 |
| `settings.field.pickyCwd.workspaceWarning` | Picky의 기본 작업 폴더에는 Picky가 알아야 하는 지침들이 `AGENTS.md`로 작성되어 있어요. 작업 폴더를 옮길 경우 해당 지침도 함께 옮기시는 것을 권장드려요. Picky가 가진 도구들을 제대로 호출하지 못할 수 있어요. | AGENTS.md에 직접 작성한 지침이 있다면 새 작업 폴더에도 복사해 주세요. |
| `settings.field.reasoningLevel` | 추론 레벨 | 추론 수준 |
| `settings.field.reasoningLevel.pickleNote` | 새로 생성되는 Pickle의 초기 추론 레벨로만 사용돼요. 실행 중인 Pickle은 독립적으로 변경할 수 있어요. | 새 Pickle의 초기 추론 수준으로 사용해요. 실행 중인 Pickle은 각각 변경할 수 있어요. |
| `settings.field.screenContext` | 화면 컨텍스트 | 화면 정보 |
| `settings.general.language.note` | macOS가 관리하는 영역(앱 메뉴, 시스템 다이얼로그 등)은 다음 실행부터 적용돼요. 그 외 영역은 즉시 변경돼요. | 앱 메뉴와 시스템 대화상자 등 일부 macOS 화면은 다음 실행부터 적용돼요. 나머지는 바로 바뀌어요. |
| `settings.general.subtitle.section` | 앱 전체 설정이에요. 새 언어 추가는 한 줄 코드 변경과 카탈로그 항목만 추가하면 돼요. | 앱 언어와 공통 설정을 변경해요. |
| `settings.mainAgent.summary.capture` | 켜면 그린 화면만 모델에 보내요. 화면 캡처는 계속돼요. | 켜면 표시하거나 직접 포함한 화면을 보낼 수 있어요. 화면 캡처는 계속돼요. |
| `settings.mainAgent.summary.dispatch` | PTT·Quick Input에 적용돼요. 작업 중이 아니면 두 방식 모두 바로 시작돼요. | 눌러서 말하기·빠른 입력에 적용돼요. 작업 중이 아니면 두 방식 모두 바로 시작해요. |
| `settings.mainAgent.summary.instructions` | 행동·도구 지침을 편집해요. 현재 세션에는 초기화 또는 재시작 후 반영돼요. | 행동·도구 지침을 편집해요. 현재 대화에는 대화 초기화 또는 앱 재시작 후 반영돼요. |
| `settings.mainAgent.summary.model` | Pi 기본값을 따르거나 모델과 추론 레벨을 고정해요. | Pi 기본값을 따르거나 모델과 추론 수준을 지정해요. |
| `settings.mainAgent.warning.workspace` | 작업 폴더를 옮길 때 AGENTS.md도 함께 옮겨주세요. 지침이 없으면 도구 호출이 실패할 수 있어요. | AGENTS.md의 사용자 지침도 새 작업 폴더에 복사해 주세요. |
| `settings.notification.toggle.newPickles.note` | 새 피클에만 적용돼요. 기존 피클은 현재 완료 알림 설정을 유지해요. | 새 Pickle에만 적용돼요. 기존 Pickle의 완료 알림 설정은 바뀌지 않아요. |
| `settings.notification.toggle.newPicklesMacOS` | 새 피클 완료 시 macOS 알림 | 새 Pickle 완료 시 macOS 알림 |
| `settings.notification.toggle.newPicklesMain` | 새 피클 완료 시 Main Picky에 보고 | 새 Pickle 완료 시 Picky에 보고 |
| `settings.oauth.body` | 아래 버튼으로 브라우저에서 Pi OAuth 로그인을 시작해요. Picky는 자격 증명을 직접 저장하지 않고, Pi의 로컬 auth storage에 기록합니다. | 아래 버튼으로 브라우저에서 AI 서비스에 로그인해요. 로그인 정보는 Pi의 로컬 인증 저장소에 저장돼요. |
| `settings.oauth.fallback` | 브라우저 콜백이 완료되지 않으면 `pi /login`을 실행한 뒤 같은 provider를 선택해 Pi의 수동 fallback을 사용하세요. | 브라우저에서 로그인이 완료되지 않으면 `pi /login`을 실행하고 같은 서비스를 선택해 수동으로 로그인해 주세요. |
| `settings.oauth.provider.anthropic.subtitle` | Anthropic 모델용 Claude Pro/Max OAuth provider. | Claude Pro/Max 구독으로 Anthropic 모델을 사용해요. |
| `settings.oauth.provider.openai.subtitle` | ChatGPT Plus/Pro Codex 구독 provider. | ChatGPT Plus/Pro 구독으로 Codex를 사용해요. |
| `settings.oauth.status.signingIn` | 브라우저 대기 중… | 브라우저에서 로그인하는 중… |
| `settings.oauth.status.stored` | Pi auth | Pi에 로그인 정보 저장됨 |
| `settings.oauth.subtitle.index` | Pi OAuth provider에 로그인합니다. | AI 서비스 계정에 로그인해요. |
| `settings.oauth.subtitle.section` | Pi와 Picky 기능에서 사용하는 provider 계정을 연결합니다. | Pi와 Picky에서 사용할 AI 서비스 계정을 연결해요. |
| `settings.oauth.summary.none` | 연결된 provider 없음 | 연결된 계정 없음 |
| `settings.oauth.title` | OAuth | 계정 연결 |
| `settings.overlayAndNotifications.subgroup.bubbles` | 버블 | 말풍선 |
| `settings.pickle.archive.toggle` | 보관된 세션 | 보관된 Pickle |
| `settings.pickle.gitChipActions.title` | Git 칩 액션 | Git 정보 클릭 동작 |
| `settings.section.builtinTools.note` | 변경 즉시 메인 에이전트에 적용되며, 진행 중이던 turn은 중단돼요. 항목을 끄면 에이전트가 해당 기능을 사용할 수 없어요. | 변경사항은 Picky에 적용돼요. 도구에 따라 현재 응답이 중단되거나 다음 요청부터 적용돼요. |
| `settings.section.cursorBubbles.subtitle` | Pi 커서 가시성, 작은 애니메이션, 말풍선. | Picky 커서, 애니메이션, 말풍선을 설정해요. |
| `settings.section.cursorBubbles.title` | 커서 &amp; 말풍선 | 커서와 말풍선 |
| `settings.section.feedback.subtitle` | 버그·아이디어·하고 싶은 말 무엇이든. | 문제나 아이디어를 개발자에게 보내 주세요. |
| `settings.section.notification.subtitle` | 세션 이벤트에 대한 배너 알림. | 작업 완료·실패·입력 요청을 알려줘요. |
| `settings.section.onboarding.body` | Picky를 다음에 실행하면 데모를 다시 보여줘요. 실제 LLM 호출은 없어요. | Picky를 다음에 실행하면 사용 안내 데모를 다시 보여줘요. AI 모델을 실제로 호출하지 않아요. |
| `settings.section.onboarding.replay` | 다음 실행 시 온보딩 다시 재생 | 다음 실행 시 사용 안내 다시 보기 |
| `settings.section.onboarding.subtitle` | 인터랙티브 인트로 데모를 다시 재생해요. | 기능을 직접 체험하는 사용 안내를 다시 봐요. |
| `settings.section.onboarding.title` | 온보딩 | 사용 안내 |
| `settings.section.overlayAndNotifications.subtitle` | 커서, 음성 버블, macOS 배너 알림. | 커서, 말풍선, macOS 배너 알림을 설정해요. |
| `settings.section.picky.subtitle` | 런타임, 작업 폴더, 추론, 캡처 컨텍스트. | 작업 폴더, 모델과 추론, 화면 전송을 설정해요. |
| `settings.section.shortcuts.subtitle` | 눌러서 말하기와 퀵 인풋 단축키 바인딩. | 눌러서 말하기와 빠른 입력 단축키를 설정해요. |
| `settings.section.voice.title` | 음성 (STT &amp; TTS) | 음성 인식·읽어주기 |
| `settings.shortcuts.pushToTalk.subtitle` | 누르고 있으면 음성 세션이 시작되고, 떼면 전송돼요. | 누른 채로 말하고, 손을 떼면 전송돼요. |
| `settings.shortcuts.quickInput.title` | 퀵 인풋 | 빠른 입력 |
| `settings.summary.cursorBubbles` | %@ · 버블 %lld / %lld개 | %@ · 말풍선 %lld / %lld개 |
| `settings.summary.pickle` | %@ · 독 %@ | %@ · 도크 %@ |
| `settings.summary.shortcuts` | PTT %@ · 퀵 입력 %@ · 열기 %@ | 음성 %@ · 빠른 입력 %@ · 열기 %@ |
| `settings.tts.disabledNote` | 이 옵션을 끌 수 있으며, Picky의 텍스트 응답은 소리 없이 그대로 표시돼요. | 끄면 응답을 소리 내어 읽지 않아요. 텍스트 표시는 응답 텍스트 설정을 따라요. |
| `settings.voice.azure.tts.apiKey.placeholder` | 비워두면 STT API 키를 재사용합니다 | 비워두면 STT API 키를 재사용해요 |
| `settings.voice.azure.tts.url` | Azure TTS speech URL | Azure TTS 음성 생성 URL |
| `settings.voice.edge.disclosure` | 음성 응답 텍스트가 Microsoft Edge Read Aloud로 전송됩니다. 비공식 온라인 서비스이므로 변경되거나 사용할 수 없게 될 수 있습니다. | 읽어줄 응답 텍스트를 Microsoft Edge Read Aloud로 보내요. 비공식 온라인 서비스라서 변경되거나 중단될 수 있어요. |
| `settings.voice.elevenlabs.tts.outputFormat` | ElevenLabs TTS 출력 포맷 | ElevenLabs TTS 출력 형식 |
| `settings.voice.elevenlabs.tts.voiceId` | ElevenLabs TTS 보이스 ID | ElevenLabs TTS 음성 ID |
| `settings.voice.openaiBaseUrlNote` | OpenAI 호환 base URL을 사용하면 로컬 프록시(LocalAI, openai-edge-tts, Together 등)로 Picky를 연결할 수 있어요. Picky는 표준 /v1/audio/transcriptions 프로토콜을 사용하며, 프록시 안정성은 사용자가 책임져야 해요. | OpenAI 호환 서비스나 프록시 주소를 입력할 수 있어요. 음성 인식은 /v1/audio/transcriptions API를 사용해요. 연결할 서비스가 이 API를 지원하는지 확인해 주세요. |
| `settings.voice.provider.stt` | STT 제공자 | 음성 인식 서비스 |
| `settings.voice.provider.tts` | TTS 제공자 | 음성 생성 서비스 |
| `speech.edge.error.connectionUnavailable` | Picky의 로컬 Edge TTS 연결을 사용할 수 없습니다. | Edge 음성 재생을 위한 Picky 연결 정보를 사용할 수 없어요. |
| `speech.edge.error.emptyResponse` | Picky의 로컬 Edge TTS 서비스가 비어 있는 오디오를 반환했습니다. | Edge 음성 서비스에서 재생할 오디오를 받지 못했어요. |
| `speech.edge.error.http` | Picky의 로컬 Edge TTS 서비스가 HTTP %lld 오류로 실패했습니다. | Edge 음성 서비스에서 HTTP %lld 오류가 발생했어요. |
| `speech.edge.error.insecureConnection` | Picky의 로컬 Edge TTS 연결 파일 권한이 안전하지 않습니다. | Picky 연결 파일의 접근 권한이 안전하지 않아 Edge 음성을 재생할 수 없어요. |
| `status.captures.screenshots` | 단축키를 사용할 때만 스크린샷을 찍어요 | 요청에 참고할 화면을 캡처해요. 전송 조건은 설정에서 바꿀 수 있어요. |
| `status.captures.text` | 가능하면 선택한 텍스트와 브라우저 컨텍스트도 가져와요 | 가능하면 선택한 텍스트와 브라우저 정보도 가져와요 |
| `status.extensions.pickyCLI.description` | 로컬 Picky CLI로 Picky에 메시지를 보내고, Pickle을 만들고, push-to-talk를 제어하는 가이드를 Pi에 추가해요. | 로컬 Picky CLI로 메시지를 보내고, Pickle을 만들고, 눌러서 말하기를 제어하는 가이드를 Pi에 추가해요. |
| `status.extensions.pickyHandoff.description` | 로컬 Pi에 /handoff-to-picky 명령을 추가해요. Pi 세션을 Picky의 완료된 Pickle 카드로 옮길 수 있어요. | 로컬 Pi에 /handoff-to-picky 명령을 추가해요. 작업 중인 대화는 새 Pickle에서 이어가고, 작업 중이 아닌 대화는 완료된 Pickle로 표시해요. |
| `status.extensions.pickyHandoff.title` | Pi handoff 명령 | Pi 대화 가져오기 명령 |
| `status.extensions.reload.banner.button` | Reload | 다시 불러오기 |
| `status.extensions.reload.banner.message` | Reload 후에 적용됩니다. | 플러그인 변경사항은 다시 불러온 뒤 적용돼요. |
| `status.extensions.reload.banner.title` | Reload 필요 | 다시 불러오기 필요 |
| `status.extensions.reload.confirm.message.both` | 동작 중인 피클 %lld개가 중단되고, 발화 중인 메인 Picky 세션의 응답이 끊깁니다. 압축 중인 세션은 압축이 끝나면 자동으로 reload돼요. | 진행 중인 Pickle 작업 %lld개와 Picky의 현재 응답이 중단돼요. 대화 기록을 정리 중인 Pickle은 정리가 끝나면 자동으로 다시 불러와요. |
| `status.extensions.reload.confirm.message.generic` | Reload 하시겠어요? | 플러그인을 다시 불러올까요? |
| `status.extensions.reload.confirm.message.main` | 발화 중인 메인 Picky 세션의 응답이 끊깁니다. | Picky의 현재 응답이 중단돼요. |
| `status.extensions.reload.confirm.message.pickles` | 동작 중인 피클 %lld개가 중단됩니다. 압축 중인 세션은 압축이 끝나면 자동으로 reload돼요. | 진행 중인 Pickle 작업 %lld개가 중단돼요. 대화 기록을 정리 중인 Pickle은 정리가 끝나면 자동으로 다시 불러와요. |
| `status.extensions.reload.confirm.proceed` | Reload | 다시 불러오기 |
| `status.extensions.reload.confirm.title` | 전체 세션을 Reload할까요? | 모든 대화에서 플러그인을 다시 불러올까요? |
| `status.extensions.reload.error.disconnected` | agentd 연결이 끊겨 Reload가 중단됐어요. | 로컬 에이전트 연결이 끊겨 다시 불러오기를 중단했어요. |
| `status.extensions.reload.error.timeout` | Reload 응답이 늦어요. 잠시 후 다시 시도해주세요. | 다시 불러오기 응답이 늦어요. 잠시 후 다시 시도해 주세요. |
| `status.extensions.reload.result.nothing` | Reload할 항목이 없어요. | 다시 불러올 항목이 없어요. |
| `status.extensions.reload.result.pickleAborted` | 동작 중 %lld개 중단 | 진행 중인 작업 %lld개 중단 |
| `status.extensions.reload.result.pickleDeferred` | 압축 중 %lld개는 압축 뒤 reload 예정 | Pickle %lld개는 대화 기록 정리 후 적용 |
| `status.extensions.reload.result.pickleReloaded` | 피클 %lld개 reload | Pickle %lld개 다시 불러옴 |
| `status.extensions.state.legacySymlink` | 이전 방식 설치 — 다시 설치하면 안전한 복사본으로 마이그레이션돼요. | 이전 방식으로 설치됐어요. 다시 설치하면 복사본으로 바뀌어요. |
| `status.feedback.subtitle` | 버그·아이디어·하고 싶은 말 무엇이든. | 문제나 아이디어를 개발자에게 보내 주세요. |
| `status.shellCommand.stale.title` | `picky` 명령이 다른 Picky.app 을 가리키고 있어요 | `picky` 명령이 다른 Picky.app을 가리키고 있어요 |
| `status.voice.listening.subtitle` | 말하는 동안 Control+Option을 계속 누르고 있어주세요. | 말하는 동안 눌러서 말하기 단축키를 계속 누르고 있어 주세요. |
| `status.voice.processing.subtitle` | Pi에게 필요한 만큼만 컨텍스트를 모으고 있어요. | 말씀하신 내용을 처리하거나 AI 응답을 기다리고 있어요. |
| `status.voice.processing.title` | 컨텍스트를 준비하고 있어요… | 요청을 처리하고 있어요… |

</details>

<details>
<summary>영어 before/after (408개 키)</summary>

| 식별자 | Before | After |
|---|---|---|
| `dictation.noSpeech` | No speech detected. Press and hold the button a little longer while speaking. | No speech detected. Start voice input and try speaking again. |
| `directMessage.followUpDelivered` | Queued the follow-up message for the selected Pickle. | Added the follow-up message to the selected Pickle’s queue. |
| `dock.contextMenu.archive` | Archive | Archive |
| `dock.contextMenu.pinInput` | Pin Picky Input to This Pickle | Pin Picky Input to This Pickle |
| `dock.contextMenu.sendNextInput` | Send Next Picky Input to This Pickle | Send Next Picky Input to This Pickle |
| `dock.drag.archive.label` | Archive | Archive |
| `dock.recentFolders.empty` | No recent folders yet. Choose a working folder to start your first Pickle. | No recent working folders. Choose a folder to start a Pickle. |
| `dock.recentFolders.newGroup.hint` | Create a dock group with a name and optional initial Pickles | Name the group and optionally add Pickles |
| `dock.recentFolders.pin.hint` | Keep this folder at the top of the picker | Keep this folder at the top of the picker |
| `dock.recentFolders.remove.hint` | This does not delete the folder | This does not delete the folder |
| `dock.recentFolders.reorder.hint` | Drag to reorder pinned folders | Drag to reorder pinned folders |
| `dock.recentFolders.unpin.hint` | Move this folder back to recent folders | Move this folder back to recent folders |
| `dock.startPickle` | Start Pickle | Start Pickle |
| `dock.startPickleIn` | Start Pickle in %@ | Start Pickle in %@ |
| `enum.armedPickleDispatchMode.followUp` | Follow-up | After current response |
| `enum.armedPickleDispatchMode.steer` | Steer | During current work |
| `error.directMessage.contextEmpty` | Couldn’t send message: Context capture returned no packet. | Could not capture screen or task context for this message. Try sending your request again. |
| `error.directMessage.startFailed` | Couldn’t start a new message session: %@ | Couldn’t start a new conversation: %@ |
| `extensions.cron.action.setupDaemon` | Set up daemon | Set up background scheduling |
| `extensions.cron.jobs.back` | Extensions | Plugins |
| `extensions.cron.jobs.missing.description` | Set up the Cron daemon or create a job in Pi, then refresh this page. | Set up Cron’s background service or create a job in Pi, then refresh this page. |
| `extensions.cron.jobs.unreadable.description` | Check the Cron job store permissions, then reload. | Check the Cron job store permissions, then refresh. |
| `extensions.cron.remove.confirm.message` | Picky will run Cron uninstall, verify that the macOS LaunchAgent is unloaded, and only then remove the npm package. | Picky will stop and uninstall the Cron background service, verify that it has stopped, then remove the plugin. |
| `extensions.cron.remove.confirm.title` | Remove Cron and its daemon? | Remove Cron and its background service? |
| `extensions.curated.askUserQuestion.description` | Ask structured radio, checkbox, and text questions in one form when Pi needs clarification. | Ask structured radio, checkbox, and text questions in one form when Pi needs clarification. |
| `extensions.curated.autoName.description` | Automatically name Pi sessions from the first user message so many open tasks stay easy to recognize. | Automatically name Pi sessions from the first user message so many open tasks stay easy to recognize. |
| `extensions.curated.comingSoon` | Coming soon — a curated list of useful Picky plugins will appear here. | Useful Picky plugins will be listed here. |
| `extensions.curated.cron.description` | Schedule local Pi jobs. Install and update configure a persistent macOS LaunchAgent; removing Cron also removes that daemon. | Schedule local Pi jobs using a macOS background service. Installing Cron sets up the service; removing Cron removes it too. |
| `extensions.curated.delayedAction.description` | Schedule delayed follow-up prompts with `/delay` or the `delay` tool. | Schedule delayed follow-up prompts with `/delay` or the `delay` tool. |
| `extensions.curated.heading` | Curated plugins | Recommended plugins |
| `extensions.curated.memoryLayer.description` | Save, recall, list, and forget durable local memories that Pi can reuse across sessions. | Save, recall, list, and forget durable local memories that Pi can reuse across sessions. |
| `extensions.curated.subagent.description` | Delegate coding and research tasks to asynchronous subagents with run, batch, and chain workflows. | Delegate coding and research tasks to asynchronous subagents with run, batch, and chain workflows. |
| `extensions.curated.todoWriteOverlay.description` | Create and update structured session todos with the `todo_write` tool and track progress in a passive top-right overlay. | Create and update structured session todos with the `todo_write` tool and track progress in a passive top-right overlay. |
| `feedback.sendFailure.diagnostics` | Couldn’t prepare the diagnostics bundle. Try again without diagnostics. | Couldn’t prepare diagnostic files. Turn off diagnostics and try again. |
| `feedback.sent` | Sent — thanks! | Sent. Thank you! |
| `footer.dock.hide` | Hide Dock | Hide Dock |
| `footer.dock.show` | Show Dock | Show Dock |
| `footer.quit.body` | Picky will stop running in the menu bar and ongoing local sessions may be interrupted. | Picky will quit and leave the menu bar. Ongoing work may be interrupted. |
| `footer.restart.body` | Picky will quit and reopen so restart-required settings can take effect. Ongoing local sessions may be interrupted. | Picky will quit and reopen to apply settings that require a restart. Ongoing work may be interrupted. |
| `group.delete.confirm.archive` | Archive Pickles | Archive Pickles |
| `group.delete.confirm.message` | All Pickles inside this group will be archived. You can restore them from the archive list. | All Pickles inside this group will be archived. You can restore them from the archive list. |
| `group.delete.confirm.title` | Delete "%@" and archive its Pickles? | Delete "%@" and archive its Pickles? |
| `group.folder.accessibility.value` | %1$lld Pickles, %2$lld unread | %1$lld Pickles, %2$lld unread |
| `group.list.accessibility.label` | %1$@, %2$lld Pickles | %1$@, %2$lld Pickles |
| `group.list.action.archive` | Archive | Archive |
| `group.list.fallbackTitle` | Pickle | Pickle |
| `group.list.newPickle.accessibilityLabel` | Create Pickle in group | Create Pickle in group |
| `group.list.newPickle.hint` | Create a Pickle in this group | Create a Pickle in this group |
| `group.list.status.blocked` | Blocked | Unable to continue |
| `group.menu.delete` | Delete group + archive pickles | Delete group and archive Pickles |
| `group.menu.ungroup` | Ungroup (keep pickles) | Ungroup (keep Pickles) |
| `hub.appearance.dark` | Dark appearance | Dark appearance |
| `hub.appearance.light` | Light appearance | Light appearance |
| `hub.calendar.estimated` | Projected | Estimated |
| `hub.calendar.estimatedLegend` | Dashed · projected | Dashed · estimated |
| `hub.calendar.history.note` | Past events show only the latest recorded run, not full history. Dashed markers are estimates using this Mac’s timezone, as Cron does. | Past events show available execution records. Dashed markers estimate future runs using this Mac’s timezone, as Cron does. |
| `hub.calendar.historyTruncated` | Only some execution records were read. Switch to week view to narrow the range. | Only some execution records were read. Switch to week view to narrow the range. |
| `hub.calendar.install.action` | Install Cron | Install scheduling (Cron) |
| `hub.calendar.install.note` | You will be notified if changes need applying. Running work is not interrupted automatically. | You will be notified if changes need applying. Running work is not interrupted automatically. |
| `hub.calendar.install.title` | Install Cron to use the calendar | Install scheduling to view scheduled tasks |
| `hub.calendar.noOccurrences` | No occurrences in this period. | No occurrences in this period. |
| `hub.calendar.projected` | Projected occurrence | Estimated run time |
| `hub.calendar.promptMissing` | The registered instructions file could not be found. | The registered instructions file could not be found. |
| `hub.calendar.promptTooLarge` | The instructions file is too large to display. | The instructions file is too large to display. |
| `hub.calendar.promptUnreadable` | The instructions file could not be read. | The instructions file could not be read. |
| `hub.calendar.promptUnsafe` | Files outside the Cron folder and symbolic links are not opened. | Files outside the Cron folder and symbolic links are not opened. |
| `hub.calendar.scheduleTimezone` | Stored timezone (not used by Cron): %@ | Stored timezone (Cron uses this Mac’s timezone): %@ |
| `hub.calendar.truncated` | Only some occurrences are shown. Use week view or filters to narrow the range. | Only some occurrences are shown. Use week view or filters to narrow the range. |
| `hub.calendar.unsupported.message` | Check your plugin and Picky versions. The schedule file has not been changed. | Check your plugin and Picky versions. The schedule file has not been changed. |
| `hub.calendar.unsupportedRules` | Some recurrence rules cannot be previewed. Only recorded next runs and latest results are shown for those jobs. | Some recurrence rules cannot be previewed. Only recorded next runs and available execution records are shown for those jobs. |
| `hub.conversation.composer.hint` | Press Return to send. Press Shift-Return for a new line. | Press Return to send. Press Shift-Return for a new line. |
| `hub.conversation.newSession` | New session | New conversation |
| `hub.dashboard.guides.empty` | Guides will appear here in the next app update. | No guides to show yet. |
| `hub.dashboard.insight.classifying` | Classifying work | No classified work yet |
| `hub.dashboard.insight.classifyingCount` | Classifying %lld Pickles | %lld unclassified Pickles |
| `hub.dashboard.insight.deepestPickle` | Deepest Pickle | Most follow-ups and delegations |
| `hub.dashboard.insight.delegationCount` | %lld delegations | %lld delegations |
| `hub.dashboard.insight.focusedProject` | Most focused project | Project with the most Pickles |
| `hub.dashboard.insight.followUpCount` | %lld follow-ups | %lld follow-ups |
| `hub.dashboard.plugins.empty` | Recommended plugins are loading. | No recommended plugins to show. |
| `hub.dashboard.share.title` | Share Picky | Share Picky |
| `hub.guides.empty.message` | New guides and product updates will appear here with your next Picky update. | Guides and product updates will appear here when available. |
| `hub.guides.video.error.message` | Check your connection, then try again or open the video on YouTube. | Check your internet connection, then try again or open the video on YouTube. |
| `hub.menu.appearance` | Appearance | Appearance |
| `hub.page.dashboard.subtitle` | Look back, discover, and start your next task. | Review your work and start a new task. |
| `hub.page.quickStart.subtitle` | Start a new Pickle from a ready-made flow. | Choose a task to start a new Pickle. |
| `hub.plugins.card.setupDaemon` | Set up daemon | Set up background scheduling |
| `hub.plugins.card.viewJobs` | View jobs | View scheduled jobs |
| `hub.plugins.detail.remove.prompt` | Remove this plugin? | Remove this plugin? |
| `hub.plugins.feedback.installed` | Installed %1$@. | Installed %1$@. |
| `hub.plugins.feedback.removed` | Removed %1$@. | Removed %1$@. |
| `hub.plugins.feedback.settingUp` | Setting up the Cron daemon… | Setting up background scheduling… |
| `hub.plugins.feedback.setup` | %@ daemon setup verified. | %@ background scheduling setup verified. |
| `hub.plugins.feedback.updated` | Updated %1$@. | Updated %1$@. |
| `hub.plugins.reload.confirm.message.both` | This will interrupt Picky and %lld active Pickle(s). | This may interrupt the Picky conversation and %lld active Pickle(s). |
| `hub.plugins.reload.confirm.message.main` | This will interrupt Picky's active voice work. | This may interrupt Picky's active voice work. |
| `hub.plugins.reload.confirm.message.pickles` | This will interrupt %lld active Pickle(s). | This may interrupt %lld active Pickle(s). |
| `hub.plugins.reload.message` | Reload Picky and active Pickles to use the changed plugins. | Reload the Picky conversation and open Pickles to apply plugin changes. |
| `hub.plugins.reload.title` | Reload to apply plugin changes | Apply plugin changes |
| `hub.plugins.useCase.cron.2` | Automating a repeated report without opening Picky | Automating recurring reports on a schedule |
| `hub.plugins.useCase.memoryLayer.1` | Keeping project rules across sessions | Keeping project rules across sessions |
| `hub.plugins.useCase.subagent.1` | Splitting a large task into parallel workers | Splitting a large task among multiple agents |
| `hub.quickStart.chooseWorkflow` | Choose a workflow | Choose a task |
| `hub.quickStart.error.notProjected` | The new Pickle did not appear in time. Check that picky-agentd is running and try again. | The new Pickle is taking longer than expected to appear. Try again. |
| `hub.quickStart.footer` | Starting a workflow opens a new Pickle. Pi asks for what it needs one question at a time, and you can continue in the same Pickle later. | Starting a task opens a new Pickle. It asks for the details it needs one question at a time. You can return to the same Pickle later. |
| `hub.quickStart.resume.pending` | First instruction not confirmed. Open this Pickle to check before sending again. | The first instruction has not been confirmed. Open this Pickle to check before sending again. |
| `hub.quickStart.starting` | Starting %@ workflow | Starting %@ |
| `hub.quickStart.success.message` | A new task is open. Pi is preparing the first question. | A new Pickle is open and preparing the first question. |
| `hub.quickStart.success.showWorkflows` | View other workflows | View other tasks |
| `hub.quickStart.workflow.files.description` | Tidy a local folder according to the rules you choose. | Tidy a local folder according to the rules you choose. |
| `hub.quickStart.workflow.guide.description` | Learn the app you're using, one step at a time, with Picky. | Learn the app you're using, one step at a time, with Picky. |
| `hub.quickStart.workflow.landing.description` | A Q&amp;A-driven flow that builds a web page introducing your product or service. | Answer a few questions to build a web page for your product or service. |
| `hub.quickStart.workflow.native.description` | Shape a native app that runs locally, through conversation. | Shape a native app that runs locally, through conversation. |
| `hub.settings.appearance.detail` | Choose the light or dark appearance for Picky. | Choose the light or dark appearance for Picky. |
| `hub.settings.autoUpdates.detail` | Periodically check for a new Picky version. | Periodically check for a new Picky version. |
| `hub.settings.checkUpdates.detail` | Look for an available update now. | Look for an available update now. |
| `hub.settings.classification.accessibilityHint` | Requires a confirmed statistics snapshot before it can change. | Available after statistics have loaded. |
| `hub.settings.classification.detail` | Optional. Off by default. | Optional. Off by default. |
| `hub.settings.classification.disclosure` | When enabled, Picky sends each eligible Pickle's title, up to five short user-message excerpts, tool names and counts, activity counts, changed-file count, and subagent count to an authenticated model provider allowed by your configured model scope. This may use your model quota or incur provider costs. When off, new work is not sent for classification. Existing classifications and local statistics are retained. | When enabled, Picky sends each eligible Pickle's title, up to five short user-message excerpts, tool names and counts, activity counts, changed-file count, and subagent count to an authenticated model provider allowed by your configured model scope. This may use your model quota or incur provider costs. When off, new work is not sent for classification. Existing classifications and local statistics are retained. |
| `hub.settings.classification.title` | Model work classification | AI work classification |
| `hub.settings.fontScale.detail` | Adjust the size used across Picky. | Adjust the size used across Picky. |
| `hub.settings.group.general.subtitle` | Language, appearance, and updates | Language, appearance, and updates |
| `hub.settings.notification.detail` | Choose when Picky should notify you. | Choose when Picky should notify you. |
| `hub.settings.onboarding` | Replay onboarding | Replay setup guide |
| `hub.settings.onboarding.detail` | Start the first-use guide again. | Start the first-use guide again. |
| `hub.settings.onboarding.dialog.message` | Your onboarding progress will return to the first step. | Start the guide now from the beginning. Push to Talk and Quick Input are unavailable during the demo. |
| `hub.settings.onboarding.dialog.title` | Replay onboarding? | Replay setup guide? |
| `hub.settings.permission.detail` | Manage this permission in System Settings. | Manage this permission in System Settings. |
| `hub.settings.pinnedFolders.detail` | Folders kept at the top of the Pickle folder picker. | Folders kept at the top of the Pickle folder picker. |
| `hub.settings.privacy.notice` | Conversations, Pickle history, and settings stay on this Mac by default. When you use an AI or voice provider, the selected request text, audio, or screen context may be sent to that provider. | Conversations, Pickle history, and settings stay on this Mac by default. When you use an AI or voice provider, the selected request text, audio, or screen context may be sent to that provider. |
| `hub.settings.recentFolders.detail` | Folders recently used to start a Pickle. | Folders recently used to start a Pickle. |
| `hub.settings.reportFontScale.detail` | Applies to generated report windows. | Applies to generated report windows. |
| `hub.settings.restart.message` | Restart Picky to apply these changes. | Restart Picky to apply these changes. |
| `hub.settings.shellCommand` | Shell command tool | Manage picky command |
| `hub.settings.shellCommand.detail` | Install or reinstall Picky’s command-line helper. | Install, reinstall, or remove the picky command used in Terminal. |
| `hub.settings.statisticsReset` | Reset statistics data | Reset work classifications |
| `hub.settings.statisticsReset.action` | Reset statistics | Reset classifications |
| `hub.settings.statisticsReset.detail` | Remove saved statistics classifications. This cannot be undone. | Delete saved classifications. With AI work classification on, Pickles may be classified again. Work records and AI usage remain. |
| `hub.settings.statisticsReset.dialog.confirm` | Reset statistics | Reset classifications |
| `hub.settings.statisticsReset.dialog.message` | Saved statistics classifications will be removed and cannot be restored. | Saved work classifications will be deleted. If AI work classification is on, eligible Pickles may be classified again. Work records, AI usage, and classification settings will remain. |
| `hub.settings.statisticsReset.dialog.title` | Reset statistics data? | Reset work classifications? |
| `hub.settings.statisticsReset.pending` | Resetting statistics… | Resetting work classifications… |
| `hub.settings.statisticsReset.success` | Statistics data was reset. | Work classifications were reset. |
| `hub.settings.terminalFontScale.detail` | Applies to command and tool output. | Applies to command and tool output. |
| `hub.settings.updateChannel.detail` | Choose stable or preview updates. | Choose stable or preview updates. |
| `hub.settings.watchdog.detail` | Record a diagnostic signal when the app becomes unresponsive. | Record a diagnostic signal when the app becomes unresponsive. |
| `hub.stats.error.disconnected` | Lost the connection to picky-agentd while loading statistics. | The connection was lost while loading statistics. Try again. |
| `hub.stats.usage.costNotice` | We do not estimate costs. Check costs with your connected provider. | We do not estimate costs. Check costs with your connected provider. |
| `hub.stats.usage.empty.message` | Usage from connected providers will appear here. | No AI usage is recorded for this period and project. Recorded usage from Picky tasks appears here when available. |
| `hub.stats.work.classifying` | %lld Pickles are still being classified. | %lld Pickles have not been classified. |
| `hub.stats.work.empty.message` | No work records match this period and project. Start something from the dashboard. | No work records match this period and project. Start something from the dashboard. |
| `hub.stats.work.records.caption` | Follow-ups, delegations, and reviews are interaction counts, not completed tasks. | Follow-ups, delegations, and reviews are interaction counts, not completed tasks. |
| `hud.activity.summary.toolsUsed.many` | Used %lld tools | Made %lld tool calls |
| `hud.activity.summary.toolsUsed.one` | Used %lld tool | Made %lld tool call |
| `hud.archiveToast.title` | Session archived | Pickle archived |
| `hud.archivedList.confirmDelete` | Tap again to delete | Click again to delete |
| `hud.archivedList.confirmDeleteAllMessage` | This action cannot be undone. Every archived Pickle is removed from Picky and from the local agent's session store. | Only archived Pickles that have completed, failed, stopped, or cannot continue will be permanently deleted. Running, queued, and input-waiting Pickles will remain. This cannot be undone. |
| `hud.archivedList.confirmDeleteAllTitle` | Permanently delete %lld archived Pickles? | Delete %lld inactive Pickles? |
| `hud.archivedList.deleteAll` | Delete all | Delete inactive Pickles |
| `hud.archivedList.empty` | No archived Pickles. | No archived Pickles. |
| `hud.archivedList.title` | Archived Pickles | Archived Pickles |
| `hud.artifacts.accessibilityLabel` | Session file artifacts | Pickle file artifacts |
| `hud.artifacts.empty` | Files Pi saved with its file-writing tool—documents, data, and images—appear here | Files saved by this Pickle will appear here. |
| `hud.changes.accessibilityLabel` | Session changes | Pickle changes |
| `hud.changes.diffTruncated` | Diff output was truncated | The diff is too long to display in full |
| `hud.changes.empty` | No changes in this view | No changes in this view |
| `hud.changes.error` | Changes error: %@ | Could not load changes: %@ |
| `hud.changes.fileSummary` | %@, %lld additions, %lld deletions | %@, %lld lines added, %lld lines deleted |
| `hud.changes.filesTruncated` | More changed files are not shown | Only some changed files are shown |
| `hud.changes.notGitRepository` | This folder is not a Git repository | This folder is not a Git repository |
| `hud.compact.done.body` | Older context was summarized. The agent can continue with a cleaner transcript. | Older conversation was summarized. The agent will use that summary to continue. |
| `hud.compact.done.title` | Session compacted | Conversation compacted |
| `hud.composer.placeholder.compacting` | Queue a message for after compaction… | Message to send after compaction… |
| `hud.composer.placeholder.recovery` | Send a recovery steer or open terminal | Send another request or open Pi terminal |
| `hud.composer.placeholder.resume` | Resume this agent with a steer… | Send a message to resume this task… |
| `hud.composer.placeholder.steer` | Steer this agent · ⌥↵ Follow-up · esc Stop | Guide the current task · ⌥↵ Follow-up · esc Stop |
| `hud.composer.runtime.accessibilityLabel` | Composer runtime controls | Model and thinking settings |
| `hud.composer.runtime.defaultThinking` | Use current thinking level for new Pickles | Use current thinking level for new Pickles |
| `hud.composer.runtime.failed` | Runtime control failed: %@ | Could not change model or thinking settings: %@ |
| `hud.composer.runtime.model.accessibilityHint` | Choose model. Control-P cycles forward and Shift-Control-P cycles backward. | Choose model. Control-P cycles forward and Shift-Control-P cycles backward. |
| `hud.composer.runtime.picker.advancedReadOnly` | This Pi model scope is read-only here because it uses advanced patterns. | This Pi model scope is read-only here because it uses advanced patterns. |
| `hud.composer.runtime.picker.conflict` | The model scope changed elsewhere. Reload the latest scope before applying changes. | The model scope changed elsewhere. Reload the latest scope before applying changes. |
| `hud.composer.runtime.picker.currentOutsideScope` | Current model (%@) is outside this scope. | Current model (%@) is outside this scope. |
| `hud.composer.runtime.picker.empty` | No models available | No models available |
| `hud.composer.runtime.picker.failed` | Could not load models: %@ | Could not load models: %@ |
| `hud.composer.runtime.picker.projectOverride` | This project overrides the global model scope. Global edits will not replace it. | This project uses its own model scope. Global changes do not apply to it. |
| `hud.composer.runtime.picker.unavailableScope` | The model scope is unavailable. Reload and try again. | The model scope is unavailable. Reload and try again. |
| `hud.composer.runtime.thinking.accessibilityHint` | Choose a supported thinking level. Shift-Tab cycles levels. | Choose a supported thinking level. Shift-Tab cycles levels. |
| `hud.composer.send.compacting` | Queue message until compaction completes | Queue message for delivery after compaction |
| `hud.composer.send.steer` | Send steering message | Send guidance to the current task |
| `hud.composer.send.unavailable` | This session cannot accept composer input | Messages cannot be sent to this conversation |
| `hud.composer.steerTarget` | Next Picky screen input will go to this Pickle | The next Picky voice or quick text input goes to this Pickle |
| `hud.composer.stop.help` | Stop this Pickle | Stop this Pickle. Queued text moves to the message field; queued screen images cannot be restored. |
| `hud.composer.submit.steer` | Steer | Steer |
| `hud.context.details.accessibilityHint` | Shows workspace, Git, and links | Shows workspace, Git, and links |
| `hud.context.details.accessibilityLabel` | Context details | Workspace details |
| `hud.contextCompaction.description` | Summarize older conversation to free context space. | Summarize older conversation to free context space. |
| `hud.contextCompaction.title` | Session context | Conversation context |
| `hud.contextCompaction.unavailable` | You can compact after the current turn finishes. | You can compact after the current turn finishes. |
| `hud.conversation.historyStart` | Beginning of the conversation | Beginning of the conversation |
| `hud.conversation.loadMoreTurns` | Show %lld earlier turns · %lld hidden | Show %lld earlier turns · %lld hidden |
| `hud.conversation.loadMoreTurns.help` | Show earlier turns | Show earlier turns |
| `hud.conversation.meta.context.unknown` | Context usage is unknown after compaction until the next model response | Context usage is unknown after compaction until the next model response |
| `hud.conversation.status.blocked` | Blocked | Unable to continue |
| `hud.conversation.turn.collapse.accessibilityHint` | Collapse chapter | Collapse turn |
| `hud.conversation.turn.current.accessibilityLabel` | Current turn | Current turn |
| `hud.conversation.turn.expand.accessibilityHint` | Expand chapter | Expand turn |
| `hud.conversation.turn.latest.accessibilityLabel` | Latest turn | Latest turn |
| `hud.conversation.turn.previous.accessibilityLabel` | Previous turn | Previous turn |
| `hud.conversation.turn.tool.many` | %lld tools | %lld tool calls |
| `hud.conversation.turn.tool.one` | %lld tool | %lld tool call |
| `hud.error.header` | FAILED · runtime error | Request failed |
| `hud.header.archive.accessibilityHint` | Hides the Pickle from the Dock without stopping it. Undo is available for six seconds. | Hides the Pickle from the Dock without stopping it. Undo is available for six seconds. |
| `hud.header.archive.accessibilityLabel` | Archive Pickle | Archive Pickle |
| `hud.header.archive.help` | Archive Pickle (⌘⌫) | Archive Pickle (⌘⌫) |
| `hud.header.close.accessibilityHint` | Closes this card without stopping the Pickle | Closes this card without stopping the Pickle |
| `hud.header.close.accessibilityLabel` | Close Pickle HUD | Close Pickle conversation card |
| `hud.header.close.help` | Close Pickle HUD (Esc or ⌘W) | Close Pickle conversation card (Esc or ⌘W) |
| `hud.header.target.accessibilityLabel` | Session status: %@ | Pickle status: %@ |
| `hud.header.target.armed.accessibilityLabel` | Session status: %@, Pickle cursor armed | Pickle status: %@, next input target |
| `hud.header.target.armed.help` | Pickle cursor is armed. The next Picky voice or quick text input goes directly to this Pickle. Click or press ⌘K to cancel, or long-press to lock. | The next Picky voice or quick text input goes to this Pickle. Click or press ⌘K to cancel. Long-press to keep sending inputs here. |
| `hud.header.target.locked.accessibilityLabel` | Session status: %@, Pickle cursor locked | Pickle status: %@, input target pinned |
| `hud.header.target.locked.help` | Pickle cursor is locked. Every Picky voice or quick text input keeps going to this Pickle until you click again or arm another. Long-press another Pickle to switch. | Picky voice and Quick Input keep going to this Pickle. Click again to unpin, or click another Pickle’s input-target badge to switch. Long-press its badge to pin it. |
| `hud.header.target.route.help` | %@. Click or press ⌘K to route the next Picky screen-context input to this Pickle. Long-press to lock it as the sticky target. | %@. Click or press ⌘K to send the next Picky voice or quick text input here. Long-press to keep sending inputs here. |
| `hud.header.target.voice.accessibilityLabel` | Session status: %@, voice steering target | Pickle status: %@, voice input target |
| `hud.header.target.voice.help` | %@. Voice steering target | %@. Voice input target |
| `hud.inlineTerminal.backToChat.help` | Return to the SwiftUI chat and composer (⌘T) | Return to chat and message input (⌘T) |
| `hud.inlineTerminal.showThisTUI` | Show This TUI | Show This Terminal |
| `hud.inlineTerminal.singleton.body` | Close the active TUI Pickle, or move the TUI screen here. | Choose “Show This Terminal” to move it here. |
| `hud.inlineTerminal.singleton.title` | TUI can only be open in one Pickle at a time. | Pi terminal can only be shown in one Pickle at a time. |
| `hud.inlineTerminal.tab.tui` | TUI | Terminal |
| `hud.liveStep.goToQuestion.accessibilityHint` | Moves keyboard focus to the question | Moves keyboard focus to the question |
| `hud.menu.archive` | Archive | Archive |
| `hud.menu.sessionInfo` | SESSION INFO | Conversation info |
| `hud.menu.showChatUI` | Show chat UI | Show chat |
| `hud.menu.stopSession` | Stop session | Stop task |
| `hud.queue.batch.followUp` | Follow-up batch · all when idle | Follow-up batch · all after the current task |
| `hud.queue.batch.steer` | Steering batch · all next turn | Steering batch · all next turn |
| `hud.queue.clear` | Clear | Delete queued requests |
| `hud.queue.clear.help` | Clear pending work without restoring it to the composer | Delete pending messages without moving them to the message field |
| `hud.queue.pending.steer` | Steer pending | Steer pending |
| `hud.queue.restore` | Restore | Move to input |
| `hud.queue.restore.accessibilityLabel` | Restore queued messages | Move queued messages to the message field |
| `hud.queue.restore.blockedByScreenContext.accessibilityLabel` | Restore queued messages unavailable: %lld attached screen images cannot yet be restored | Restore queued messages unavailable: %lld attached screen images cannot yet be restored |
| `hud.queue.restore.blockedByScreenContext.error` | Restore is unavailable because %lld attached screen images cannot yet be restored | Restore is unavailable because %lld attached screen images cannot yet be restored |
| `hud.queue.restore.blockedByScreenContext.help` | Restore is unavailable because %lld attached screen images cannot yet be restored | Restore is unavailable because %lld attached screen images cannot yet be restored |
| `hud.queue.restore.help` | Restore queued messages to the composer and clear pending work | Move queued messages to the message field and clear the queue |
| `hud.queue.restoring` | Restoring… | Moving to input… |
| `hud.rewind.empty` | No rewindable user messages found. | No rewindable user messages found. |
| `hud.subagent.invocation.batch` | batch ×%lld | batch ×%lld |
| `hud.subagent.invocation.chain` | chain %lld/%lld | chain %lld/%lld |
| `hud.subagent.invocation.run` | run | run |
| `hud.todo.collapse` | Collapse task progress | Collapse task progress |
| `hud.todo.toggle.help` | Expand or collapse task progress | Expand or collapse task progress |
| `hud.toolHistory.argumentsUnavailable` | Original input is not available yet. | Original input is not available yet. |
| `hud.toolHistory.ask.awaiting` | Waiting for an answer in the session. | Waiting for an answer in the conversation. |
| `hud.toolHistory.ask.dismissed` | Closed without a submitted answer. | Closed without a submitted answer. |
| `hud.toolHistory.ask.unavailable` | Structured answers are unavailable. The stored response is shown below. | Answers cannot be displayed by field. The stored response is shown below. |
| `hud.toolHistory.categoryFilter.accessibilityLabel` | %@, %lld calls | %@, %lld calls |
| `hud.toolHistory.detail.attachmentsOmitted` | Image data is omitted. Text and available metadata are shown. | Image data is omitted. Text and available metadata are shown. |
| `hud.toolHistory.detail.failed` | Could not load the original. Check the daemon connection and retry. | Could not load the original. Try again. |
| `hud.toolHistory.detail.pending` | The result has not been saved yet. Try again shortly. | The result has not been saved yet. Try again shortly. |
| `hud.toolHistory.detail.scope` | Stored execution record. Pi may have truncated the original tool output. | Stored execution record. Pi may have truncated the original tool output. |
| `hud.toolHistory.detail.sourceChanged` | The session changed. Close this detail and select a call from the refreshed history. | The conversation changed. Close this detail and select a tool call from the refreshed history. |
| `hud.toolHistory.detail.storedPreview` | Stored preview · may not include the full original | Stored preview · may not include the full original |
| `hud.toolHistory.detail.storedPreviewTruncated` | Stored preview · truncated, not the full original | Stored preview · truncated, not the full original |
| `hud.toolHistory.detail.unavailable` | The original record is missing, unreadable, ambiguous, or exceeds the reader limit. The preview is still available. | The original could not be found or read. The record may be ambiguous or exceed the read limit. A stored preview is shown below if available. |
| `hud.toolHistory.detail.unsupported` | Original lookup for directly executed shell commands is not supported yet. | Original lookup for directly executed shell commands is not supported yet. |
| `hud.toolHistory.empty` | No tool calls recorded yet | No tool calls recorded yet |
| `hud.toolHistory.file.unavailable` | Could not open the file | Could not open the file |
| `hud.toolHistory.filter.empty` | No tool calls match these filters | No tool calls match these filters |
| `hud.toolHistory.scope.session` | Whole session | Whole conversation |
| `hud.toolHistory.scope.turn` | This turn | This turn |
| `hud.toolHistory.search.accessibilityLabel` | Search tool history | Search tool history |
| `hud.toolHistory.search.placeholder` | Search tools | Search tools |
| `hud.utilityPanel.accessibilityLabel` | Pickle utility panel | Pickle work panel |
| `hud.utilityPanel.changes.placeholder` | Changes will appear here | Changes will appear here |
| `hud.utilityPanel.tab.artifacts` | Artifacts | Artifacts |
| `hud.utilityPanel.toggle.help` | Show or hide utility panel (⌘E) | Show or hide the work panel (⌘E) |
| `messages.empty.body` | Hold Control+Option or type below. Your prompt and the Picky reply will appear here. | Use voice input or type below. Your messages and Picky’s replies will appear here. |
| `messages.newSession` | New session | New conversation |
| `messages.newSession.starting` | Starting new session | Starting a new conversation |
| `messages.subtitle` | Latest 100 prompts and replies. | Up to 100 recent messages and replies. |
| `notif.session.completed.title` | Analysis finished | Task completed |
| `onboarding.bubble.awaitingArchive` | Now **long-press** the demo pickle to archive it. | Now **long-press** the demo pickle to archive it. |
| `onboarding.bubble.awaitingPickleOpen` | **Open the dock pickle** to keep going. | **Open the dock pickle** to keep going. |
| `onboarding.bubble.delegatingToPickle` | '**Hey Pickle** — can you summarize this page and write it up for me? Focus on the part they marked.' | '**Hey Pickle**, can you summarize this page and write it up for me? Focus on the part they marked.' |
| `onboarding.bubble.explainingDelegation` | For a page like this I can answer inline, or I can hand the work off to a **Pickle** in the dock. | For a page like this I can answer inline, or I can hand the work off to a **Pickle** in the dock. |
| `onboarding.bubble.explainingPickle` | A Pickle is an independent **Pi session** that runs in your dock — like a background tab for long work. | A Pickle is an **independent Pi conversation** in your dock. Give it a longer task while you keep working. |
| `onboarding.bubble.explainingTriggers` | You can talk to me with **Push-to-Talk (Control+Option)** or **Quick Input (double-tap Control)**. **For this demo I'll drive — just watch.** | Use your configured **Push to Talk** or **Quick Input** shortcut to call me. **For this demo, just watch.** |
| `onboarding.bubble.introducing` | Hi! I'm **Picky**. I follow your cursor and help you get things done — right where you're working. | Hi! I'm **Picky**. I follow your cursor and help you where you're working. |
| `onboarding.bubble.inviteArchive` | When you're done with a Pickle, **long-press** it to archive. | When you're done with a Pickle, **long-press** it to archive. |
| `onboarding.bubble.inviteClose` | Now **click the pickle in the dock again** to close it. | Now **click the pickle in the dock again** to close it. |
| `onboarding.bubble.openedPickle` | Inside a Pickle you can send follow-up messages or **switch to the terminal UI (⌘T)** to keep working. | Inside a Pickle, send more messages or **switch to the terminal (⌘T)** to keep working. |
| `onboarding.bubble.openingPatchNotes` | Opening **Pi 0.73.1 release notes** in your browser… | Opening **Pi 0.73.1 release notes** in your browser… |
| `onboarding.bubble.outro` | Nice. If you’re unsure how to use Picky, just ask me — I can answer from Picky’s built-in guide. Call me anytime with **Push-to-Talk (Control+Option)** or **Quick Input (double-tap Control)**. | Ask me whenever you need help with Picky. I can refer to the built-in guide. Use your **Push to Talk** or **Quick Input** shortcut to call me. |
| `onboarding.bubble.pickleCompleted` | Pickle is done! **Click the pickle** in your dock to inspect what it produced. | Pickle is done! **Click the pickle** in your dock to inspect what it produced. |
| `onboarding.bubble.pickleRunning` | While the Pickle works, notice how **your highlighted area** gets carried along as context — see the preview above. | The preview above shows how **your highlighted area** is included with the Pickle’s task. |
| `onboarding.bubble.preWelcome` | This onboarding **never makes real LLM calls**. Relax and follow along. | This demo **does not make real AI model calls**. Follow along at your own pace. |
| `onboarding.bubble.showingCapabilities` | There is a bunch of things I can do. For example, I can pull up Pi's release notes. | I can help with many tasks. For example, I can open Pi's release notes. |
| `onboarding.highlight.header` | This is what gets sent as context | This is included with your request |
| `onboarding.skip.button` | Skip onboarding | Skip introduction |
| `overlay.captureBorder.contextLabel` | This screen is being shared as context | Include this screen with the next request |
| `overlay.captureBorder.notIncludedLabel` | This screen is not included as context | Do not include this screen with the next request |
| `prereq.copy.contextHandoff` | It captures neutral desktop context when you press the hot key, then hands that context to your local agent client. | When you send a voice or text request, Picky captures desktop context such as your screen and selected text for Pi. |
| `prereq.copy.noAccount` | No account, no payment — Picky uses your local Pi install. | Picky needs no separate account. Your chosen AI or speech services may require sign-in or charge fees. |
| `prereq.copy.runsLocally` | Picky runs locally. | Picky runs on this Mac. |
| `prereq.heading` | PREREQUISITES | Required permissions |
| `prereq.screenRecording.detail.granted` | Only takes a screenshot when you use the hotkey | Captures screen context for your requests. Control when screenshots are sent in Settings. |
| `settings.builtinTools.tool.readUserGuide.description` | Let the agent consult Picky's bundled manual before answering app-usage questions. Disabling makes the agent answer those from general knowledge. | Let the agent consult Picky’s bundled guide for app-usage questions. Turning this off disables this guide-reading tool. |
| `settings.builtinTools.tool.screenOverlay.description` | Let Picky point at and draw shapes on your screen to guide you. Turning this off stops all on-screen overlays. | Let Picky point at locations and draw shapes on your screen. Turning this off disables these visual guides. |
| `settings.cursor.disabledNote` | Smooth follow and idle animations are disabled while the Pi cursor is hidden. | Smooth follow and idle animations are disabled while the Picky cursor is hidden. |
| `settings.cursorBubbles.toggle.userSTT` | User STT recognition | Recognized speech text |
| `settings.dispatch.idle.note` | Applies to PTT and Quick Input sent to an armed Pickle. Idle Pickles start immediately with either option. | Applies to PTT and Quick Input sent to an armed Pickle. Idle Pickles start immediately with either option. |
| `settings.dispatch.steer.detail` | Send into the current turn to adjust its direction. | Send your request during the current work to adjust its direction. |
| `settings.field.agentsFile.note` | Edit Picky's persona and Pickle routing rules directly in the AGENTS.md inside the main agent cwd. Pi loads it on every main-agent turn — reset or relaunch Picky to pick up mid-session changes. | Edit Picky’s persona and Pickle routing instructions in the workspace’s AGENTS.md. Reset the Picky conversation or restart the app to apply changes to the current conversation. |
| `settings.field.armedPickleDispatchMode` | Armed Pickle delivery | Delivery to the input-target Pickle |
| `settings.field.armedPickleDispatchMode.note` | Choose whether PTT and Quick Input sent to an armed Pickle wait as a follow-up or interrupt the current turn as a steer. Idle Pickles start immediately either way. | For voice and Quick Input requests sent to the input-target Pickle, choose whether to wait for its response to finish or send during its work. Idle Pickles start immediately. |
| `settings.field.attachScreenshotsOnlyWhenInked` | Send screenshots only when drawn | Limit automatic screenshot sharing |
| `settings.field.attachScreenshotsOnlyWhenInked.note` | When on, Picky attaches a screenshot only if you marked the screen with click and drag. Screen capture still runs locally for the ink overlay; only the model handoff is skipped. | When on, only marked screens are sent automatically. Screens you explicitly include are sent even without marks. Local capture for drawing continues. |
| `settings.field.defaultCwd` | Default cwd | Default working folder |
| `settings.field.dockSize.mediumNote` | M matches the current Pickle dock size. | M is the default dock size. |
| `settings.field.piModel.helpText` | Choose Automatic to follow Pi settings, or pick a model to pin Picky. Reasoning level below is applied with the pinned model. | Choose Automatic to follow Pi settings, or pick a model to pin Picky. Reasoning level below is applied with the pinned model. |
| `settings.field.pickyCwd` | Picky cwd | Picky working folder |
| `settings.field.pickyCwd.workspaceWarning` | Picky's default workspace ships with an `AGENTS.md` describing how Picky should behave and which tools to call. If you change the cwd, we recommend copying `AGENTS.md` over too — otherwise Picky may not invoke its tools correctly. | If you use custom instructions in AGENTS.md, copy the file to your new working folder to keep using them. |
| `settings.field.reasoningLevel` | Reasoning level | Reasoning level |
| `settings.field.reasoningLevel.pickleNote` | Used only as the initial reasoning level for newly-created Pickles. Running Pickles can still cycle it independently. | Used only as the initial reasoning level for newly-created Pickles. Running Pickles can still cycle it independently. |
| `settings.field.screenContext` | Screen context | Screen context |
| `settings.general.language.note` | Some macOS-owned surfaces (the app menu, system dialogs) only follow this on the next launch. The rest of Picky retranslates immediately. | Some macOS-owned surfaces (the app menu, system dialogs) only follow this on the next launch. The rest of Picky retranslates immediately. |
| `settings.general.subtitle.section` | App-wide preferences. Adding a new language is a one-line code change plus catalog entries. | Change the app language and other app-wide preferences. |
| `settings.mainAgent.summary.capture` | When enabled, only drawn-on screenshots are sent. Screen capture continues. | When on, marked or explicitly included screens can be sent. Screen capture continues. |
| `settings.mainAgent.summary.dispatch` | Used by PTT and Quick Input. Idle Pickles start immediately in either mode. | Used by PTT and Quick Input. Idle Pickles start immediately in either mode. |
| `settings.mainAgent.summary.instructions` | Edit behavior and tool instructions. Reset or restart to apply them to the current session. | Edit behavior and tool instructions. Reset or restart to apply them to the current session. |
| `settings.mainAgent.summary.model` | Follow Pi defaults, or pin a model and reasoning level. | Follow Pi defaults, or pin a model and reasoning level. |
| `settings.mainAgent.warning.workspace` | Move AGENTS.md with the workspace. Missing instructions can cause tool calls to fail. | Copy any custom AGENTS.md instructions to the new working folder. |
| `settings.notification.toggle.newPickles.note` | These defaults affect only new Pickles. Existing Pickles keep their current completion settings. | These defaults affect only new Pickles. Existing Pickles keep their current completion settings. |
| `settings.notification.toggle.newPicklesMacOS` | Notify in macOS when new Pickles complete | Notify in macOS when new Pickles complete |
| `settings.notification.toggle.newPicklesMain` | Report new Pickles to Main Picky when complete | Report new Pickles to Main Picky when complete |
| `settings.oauth.body` | Use these buttons to start Pi OAuth in your browser. Picky stores nothing itself; credentials are written to Pi's local auth storage. | Use the buttons below to sign in to AI services in your browser. Credentials are saved in Pi’s local authentication storage. |
| `settings.oauth.fallback` | If the browser callback does not complete, run `pi /login` and choose the same provider for Pi's manual fallback. | If browser sign-in does not complete, run `pi /login` and choose the same provider to sign in manually. |
| `settings.oauth.provider.anthropic.subtitle` | Claude Pro/Max OAuth provider for Anthropic models. | Use Anthropic models with a Claude Pro/Max subscription. |
| `settings.oauth.provider.openai.subtitle` | ChatGPT Plus/Pro Codex subscription provider. | Use Codex with a ChatGPT Plus/Pro subscription. |
| `settings.oauth.status.signingIn` | Waiting for browser… | Waiting for browser sign-in… |
| `settings.oauth.status.stored` | Pi auth | Credentials saved in Pi |
| `settings.oauth.subtitle.index` | Sign in to Pi OAuth providers. | Sign in to AI service accounts. |
| `settings.oauth.subtitle.section` | Connect provider accounts used by Pi and Picky features. | Connect AI service accounts for Pi and Picky. |
| `settings.oauth.summary.none` | No providers configured | No accounts connected |
| `settings.oauth.title` | OAuth | Connected accounts |
| `settings.overlayAndNotifications.subgroup.bubbles` | Bubbles | Bubbles |
| `settings.pickle.archive.toggle` | Archived sessions | Archived Pickles |
| `settings.pickle.gitChipActions.title` | Git chip actions | Git click actions |
| `settings.section.builtinTools.note` | Changes apply to the main agent immediately and interrupt any in-progress turn. Turning one off stops the agent from using that capability. | Changes apply to Picky. Some tool changes interrupt the current response; others take effect on the next request. |
| `settings.section.cursorBubbles.subtitle` | Pi cursor visibility, small animations, and speech bubbles. | Configure the Picky cursor, animations, and speech bubbles. |
| `settings.section.cursorBubbles.title` | Cursor &amp; Bubbles | Cursor &amp; Bubbles |
| `settings.section.feedback.subtitle` | Bug, idea, or anything to the dev. | Send problems or ideas to the developer. |
| `settings.section.notification.subtitle` | Banners for session events. | Banners for completion, failures, and input requests. |
| `settings.section.onboarding.body` | Picky will replay the takeover demo the next time it launches, with no real LLM calls. | Picky will replay the introduction the next time it launches, without making real AI model calls. |
| `settings.section.onboarding.replay` | Replay onboarding on next launch | Replay introduction on next launch |
| `settings.section.onboarding.subtitle` | Replay the interactive intro demo. | Replay the interactive introduction. |
| `settings.section.onboarding.title` | Onboarding | Introduction |
| `settings.section.overlayAndNotifications.subtitle` | Cursor, speech bubbles, and macOS banners. | Cursor, speech bubbles, and macOS banners. |
| `settings.section.picky.subtitle` | Runtime, cwd, reasoning, and captured screen context. | Configure the working folder, model and reasoning, and screen sharing. |
| `settings.section.shortcuts.subtitle` | Push to Talk and Quick Input bindings. | Push to Talk and Quick Input bindings. |
| `settings.section.voice.title` | Voice (STT &amp; TTS) | Speech input and playback |
| `settings.shortcuts.pushToTalk.subtitle` | Hold to start a voice session. Release to send. | Hold to speak. Release to send. |
| `settings.shortcuts.quickInput.title` | Quick Input | Quick Input |
| `settings.summary.cursorBubbles` | %@ · %lld / %lld bubbles | %@ · %lld / %lld bubbles |
| `settings.summary.pickle` | %@ · Dock %@ | %@ · Dock %@ |
| `settings.summary.shortcuts` | PTT %@ · Quick Input %@ · Focus %@ | PTT %@ · Quick Input %@ · Focus %@ |
| `settings.tts.disabledNote` | Turn this off to keep Picky text replies visible without playing audio. | Turn this off to stop spoken replies. Text visibility follows your reply-text setting. |
| `settings.voice.azure.tts.apiKey.placeholder` | Leave empty to reuse the STT API key | Leave empty to reuse the STT API key |
| `settings.voice.azure.tts.url` | Azure TTS speech URL | Azure TTS speech URL |
| `settings.voice.edge.disclosure` | Spoken response text is sent to Microsoft Edge Read Aloud. This unofficial online service may change or become unavailable. | Spoken response text is sent to Microsoft Edge Read Aloud. This unofficial online service may change or become unavailable. |
| `settings.voice.elevenlabs.tts.outputFormat` | ElevenLabs TTS output format | ElevenLabs TTS output format |
| `settings.voice.elevenlabs.tts.voiceId` | ElevenLabs TTS voice ID | ElevenLabs TTS voice ID |
| `settings.voice.openaiBaseUrlNote` | OpenAI-compatible base URLs let you point Picky at a local proxy (LocalAI, openai-edge-tts, Together, etc). Picky speaks the standard /v1/audio/transcriptions protocol — proxy stability is your responsibility. | Enter the base URL of an OpenAI-compatible service or proxy. Speech recognition uses /v1/audio/transcriptions. Check that the service supports this API. |
| `settings.voice.provider.stt` | STT provider | Speech recognition service |
| `settings.voice.provider.tts` | TTS provider | Speech playback service |
| `speech.edge.error.connectionUnavailable` | Picky's local Edge TTS connection is unavailable. | Picky’s connection information for Edge speech playback is unavailable. |
| `speech.edge.error.emptyResponse` | Picky's local Edge TTS service returned empty audio. | The Edge speech service returned no audio to play. |
| `speech.edge.error.http` | Picky's local Edge TTS service failed with HTTP %lld. | The Edge speech service failed with HTTP %lld. |
| `speech.edge.error.insecureConnection` | Picky's local Edge TTS connection has unsafe file permissions. | Edge speech playback is unavailable because Picky’s connection file permissions are unsafe. |
| `status.captures.screenshots` | Screenshots only when you use the hotkey | Captures screen context for your requests. Control when screenshots are sent in Settings. |
| `status.captures.text` | Selected text and browser context when available | Selected text and browser context when available |
| `status.extensions.pickyCLI.description` | Adds guidance for using the local Picky CLI to submit to Picky, create Pickles, and control push-to-talk. | Adds guidance for using the local Picky CLI to submit to Picky, create Pickles, and control push-to-talk. |
| `status.extensions.pickyHandoff.description` | Adds the /handoff-to-picky slash command to your local Pi. Lets you pin a Pi conversation to Picky as a completed Pickle card. | Adds /handoff-to-picky to local Pi. Active work continues in a new Pickle; idle conversations appear as completed Pickles. |
| `status.extensions.pickyHandoff.title` | Pi handoff command | Pi conversation handoff |
| `status.extensions.reload.banner.button` | Reload | Reload |
| `status.extensions.reload.banner.message` | Plugin changes apply after Reload. | Plugin changes apply after Reload. |
| `status.extensions.reload.banner.title` | Reload required | Reload required |
| `status.extensions.reload.confirm.message.both` | %lld running Pickle session(s) will be aborted and the current Picky voice response will be cut. Sessions in compaction will reload automatically when compaction completes. | %lld running Pickle task(s) and Picky’s current response will be interrupted. Pickles compacting their conversation history will reload when compaction finishes. |
| `status.extensions.reload.confirm.message.generic` | Proceed with reload? | Reload plugins? |
| `status.extensions.reload.confirm.message.main` | The current Picky voice response will be cut. | Picky’s current response will be interrupted. |
| `status.extensions.reload.confirm.message.pickles` | %lld running Pickle session(s) will be aborted. Sessions in compaction will reload automatically when compaction completes. | %lld running Pickle task(s) will be interrupted. Pickles compacting their conversation history will reload when compaction finishes. |
| `status.extensions.reload.confirm.proceed` | Reload | Reload |
| `status.extensions.reload.confirm.title` | Reload all sessions? | Reload plugins in all conversations? |
| `status.extensions.reload.error.disconnected` | Reload stopped because agentd disconnected. | Reload stopped because the local agent disconnected. |
| `status.extensions.reload.error.timeout` | Reload timed out. Try again in a moment. | Reload timed out. Try again in a moment. |
| `status.extensions.reload.result.nothing` | Nothing to reload. | Nothing to reload. |
| `status.extensions.reload.result.pickleAborted` | %lld running aborted | %lld running task(s) interrupted |
| `status.extensions.reload.result.pickleDeferred` | %lld awaiting compaction | %lld waiting for history compaction |
| `status.extensions.reload.result.pickleReloaded` | %lld Pickle reloaded | %lld Pickle(s) reloaded |
| `status.extensions.state.legacySymlink` | Legacy install — re-install to migrate to a copy. | Legacy installation. Reinstall to replace the link with a copy. |
| `status.feedback.subtitle` | Bug, idea, or anything to the dev. | Send problems or ideas to the developer. |
| `status.shellCommand.stale.title` | `picky` points at a different Picky.app | `picky` points at a different Picky.app |
| `status.voice.listening.subtitle` | Keep holding Control+Option while you speak. | Keep holding your Push to Talk shortcut while you speak. |
| `status.voice.processing.subtitle` | Picky is collecting just enough context for Pi. | Picky is processing your speech or waiting for the AI response. |
| `status.voice.processing.title` | Preparing context… | Processing your request… |

</details>

## 하드코딩 문구의 번역 연결 및 새 안내

Before는 기존 코드에 직접 적힌 문구다. 기존 지역화가 없던 항목은 영어 원문이 보일 수 있다. 동작 분기로 추가한 안내는 기존 공통 문구 또는 새 안내로 표시한다.

| 식별자 | Before | After (한국어) | After (영어) |
|---|---|---|---|
| `appearance.dark.accessibility` | iconButton(systemName: "moon.fill", target: .dark, accessibilityLabel: "Use dark appearance") | 다크 모드 사용 | Use dark appearance |
| `appearance.light.accessibility` | iconButton(systemName: "sun.max.fill", target: .light, accessibilityLabel: "Use light appearance") | 라이트 모드 사용 | Use light appearance |
| `common.collapse` | return isExpanded ? "접기" : "더 보기"<br>return isExpanded ? L10n.t("common.collapse") : "더 보기" | 접기 | Show less |
| `common.collapsed` | .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")<br>.accessibilityValue(isCollapsed ? L10n.t("common.collapsed") : "Expanded") | 접힘 | Collapsed |
| `common.dismiss` | Dismiss | 닫기 | Dismiss |
| `common.expanded` | .accessibilityValue(isCollapsed ? L10n.t("common.collapsed") : "Expanded") | 펼쳐짐 | Expanded |
| `common.notSelected` | .accessibilityValue(selected ? L10n.t("common.selected") : "Not selected") | 선택 안 됨 | Not selected |
| `common.resetZoom` | Reset Zoom | 확대율 초기화 | Reset Zoom |
| `common.selected` | .accessibilityValue(selected ? "Selected" : "Not selected")<br>.accessibilityValue(selected ? L10n.t("common.selected") : "Not selected") | 선택됨 | Selected |
| `common.sending` | .accessibilityValue(viewModel.isSending ? "Sending" : "") | 보내는 중 | Sending |
| `common.showMore` | return isExpanded ? L10n.t("common.collapse") : "더 보기" | 더 보기 | Show more |
| `common.zoomIn` | Zoom In | 확대 | Zoom In |
| `common.zoomOut` | Zoom Out | 축소 | Zoom Out |
| `dock.archive.undo.accessibility` | Session archived. Undo available. | Pickle을 보관했어요. 실행 취소할 수 있어요. | Pickle archived. You can undo this. |
| `dock.group.addMember.accessibility` | .accessibilityLabel("\(isSelected ? "Remove" : "Add") \(session.title) \(isSelected ? "from" : "to") group") | 그룹에 %@ 추가 | Add %@ to group |
| `dock.group.create.empty` | No Pickles to include yet. You can create the group now and drag Pickles in later. | 추가할 Pickle이 없어요. 그룹을 먼저 만들고 나중에 Pickle을 끌어다 놓을 수 있어요. | No Pickles to add yet. Create the group now and drag Pickles into it later. |
| `dock.group.create.members` | Include Pickles | 추가할 Pickle | Include Pickles |
| `dock.group.create.name` | Name | 이름 | Name |
| `dock.group.create.placeholder` | e.g. my-web-app | 예: 웹사이트 작업 | e.g. Website project |
| `dock.group.create.selected` | \(selectedMemberIDs.count) selected | %lld개 선택됨 | %lld selected |
| `dock.group.create.submit` | Create | 만들기 | Create |
| `dock.group.create.title` | New group | 새 그룹 | New Group |
| `dock.group.removeMember.accessibility` | .accessibilityLabel("\(isSelected ? "Remove" : "Add") \(session.title) \(isSelected ? "from" : "to") group") | 그룹에서 %@ 제외 | Remove %@ from group |
| `dock.group.unreadCount` | \(unreadCount) unread | 읽지 않음 %lld개 | %lld unread |
| `dock.handle.accessibility` | HUD dock handle | Pickle 독 이동 핸들 | Pickle dock handle |
| `dock.handle.help` | Drag to move the Pickle dock. Crossing the middle of the screen switches the dock edge. Double-click to toggle between vertical and horizontal layouts. | 끌어서 Pickle 독을 이동하세요. 화면 중앙을 넘으면 반대쪽 가장자리로 옮겨져요. 두 번 클릭하면 가로·세로 배치를 전환해요. | Drag to move the Pickle dock. Cross the middle of the screen to switch edges. Double-click to switch between vertical and horizontal layouts. |
| `dock.pickle.interaction.help` | Click to open or close. Press and hold for 1.5 seconds to archive this Pickle. | 클릭하면 열거나 닫아요. 1.5초 동안 누르면 이 Pickle을 보관해요. | Click to open or close. Press and hold for 1.5 seconds to archive this Pickle. |
| `dock.pickle.open.accessibility` | Preview \(session.title) | %@ 열거나 닫기 | Open or close %@ |
| `dock.pickle.unread.help` | This Pickle has updates you haven't seen yet. | 아직 읽지 않은 업데이트가 있어요. | This Pickle has unread updates. |
| `dock.pickle.untitled` | Untitled Pickle | 이름 없는 Pickle | Untitled Pickle |
| `dock.unread` | Unread | 읽지 않음 | Unread |
| `feedback.attachment.attach` | Attach | 첨부 | Attach |
| `feedback.attachment.choose` | Choose up to \(MediaAttachmentPolicy.maxCount) files. | 파일을 최대 %1$lld개까지 선택해 주세요. | Choose up to %1$lld files. |
| `feedback.attachment.moreNotices` | return unique.prefix(2).joined(separator: " ") + " +\(unique.count - 2) more." | 첨부 문제 %1$lld개가 더 있어요. | %1$lld more attachment issues. |
| `feedback.attachment.notRegular` | Cannot attach \(filename). Choose a regular file. | %1$@을(를) 첨부할 수 없어요. 일반 파일을 선택해 주세요. | Cannot attach %1$@. Choose a regular file. |
| `feedback.attachment.panelTitle` | Attach files | 파일 첨부 | Attach files |
| `feedback.attachment.remove` | .buttonStyle(.plain)<br>            .disabled(status == .sending)<br>            .hoverAffordance() | 첨부 파일 %1$@ 제거 | Remove %1$@ from attachments |
| `feedback.attachment.tooLarge` | \(filename) is \(Self.format(byteCount)); max is \(Self.format(MediaAttachmentPolicy.maxFileBytes)). | %1$@의 크기는 %2$@예요. %3$@ 이하의 파일을 선택해 주세요. | %1$@ is %2$@. Choose a file no larger than %3$@. |
| `feedback.attachment.tooMany` | Attach up to \(MediaAttachmentPolicy.maxCount) files. | 파일은 최대 %1$lld개까지 첨부할 수 있어요. | Attach up to %1$lld files. |
| `feedback.attachment.totalTooLarge` | Selected files are \(Self.format(byteCount)); total max is \(Self.format(MediaAttachmentPolicy.maxTotalBytes)). | 이 파일을 추가하면 첨부 파일 합계가 %1$@가 돼요. 합계는 %2$@ 이하여야 해요. | Adding this file would bring attachments to %1$@. Keep the total at or below %2$@. |
| `feedback.category.bug` | Bug | 오류 신고 | Bug report |
| `feedback.category.idea` | Idea | 개선 제안 | Suggestion |
| `feedback.category.other` | Other | 기타 | Other |
| `feedback.diagnostics.full` | Full bundle | 오류 기록 및 설정 | Error logs + settings |
| `feedback.diagnostics.fullHint` | Logs only + sanitized settings.json (API keys masked). Chat/tool arguments/results are still excluded. | 오류 기록에 API 키를 가린 앱 설정을 추가해요. 대화 기록이나 도구 입력·결과를 별도 파일로 첨부하지는 않아요. 로그에는 민감한 내용이 남아 있을 수 있어요. | Also includes app settings with API keys masked. No separate chat transcript or tool inputs/results are attached. Logs may still contain sensitive text. |
| `feedback.diagnostics.logs` | Logs only | 오류 기록 | Error logs |
| `feedback.diagnostics.logsHint` | Attaches stderr, OSLog, metadata, and tool-name-only activity. User chat, tool arguments, and tool results are never included. | 오류 기록, 앱·시스템 정보, 사용한 도구 이름을 Picky 팀에 보내요. 대화 기록이나 도구 입력·결과를 별도 파일로 첨부하지는 않아요. 로그에는 민감한 내용이 남아 있을 수 있어요. | Sends error logs, app and system information, and tool names to the Picky team. No separate chat transcript or tool inputs/results are attached. Logs may still contain sensitive text. |
| `feedback.diagnostics.off` | Off | 첨부 안 함 | None |
| `feedback.diagnostics.offHint` | No file attached. Useful for ideas or quick notes. | 진단 파일은 보내지 않아요. 위에서 직접 선택한 파일은 첨부돼요. | No diagnostic files will be sent. Files you selected above will still be attached. |
| `feedback.diagnostics.title` | Attach diagnostics | 문제 진단 정보 | Diagnostic information |
| `hub.settings.permission.request` | 확인 필요 · 시스템 설정 | 접근 허용 요청 | Request access |
| `hub.settings.permission.request.detail` | 이 권한은 시스템 설정에서 관리할 수 있습니다. | Picky에서 브라우저 콘텐츠 접근을 요청해요. | Request browser content access in Picky. |
| `hud.archive.confirmDelete.accessibility` | .accessibilityLabel(isDeleteArmed ? "Confirm delete Pickle" : "Delete Pickle")<br>.accessibilityLabel(isDeleteArmed ? L10n.t("hud.archive.confirmDelete.accessibility") : "Delete Pickle") | Pickle 삭제 확인 | Confirm Pickle deletion |
| `hud.archive.delete.accessibility` | .accessibilityLabel(isDeleteArmed ? L10n.t("hud.archive.confirmDelete.accessibility") : "Delete Pickle") | Pickle 삭제 | Delete Pickle |
| `hud.archive.deleteAll.accessibility` | Delete all archived Pickles | 진행 중이 아닌 보관 Pickle 삭제 | Delete inactive archived Pickles |
| `hud.archive.restore.accessibility` | Restore Pickle | Pickle 복원 | Restore Pickle |
| `hud.archivedList.deleteFailed` | (새 안내) | Pickle을 삭제하지 못해 보관 목록에 남겨 뒀어요. %1$@ | Could not delete the Pickle. It remains in the archive. %1$@ |
| `hud.archivedList.deleteUnavailableActive` | (새 안내) | 아직 진행 중인 Pickle이에요. 복원한 뒤 중단하거나 작업이 끝난 후 삭제해 주세요. | This Pickle is still active. Restore it and stop it, or wait for it to finish before deleting. |
| `hud.attachment.remove` | Remove attachment | 첨부 파일 제거 | Remove attachment |
| `hud.attachment.removeNamed` | Remove attachment \(attachment.displayName) | 첨부 파일 %@ 제거 | Remove attachment %@ |
| `hud.card.resize.help` | Drag the corner to resize this Pickle card. Double-click to reset the size. | 모서리를 끌어 Pickle 카드 크기를 조절하세요. 두 번 클릭하면 원래 크기로 돌아가요. | Drag the corner to resize this Pickle card. Double-click to reset its size. |
| `hud.composer.bash.accessibility` | .accessibilityLabel(effectiveBashMode == .private ? L10n.t("hud.composer.bash.private.accessibility") : "Bash mode") | 셸 명령 | Shell command |
| `hud.composer.bash.private.accessibility` | .accessibilityLabel(effectiveBashMode == .private ? "Bash private mode" : "Bash mode")<br>.accessibilityLabel(effectiveBashMode == .private ? L10n.t("hud.composer.bash.private.accessibility") : "Bash mode") | 셸 명령, 출력은 Pi에게 전달하지 않음 | Shell command, output not shared with Pi |
| `hud.composer.bash.private.help` | Bash execution · output hidden from Pi context | 셸 명령 실행 · 출력은 Pi에게 전달하지 않아요 | Run a shell command without sharing its output with Pi |
| `hud.composer.bash.shared.help` | Bash execution · output added to Pi context | 셸 명령 실행 · 출력을 Pi에게 전달해요 | Run a shell command and share its output with Pi |
| `hud.composer.placeholder.question` | 에이전트에 개입 · ⌥↵ 후속 요청 · esc 중지 | 추가 지시 입력… 질문이 있다면 질문에서 답해 주세요. | Add a separate instruction… If there is a question, answer it in the question form. |
| `hud.context.percent` | Context usage: \(Int(clamped.rounded()))% of \(usage.contextWindow.formatted()) tokens | 컨텍스트 사용량: 전체 %2$@ 토큰 중 %1$lld%% | Context usage: %lld%% of %@ tokens |
| `hud.context.tokensAndPercent` | Context usage: \(tokens.formatted())/\(usage.contextWindow.formatted()) tokens (\(Int(clamped.rounded()))%) | 컨텍스트 사용량: %@/%@ 토큰 (%lld%%) | Context usage: %@/%@ tokens (%lld%%) |
| `hud.context.usage` | Context usage | 컨텍스트 사용량 | Context usage |
| `hud.error.continue` | 다시 시도 | 이어가기 | Continue |
| `hud.error.continue.accessibilityLabel` | 실패한 요청 다시 시도 | 오류가 발생한 작업 이어가기 | Continue after the error |
| `hud.event.awaitingInput` | Awaiting input<br>Waiting for input | 입력 대기 중 | Waiting for your input |
| `hud.event.reportReady` | case .completed: return hasReportArtifact ? "Report ready" : "Result"<br>case .completed: return hasReportArtifact ? L10n.t("hud.event.reportReady") : "Result" | 보고서 준비됨 | Report ready |
| `hud.event.result` | case .completed: return hasReportArtifact ? L10n.t("hud.event.reportReady") : "Result" | 결과 | Result |
| `hud.event.update` | Update | 업데이트 | Update |
| `hud.extension.error` | Error | 오류 | Error |
| `hud.extension.info` | Info | 안내 | Info |
| `hud.extension.label` | Pi extension | Pi 확장 기능 | Pi extension |
| `hud.extension.warning` | Warning | 주의 | Warning |
| `hud.folderPicker.message` | Choose the folder where the new Pickle should run. | 새 Pickle이 작업할 폴더를 선택하세요. | Choose the folder where the new Pickle will work. |
| `hud.folderPicker.start` | Start | 시작 | Start |
| `hud.folderPicker.title` | Choose a working folder | 작업 폴더 선택 | Choose a Working Folder |
| `hud.gitAction.configure` | Open Settings → Pickle to configure the command. | 설정 → Pickle에서 실행할 명령을 설정하세요. | Open Settings → Pickle to configure the command. |
| `hud.gitAction.empty` | Git chip action is empty | Git 동작이 설정되지 않았어요 | No Git action configured |
| `hud.gitAction.failed` | Git chip action failed | Git 동작을 실행하지 못했어요 | Could not run the Git action |
| `hud.gitAction.noFolder` | This Pickle has no working directory, so the shell command cannot run. | 이 Pickle에 작업 폴더가 없어 셸 명령을 실행할 수 없어요. | This Pickle has no working folder, so the shell command cannot run. |
| `hud.localTerminal.closed` | Shell closed | 터미널이 닫혔어요 | Terminal closed |
| `hud.localTerminal.exitCode` | Shell exited with code \(exitCode) | 셸이 종료됐어요 (종료 코드 %d) | Shell exited with code %d |
| `hud.localTerminal.exited` | Shell exited | 셸이 종료됐어요 | Shell exited |
| `hud.localTerminal.ready` | Ready in \(Self.compactPath(PickyShellTerminalCommand.workingDirectory(from: cwd))) | %@에서 시작할 준비가 됐어요 | Ready in %@ |
| `hud.localTerminal.running` | Shell in \(Self.compactPath(PickyShellTerminalCommand.workingDirectory(from: cwd))) | %@에서 셸 실행 중 | Shell in %@ |
| `hud.localTerminal.show` | Show This Terminal | 여기에서 터미널 보기 | Show Terminal Here |
| `hud.localTerminal.title` | Local Terminal | 로컬 터미널 | Local Terminal |
| `hud.localTerminal.visibleElsewhere` | Terminal is already visible in another HUD panel | 이 터미널은 다른 Pickle 패널에 열려 있어요. | This terminal is open in another Pickle panel. |
| `hud.markdown.omittedLines` | Text("+\(omittedCount) more line\(omittedCount == 1 ? "" : "s")") | 표시하지 않은 줄: %lld개 | Lines not shown: %lld |
| `hud.menu.section.quick` | QUICK | 바로가기 | Shortcuts |
| `hud.menu.section.session` | SESSION | 대화 | Conversation |
| `hud.menu.section.settings` | SETTINGS | 설정 | Settings |
| `hud.menu.stopSession.help` | (기존 도움말 없음) | 작업을 중지하고 대기 중인 텍스트를 입력란으로 옮겨요. 대기 중인 화면 첨부는 복원할 수 없어요. | Stop the task and move queued text to the message field. Queued screen images cannot be restored. |
| `hud.message.editInComposer` | let item = NSMenuItem(title: "Edit in Composer", action: #selector(editTextClicked), keyEquivalent: "") | 입력창에서 수정 | Edit in Composer |
| `hud.message.openReport.help` | hoverButton.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: "Open this message as report")?<br>Open this message as report | 이 메시지를 보고서로 열기 | Open this message as a report |
| `hud.question.allow` | Allow | 허용 | Allow |
| `hud.question.answered` | INPUT ANSWERED | 답변 완료 | Answered |
| `hud.question.cancelled` | INPUT CANCELLED | 취소됨 | Cancelled |
| `hud.question.collapse` | .help(isCollapsed ? L10n.t("hud.question.expand") : "Collapse question details") | 질문 접기 | Collapse question details |
| `hud.question.deliveryFailed` | Answer delivery failed: \(errorMessage) | 답변을 보내지 못했어요: %@ | Could not send your answer: %@ |
| `hud.question.empty` | 질문 내용이 없습니다. | 질문 내용이 없어요. | No question content. |
| `hud.question.escape` | esc 취소 | esc 취소 | esc Cancel |
| `hud.question.expand` | .help(isCollapsed ? "Expand question details" : "Collapse question details")<br>.help(isCollapsed ? L10n.t("hud.question.expand") : "Collapse question details") | 질문 펼치기 | Expand question details |
| `hud.question.needed` | INPUT NEEDED | 입력이 필요해요 | Your input needed |
| `hud.question.next` | 다음 | 다음 | Next |
| `hud.question.next.accessibility` | Next question | 다음 질문 | Next question |
| `hud.question.other` | Other… | 기타… | Other… |
| `hud.question.previous` | 이전 | 이전 | Previous |
| `hud.question.requested` | Input requested | 입력이 필요해요 | Input requested |
| `hud.question.required` | 필수 항목을 입력하세요 | 필수 항목을 입력해 주세요 | Fill in the required fields |
| `hud.question.responsePlaceholder` | Response… | 답변을 입력하세요… | Your answer… |
| `hud.question.sendFailed` | Failed to answer question | 답변을 보내지 못했어요. | Could not send your answer. |
| `hud.question.status.accessibility` | Question \(statusLabel) | 질문: %@ | Question: %@ |
| `hud.question.step` | Question \(viewModel.currentStepIndex + 1) of \(questions.count) | %2$lld개 중 %1$lld번째 질문 | Question %lld of %lld |
| `hud.question.submit` | 제출<br>Submit | 제출 | Submit |
| `hud.question.submit.accessibility` | Submit answer | 답변 제출 | Submit answer |
| `hud.report.copyMarkdown.help` | Copy this report's markdown to the clipboard | 보고서 Markdown 복사 | Copy this report’s Markdown |
| `hud.report.empty` | No content captured for this report. | 보고서 내용이 없어요. | This report has no content. |
| `hud.report.reveal.help` | Open \(model.fileURL.path) in Finder | Finder에서 %@ 보기 | Show %@ in Finder |
| `hud.report.windowTitle` | Picky Report — \(title) | Picky 보고서: %@ | Picky Report: %@ |
| `hud.session.error.archived` | Cannot follow up an archived Pickle session<br>Cannot steer an archived Pickle session | 메시지를 보내려면 이 Pickle을 먼저 복원해 주세요. | Restore this Pickle before sending a message. |
| `hud.session.error.disconnected` | Disconnected from picky-agentd | Picky 로컬 서비스와 연결이 끊겼어요. | Disconnected from the local Picky service. |
| `hud.session.error.emptyMessage` | Follow-up message cannot be empty<br>Steer message cannot be empty | 보낼 메시지를 입력해 주세요. | Enter a message to send. |
| `hud.session.error.latestReportUnavailable` | Latest response is not available as a report | 최근 응답을 보고서로 열 수 없어요. | The latest response cannot be opened as a report. |
| `hud.session.error.messageReportUnavailable` | Message is not available as a report | 이 메시지를 보고서로 열 수 없어요. | This message cannot be opened as a report. |
| `hud.session.error.noRetrySession` | No session for retry | 다시 시도할 Pickle을 찾지 못했어요. | The Pickle to retry could not be found. |
| `hud.session.error.noRetryText` | No previous request text to retry | 다시 보낼 이전 요청이 없어요. | There is no previous request to send again. |
| `hud.session.error.noSelection` | No session selected for follow-up<br>No session selected for steering | 메시지를 보낼 Pickle을 선택해 주세요. | Select a Pickle to send a message. |
| `hud.session.error.subagentReportUnavailable` | Subagent response is not available as a report | 이 하위 에이전트 응답을 보고서로 열 수 없어요. | This subagent response cannot be opened as a report. |
| `hud.session.sync.invalidSnapshot` | Discarded invalid session projection snapshot | 올바르지 않은 상태 데이터로 인해 Pickle을 업데이트하지 못했어요. | Could not update this Pickle because its state data is invalid. |
| `hud.session.sync.missingInitialState` | Discarded session projection transaction without bootstrap | 초기 상태를 불러오지 못해 Pickle을 업데이트하지 못했어요. | Could not update this Pickle before its initial state was loaded. |
| `hud.session.sync.reconnecting` | Picky lost sync with this Pickle and is reconnecting. | 이 Pickle과 동기화가 끊겨 다시 연결하고 있어요. | Picky lost sync with this Pickle and is reconnecting. |
| `hud.session.sync.recoveryFailed` | Session projection recovery failed: \(error.localizedDescription) | Pickle의 현재 상태를 복구하지 못했어요: %@ | Could not recover the Pickle’s current state: %@ |
| `hud.session.sync.storageUnavailable` | Session projection v2 requires registry storage | Pickle 상태 저장소를 사용할 수 없어요. | Pickle state storage is unavailable. |
| `hud.state.blocked` | Blocked | 진행할 수 없음 | Blocked |
| `hud.state.cancelled` | Cancelled | 취소됨 | Cancelled |
| `hud.state.queued` | Queued | 대기 중 | Queued |
| `hud.terminalSync.baselineMissing.body` | Pi may have compacted or branched the transcript while the terminal was open. The card was not updated. Open the terminal again or copy the resume command if you need the latest answer. | 터미널 대화를 합칠 수 없어 카드를 업데이트하지 못했어요. 최신 답변은 터미널을 다시 열거나 재개 명령을 복사해 확인하세요. | The terminal conversation could not be merged, so this card was not updated. Reopen the terminal or copy the resume command to see the latest answer. |
| `hud.terminalSync.baselineMissing.title` | Terminal sync skipped | 대화를 동기화하지 못했어요 | Conversation not synced |
| `hud.terminalSync.imported.many` | \(count) new messages were imported from the terminal session. | 터미널에서 메시지 %lld개를 가져왔어요. | Added %lld messages from the terminal. |
| `hud.terminalSync.imported.one` | 1 new message was imported from the terminal session. | 터미널에서 메시지 1개를 가져왔어요. | Added 1 message from the terminal. |
| `hud.terminalSync.imported.title` | Terminal sync | 대화 동기화됨 | Conversation synced |
| `hud.toolCall.accessibility` | .accessibilityLabel([displayedToolName, displayedDetail, "tool call"].compactMap { $0 }.joined(separator: " ")) | 도구 실행 | tool call |
| `hud.toolHistory.failed.help` | Tool failed — open tool history | 도구 실행 실패 · 실행 내역 열기 | Tool failed. Open tool history. |
| `hud.toolHistory.open` | Open tool history | 도구 실행 내역 열기 | Open tool history |
| `hud.toolHistory.running.help` | Tool running — open tool history | 도구 실행 중 · 실행 내역 열기 | Tool running. Open tool history. |
| `hud.toolHistory.windowTitle` | Tool history — \(title) | 도구 실행 내역: %@ | Tool History: %@ |
| `menu.checkUpdates` | Check for Updates… | 업데이트 확인… | Check for Updates… |
| `menu.closeWindow` | Close Window | 윈도우 닫기 | Close Window |
| `menu.copy` | Copy | 복사 | Copy |
| `menu.cut` | Cut | 오려두기 | Cut |
| `menu.edit` | Edit | 편집 | Edit |
| `menu.fontSize` | let fontSizeItem = NSMenuItem(title: "Font Size", action: nil, keyEquivalent: "")<br>Font Size | 글자 크기 | Font Size |
| `menu.fontSize.decrease` | Decrease | 작게 | Decrease |
| `menu.fontSize.increase` | Increase | 크게 | Increase |
| `menu.fontSize.reset` | Actual Size | 기본 크기 | Actual Size |
| `menu.paste` | Paste | 붙여넣기 | Paste |
| `menu.redo` | Redo | 다시 실행 | Redo |
| `menu.selectAll` | Select All | 모두 선택 | Select All |
| `menu.undo` | Undo | 실행 취소 | Undo |
| `menu.view` | View | 보기 | View |
| `menu.window` | Window | 윈도우 | Window |
| `overlay.activity.thinking` | 생각 중 | 생각 중 | Thinking… |
| `overlay.annotation.summary` | return "Screen guidance: \(labelTexts.joined(separator: ", "))." | 화면 안내: %@ | Screen guidance: %@ |
| `overlay.annotation.visible` | Screen guidance is visible. | 화면 안내가 표시되어 있어요. | Screen guidance is visible. |
| `overlay.question.waiting` | 질문 대기 중 | 답변을 기다리고 있어요 | Waiting for your answer |
| `overlay.question.waiting.accessibility` | Question waiting for an answer | 답변을 기다리고 있어요 | Waiting for your answer |
| `quickInput.placeholder.main` | Message Picky… | Picky에게 메시지 보내기… | Message Picky… |
| `quickInput.placeholder.pickle` | Message \(label)… | %@에게 메시지 보내기… | Message %@… |
| `quickInput.recentConversation` | Recent conversation | 최근 대화 | Recent conversation |
| `settings.oauth.browserOpenFailed` | Could not open the Pi OAuth URL: \(value) | 로그인 URL을 열지 못했어요: %@ | Could not open the sign-in URL: %@ |
| `settings.oauth.browserUnavailable` | This Pi provider does not offer browser-based OAuth login. | 이 제공업체는 브라우저 로그인을 지원하지 않아요. | This provider does not support browser sign-in. |
| `settings.oauth.disconnected` | picky-agentd disconnected during Pi OAuth. | 로그인 중 로컬 서비스 연결이 끊겼어요. 다시 로그인해 주세요. | The local service disconnected during sign-in. Try signing in again. |
| `settings.oauth.invalidURL` | Pi OAuth returned an invalid URL: \(value) | 제공업체가 올바르지 않은 로그인 URL을 반환했어요: %@ | The provider returned an invalid sign-in URL: %@ |
| `settings.oauth.timedOut` | Timed out waiting for picky-agentd OAuth response. | 로그인 응답 시간이 초과됐어요. 다시 로그인해 주세요. | Sign-in timed out. Try signing in again. |
| `settings.onboarding.saveFailed` | Unable to save the onboarding preference. | 시작 안내 설정을 저장하지 못했어요. | Could not save the onboarding setting. |
| `settings.shortcut.conflict` | That shortcut conflicts with another action. | 다른 동작에서 사용하는 단축키예요. 다른 단축키를 입력해 주세요. | This shortcut is used by another action. Choose another shortcut. |
| `settings.shortcut.invalid` | That shortcut combination isn’t valid. | 지원하지 않는 단축키 조합이에요. 다른 단축키를 입력해 주세요. | This shortcut combination isn’t supported. Choose another shortcut. |
| `settings.validation.mainFolder` | Picky cwd does not exist or is not a directory: \(path) | Picky 작업 폴더가 없거나 폴더가 아닌 경로예요: %@ | Picky’s working folder does not exist or is not a folder: %@ |
| `settings.validation.piExecutable` | Pi binary path is not executable: \(path) | Pi 실행 파일을 실행할 수 없어요: %@ | The Pi executable cannot be run: %@ |
| `settings.validation.piFolder` | PI_CODING_AGENT_DIR does not exist or is not a directory: \(path) | PI_CODING_AGENT_DIR 경로가 없거나 폴더가 아니에요: %@ | PI_CODING_AGENT_DIR does not exist or is not a folder: %@ |
| `settings.validation.pickleFolder` | Pickle default cwd does not exist or is not a directory: \(path) | Pickle 기본 작업 폴더가 없거나 폴더가 아닌 경로예요: %@ | Pickle’s default working folder does not exist or is not a folder: %@ |
| `settings.validation.worktreeFolder` | Worktree parent does not exist or is not a directory: \(path) | Worktree 상위 폴더가 없거나 폴더가 아닌 경로예요: %@ | The worktree parent folder does not exist or is not a folder: %@ |
| `shellCommand.conflict.body` | A non-Picky file already exists at \(path.path). Picky will not overwrite it; please remove or rename it manually if you want to install the picky CLI here. | %@에 Picky가 관리하지 않는 파일이 있어 덮어쓰지 않아요. 여기에 설치하려면 기존 파일을 옮기거나 이름을 바꿔 주세요. | A file not managed by Picky already exists at %@. Picky will not overwrite it. To install here, move or rename that file first. |
| `shellCommand.current.body` | `\(installPath.lastPathComponent)` is already installed at \(path.path) and points at this Picky.app. | %@ 명령이 %@에 설치되어 있으며 현재 Picky.app을 사용해요. | The %@ command is installed at %@ and uses this Picky.app. |
| `shellCommand.done` | Done | 완료 | Done |
| `shellCommand.error.admin` | Failed to install with administrator privileges: \(message) | 관리자 권한으로 설치하지 못했어요: %@ | Could not install with administrator privileges: %@ |
| `shellCommand.error.missing` | Picky CLI is missing inside the app bundle at \(url.path). Reinstall Picky.app or rebuild it with the bundled agentd. | %@에 Picky 명령 파일이 없어요. Picky.app을 다시 설치해 주세요. | The Picky command file is missing at %@. Reinstall Picky.app. |
| `shellCommand.error.path` | Unsupported install path: \(url.path) | 지원하지 않는 설치 경로예요: %@ | Unsupported installation path: %@ |
| `shellCommand.error.remove` | Failed to uninstall the picky CLI wrapper: \(message) | picky 명령 파일을 삭제하지 못했어요: %@ | Could not remove the picky command file: %@ |
| `shellCommand.error.write` | Failed to write the picky CLI wrapper: \(message) | picky 명령 파일을 만들지 못했어요: %@ | Could not write the picky command file: %@ |
| `shellCommand.install` | Install | 설치 | Install |
| `shellCommand.install.body` | Install a `\(installPath.lastPathComponent)` shell command at \(installPath.path) so terminals, Raycast, Hammerspoon, and cron can talk to Picky. | 터미널이나 자동화 도구에서 Picky를 제어할 수 있도록 %@ 명령을 %@에 설치해요. | Install the %@ command at %@ to control Picky from a terminal or automation tools. |
| `shellCommand.install.title` | Install \(installPath.lastPathComponent) shell command | %@ 셸 명령 설치 | Install %@ Shell Command |
| `shellCommand.installFailed` | Install failed | 설치하지 못했어요 | Installation failed |
| `shellCommand.installed.body` | Installed `\(installPath.lastPathComponent)` at \(installed.path).\n\nIf this is the first install, restart your terminal so the new command is on PATH. | %@ 명령을 %@에 설치했어요.<br><br>명령을 찾을 수 없다면 새 터미널을 열고 설치 폴더가 PATH에 포함되어 있는지 확인하세요. | Installed %@ at %@.<br><br>If the command is not found, open a new terminal and check that the install folder is on PATH. |
| `shellCommand.ok` | OK | 확인 | OK |
| `shellCommand.reinstall` | Reinstall | 다시 설치 | Reinstall |
| `shellCommand.removed.body` | Removed `\(installPath.lastPathComponent)` from \(installPath.path). | %@ 명령을 %@에서 삭제했어요. | Removed %@ from %@. |
| `shellCommand.stale.body` | `\(installPath.lastPathComponent)` is installed at \(path.path) but points at a different Picky.app:\n\(pinned)\n\nReinstall to point it at the running Picky.app, or uninstall. | %@ 명령(%@)이 다른 Picky.app을 사용하고 있어요:<br>%@<br><br>현재 앱을 사용하려면 다시 설치하세요. 명령을 삭제할 수도 있어요. | The %@ command at %@ uses a different Picky.app:<br>%@<br><br>Reinstall to use the current app, or uninstall the command. |
| `shellCommand.uninstall` | Uninstall | 설치 삭제 | Uninstall |
| `shellCommand.uninstallFailed` | Uninstall failed | 삭제하지 못했어요 | Uninstall failed |
| `shortcut.capture.doubleTap` | Captured as a double-tap. | 두 번 누르기로 입력됐어요. | Captured as a double-tap. |
| `shortcut.capture.focusHint` | Press left and right Command together, double-tap a modifier, or hold modifiers + key. | 양쪽 Command를 함께 누르거나, 보조 키를 두 번 누르거나, 보조 키와 다른 키를 함께 누르세요. | Press left and right Command together, double-tap a modifier, or hold modifiers + key. |
| `shortcut.capture.pendingCommand` | Add a key, tap the modifier again, or press the other Command. | 다른 키를 함께 누르거나, 같은 보조 키를 한 번 더 누르거나, 반대쪽 Command를 누르세요. | Add a key, tap the modifier again, or press the other Command. |
| `shortcut.capture.pendingModifier` | Add a key, or tap the same modifier once more. | 다른 키를 함께 누르거나, 같은 보조 키를 한 번 더 누르세요. | Add a key, or tap the same modifier once more. |
| `shortcut.capture.pttHint` | Press a shortcut. e.g. ⌃⌥, or ⌃⌥+space. | 단축키를 누르세요. 예: ⌃⌥ 또는 ⌃⌥+스페이스. | Press a shortcut. e.g. ⌃⌥, or ⌃⌥+space. |
| `shortcut.capture.quickInputHint` | Press a shortcut. Tap the same modifier twice for a double-tap, or hold modifiers + key for a combo. | 같은 보조 키를 두 번 누르거나, 보조 키와 다른 키를 함께 누르세요. | Press a shortcut. Tap the same modifier twice for a double-tap, or hold modifiers + key for a combo. |
| `shortcut.capture.unsupported` | This key can’t be used as a shortcut. Try another one. | 단축키로 사용할 수 없는 키예요. 다른 키를 눌러 주세요. | This key can’t be used as a shortcut. Try another one. |
| `terminal.alreadyOpen` | Pi terminal is already open for this session. | 이 대화의 Pi 터미널이 이미 열려 있어요. | The Pi terminal is already open for this conversation. |
| `terminal.attached` | Attached to \(compactPath(sessionFilePath))<br>Attached to \(self.compactPath(self.sessionFilePath)) | 대화 파일: %1$@ | Conversation file: %1$@ |
| `terminal.closeHint` | ⌘W / close syncs once | 닫으면 동기화 시도 · ⌘W | Close to try syncing · ⌘W |
| `terminal.exited` | Pi terminal closed. Close to sync the session card. | Pi 터미널이 종료됐어요. 창을 닫으면 대화 동기화를 시도해요. | Pi terminal exited. Close this window to try syncing the conversation. |
| `terminal.exitedWithCode` | Pi terminal exited with code \(exitCode). Close to sync the session card. | Pi 터미널이 종료됐어요(코드 %1$lld). 창을 닫으면 대화 동기화를 시도해요. | Pi terminal exited (code %1$lld). Close this window to try syncing the conversation. |
| `terminal.openFailed` | Failed to open Pi terminal: \(message) | Pi 터미널을 열지 못했어요: %1$@ | Could not open the Pi terminal: %1$@ |
| `terminal.resetZoom` | Reset Zoom | 기본 크기 | Reset Zoom |
| `terminal.sessionFileMissing` | Session file does not exist: \(sessionFilePath) | 대화 파일을 찾을 수 없어요: %1$@ | Conversation file not found: %1$@ |
| `terminal.startFailed` | Pi terminal failed to start. Close and try again. | Pi 터미널을 시작하지 못했어요. 창을 닫고 다시 열어 주세요. | Could not start the Pi terminal. Close this window and open it again. |
| `terminal.starting` | Starting pi --session… | Pi 터미널 여는 중… | Opening Pi terminal… |
| `terminal.waitingForPrevious` | Waiting for the previous Pi terminal to close… | 이전 Pi 터미널이 종료되기를 기다리는 중… | Waiting for the previous Pi terminal to close… |
| `terminal.zoomIn` | Zoom In | 확대 | Zoom In |
| `terminal.zoomOut` | Zoom Out | 축소 | Zoom Out |

## 기존 번역을 재사용하도록 연결한 화면

번역 자체를 바꾸지 않고 하드코딩을 제거한 항목이다.

| 화면 파일 | Before | After (한국어) | After (영어) |
|---|---|---|---|
| `Picky/App/ShellCommandMenuController.swift` | Cancel | 취소 | Cancel |
| `Picky/QuickInput/QuickInputPanelView.swift` | Send | 보내기 | Send |
| `Picky/QuickInput/QuickInputPanelView.swift` | Close | 닫기 | Close |
| `Picky/Overlay/PickyMainActivityChipPolicy.swift` | 생각 중 | 생각 과정 | Thinking |
| `Picky/Overlay/PickyMainActivityChipView.swift` | .accessibilityValue(model.isRunning ? "Running" : "Completed") | 실행 중 | Running |
| `Picky/Overlay/PickyMainActivityChipView.swift` | .accessibilityValue(model.isRunning ? L10n.t("hud.conversation.status.running") : "Completed") | 실행 중 | Running |
| `Picky/Overlay/PickyMainActivityChipView.swift` | .accessibilityValue(model.isRunning ? L10n.t("hud.conversation.status.running") : "Completed") | 완료 | Completed |
| `Picky/HUD/PickyHUDLayoutPolicy.swift` | Failed | 실패 | Failed |
| `Picky/HUD/PickyDockGroupCreatorView.swift` | Cancel | 취소 | Cancel |
| `Picky/HUD/PickyHUDDockIconView.swift` | Running | 실행 중 | Running |
| `Picky/HUD/PickyHUDDockIconView.swift` | Completed | 완료 | Completed |
| `Picky/HUD/PickyHUDDockIconView.swift` | Failed | 실패 | Failed |
| `Picky/HUD/Conversation/Bubbles/PickyAgentBubbleSurfaceView.swift` | let item = NSMenuItem(title: "Copy Text", action: #selector(copyTextClicked), keyEquivalent: "") | 텍스트 복사 | Copy Text |
| `Picky/HUD/Conversation/Bubbles/PickyAgentBubbleSurfaceView.swift` | let item = NSMenuItem(title: "Open as Report", action: #selector(openAsReportClicked), keyEquivalent: "") | 리포트로 열기 | Open as Report |
| `Picky/HUD/Conversation/Bubbles/PickyToolCallInlineRow.swift` | Failed | 실패 | Failed |
| `Picky/HUD/Conversation/Bubbles/PickyToolCallInlineRow.swift` | Running | 실행 중 | Running |
| `Picky/HUD/Conversation/Bubbles/PickyToolCallInlineRow.swift` | Completed | 완료 | Completed |
| `Picky/HUD/Conversation/Bubbles/PickyMarkdownInlineTextView.swift` | let item = NSMenuItem(title: "Copy Text", action: #selector(copyTextClicked), keyEquivalent: "") | 텍스트 복사 | Copy Text |
| `Picky/HUD/Conversation/Bubbles/PickyMarkdownInlineTextView.swift` | Open as Report | 리포트로 열기 | Open as Report |
| `Picky/HUD/Conversation/Bubbles/PickyQuestionBubbleView.swift` | Cancel | 취소 | Cancel |
| `Picky/HUD/Conversation/Bubbles/PickyUserBubbleSurfaceView.swift` | let item = NSMenuItem(title: "Copy Text", action: #selector(copyTextClicked), keyEquivalent: "") | 텍스트 복사 | Copy Text |
| `Picky/HUD/Conversation/Bubbles/PickyUserBubbleSurfaceView.swift` | let item = NSMenuItem(title: "Open as Report", action: #selector(openAsReportClicked), keyEquivalent: "") | 리포트로 열기 | Open as Report |
| `Picky/Companion/CompanionPanelSettingsView.swift` | settings.dock.size.label | 도크 크기 | Dock size |
| `Picky/Hub/Plugins/PickyHubPluginCardView.swift` | title: isHoveringInstalledAction ? "hub.plugins.card.remove" : "hub.plugins.detail.installed", | 삭제 | Remove |
| `Picky/Hub/Pages/PickyHubSettingsPage.swift` | title: granted ? "hub.settings.permission.granted" : "hub.settings.permission.required", | 허용됨 · 시스템 설정 | Granted · System Settings |
| `Picky/Hub/Settings/PickyHubPermissionAction.swift` | func perform( | 확인 필요 · 시스템 설정 | Needs review · System Settings |
| `Picky/HUD/Conversation/Bubbles/PickyErrorBubbleView.swift` | hud.error.retry | 다시 시도 | Retry |

## 검증 범위의 한계

실행 중인 Picky는 종료하거나 재시작하지 않았다. 실제 화면의 줄바꿈·잘림, VoiceOver 낭독, 권한 대화상자와 외부 서비스의 응답은 이번 정적 검수만으로 검증하지 않았다. 보관 삭제는 전송 실패시 목록을 유지하지만, 전송 성공 뒤 서버가 거부하는 경우의 확인 응답 처리는 기존 한계로 남아 있다.
