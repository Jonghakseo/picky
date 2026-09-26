# Pickle 비동기 작업 런타임 검증

2026-09-26 · Pi · W8 로컬 활성화 및 후속 UI 수정

W8의 실앱 기록과 후속 수정의 자동 검증을 구분한다. 후속 UI 수정 중에는 실행 중인 앱을 교체하거나 재시작하지 않았다.

---

> **구현·로컬 활성화 완료, 네이티브 E2E는 부분 통과.** 실제 앱에서 발견한 완료 후 복원 문제를 `889e3f341`에서 수정했다. 수정된 코드의 저장·프로토콜 E2E는 통과했지만, 후반에 macOS 화면이 잠겨 실앱의 복원 클릭 경로를 다시 확인하지 못했다.

## 적용 범위

활성화 커밋은 `ae02e93b5`, 완료 후 복원 수정은 `889e3f341`이다. Picky에 검증한 `bash-async 0.2.1`과 `subagent 0.5.7`을 포함하고, 실제 provider 협상이 된 Pickle에서 비동기 실행을 허용한다. 원본은 로컬에서 만든 미공개 pack이며, 버전 문자열뿐 아니라 69개 파일의 해시를 고정했다. 전역 Pi 패키지·설정 교체, npm publish, GitHub release, push는 하지 않았다.

일반 확장의 다른 도구는 유지하면서 예약된 비동기 이벤트 채널을 격리했다. 패키지 검증 실패 시 legacy async 도구로 우회하지 않으며, SDK 초기 로드와 `/reload`가 누락된 전역 패키지를 자동 설치하지 않게 했다.

## 자동 검증

| 경계 | 실행한 검증 |
| --- | --- |
| Provider 원본과 pack | 필수 strict gate 1,463개 통과. coverage 실행은 같은 테스트의 반복이며 합산하지 않았다. 두 tarball과 추출한 69개 파일의 해시를 확인했다. |
| 실제 SDK와 패키지 의존성 | 패키징된 provider를 사용한 admission 통합 20개 통과. Picky SDK 0.87.1, 별도 고정 의존성으로 실행했다. |
| W8 로더·활성화·제어 | 관련 SDK/bridge/bootstrap 테스트 151개 통과, 기존 skip 1개. 타입·린트·아키텍처 검사와 커밋 훅 통과. |
| 컴파일된 production daemon | 임시 HOME와 포트에서 실제 두 provider를 로드했다. WebSocket v2와 저장 상태가 ready → 실제 실행 → 결과 처리 → completed로 이어졌다. |
| 혼합 확장 충돌 | 경쟁 handshake를 보내는 일반 확장의 예약 프레임 수신은 0건이었다. 다른 도구·일반 이벤트·reload 정리는 유지됐다. |
| 접수 중단과 재개 | drain 상태에서 새 spawn은 거부하고 기존 작업·결과를 유지했다. 기존 작업 정착 후 on으로 새 실행을 수락했다. |
| 완료 후 owner 교체 | 관련 412개 테스트와 실제 pack 20개 테스트를 통과했다. 별도 컴파일 daemon 두 개에서 보관·종료·복원·새 실행을 거쳤다. 실제 spawn 2개, handled ticket 2개, 서로 다른 owner와 bootstrap epoch를 확인했다. 이전 승인은 재사용하지 않았다. |

컴파일 daemon 검증에는 격리 모델과 유한한 자식 프로세스를 사용했다. 아래 실제 앱·모델 검증과 같은 것으로 세지 않는다. W6·W7의 Swift replay, 렌더, 18개 인접 테스트는 변경되지 않은 경계의 기존 증거로 재사용했다.

## 실제 앱에서 확인한 동작

Xcode 16.3과 공유 DerivedData로 빌드했다. 기존 개발 인증서와 `com.jonghakseo.picky.dev`, 기존 실행 경로를 유지했다. 서명·실행 프로세스·빌드 SHA·앱 내부의 69개 provider 파일을 확인했다. 전역 Pi 설정 파일의 해시도 그대로였다.

실제 `gpt-6-sol` 모델을 사용하는 무해한 테스트 피클과 유한한 `sleep` 작업을 사용했다. CLI로 만든 primary-hosted 피클뿐 아니라 앱의 최근 폴더 버튼으로 만든 per-Pickle child도 실행했다.

| 동작 | 관찰 결과 |
| --- | --- |
| bash_async와 subagent의 비동기 반환 | 두 도구가 반환하고 Pi가 응답한 뒤에도 실제 작업과 Pickle은 실행 중이었다. tracking ready, active root와 해제 금지를 확인했다. |
| 자동 완료 전달 | 자연 종료 뒤 각 ticket이 handled, active/pending이 0, runtime 해제 가능 상태가 됐다. 실제 Pi 저널에서 완료 응답이 각각 1개임을 확인했다. |
| Pi가 응답을 끝낸 동안 추가 입력 | 기존 bash 작업을 유지한 채 새 요청에 `W8_NATIVE_INPUT_ACCEPTED`로 응답했다. |
| 한 행 표시 | 네이티브 AX에서 작업명·실행 중 상태·시간의 y 좌표가 같은 행이었다. 터미널 행은 908.5/908.5/909였다. 시간은 별도 메타정보 행이 아니었다. |
| 상세와 개별 중지 | UI에서 subagent 상세를 펼쳤다. bash만 중지하자 bash는 cancelled/settled, subagent는 running/active로 남았다. |
| 입력 초안 유지 | `W8 draft 유지 가나`를 입력했다. 작업 중지·결과 반영·완료 경합 안내 뒤에도 값이 유지됐다. 실제 IME marked text 검증은 아니다. |
| 보관 선택과 경합 | 무옵션 CLI 보관을 거부했다. UI에서 두 보관 선택을 확인했다. 확인창 도중 작업이 완료되면 stale 작업 상태로 보관하지 않고 오류를 표시했다. |
| 계속 실행하며 보관 | UI에서 선택한 뒤 archivedAt이 저장되고 작업은 running/ready, active root 1, 해제 불가로 유지됐다. Dock의 보관된 작업 버튼도 눌러 목록을 열었다. |
| 실패와 전체 중지 후 보관 | exit 7 작업은 failed/settled였다. 별도의 실행 중 작업을 stopThenArchive로 중지했고 cancelled/settled, ticket suppressed, active/pending 0, 해제 가능 상태를 확인했다. 실제 primary daemon 아래 테스트 sleep도 남지 않았다. |
| 완료·해제 후 복원 | 새 child가 reconciling/closed에 머물러 입력을 거부하는 문제를 발견했다. 수정 후 실제 pack을 쓰는 두 컴파일 daemon의 재실행·저장·v2 경로는 통과했다. 설치 앱의 같은 클릭 경로는 화면 잠금으로 재검증하지 못했다. |

CLI의 `Queued` 응답만으로 입력 실행을 통과 처리하지 않았다. 복원 실패에서는 실제 daemon 오류와 저장 상태를 확인했다. 스크린샷은 남겼지만 이 세션의 이미지 읽기 도구가 비활성화되어 픽셀을 직접 검수하지 못했다. 위 UI 판정은 실제 AX 요소·좌표·조작 뒤 상태를 근거로 한다.

수정된 앱은 같은 인증서·경로로 실행 중이며 rollout은 `on`이다. 설치된 복원 policy의 SHA256은 두 daemon 검증에 사용한 코드와 일치한다. 화면 잠금은 Peekaboo가 `Screen capture is unavailable while the macOS GUI session is locked`로 보고했다. 잠금을 우회하지 않았다.

## 검증 중 처리한 문제와 환경 변화

- 미검증 provider 우회, SDK reload의 자동 설치, 혼합 확장의 이벤트 충돌, 패키징 helper의 캐시 누락을 수정했다. 독립 검토에서 네 지적을 종결했다.
- drain으로 거부한 작업의 no-spawn 갱신이 이전 실행까지 unsupported로 만들던 문제를 실제 패키지 E2E에서 재현하고 수정했다.
- 종료 승인을 받은 보관 세션의 증거를 재로딩 때 지우던 문제를 수정했다. 보관 의도·작업 revision·owner·generation·저널이 모두 일치하는 종료 상태만 유지한다. 복원은 새 owner를 붙인 뒤 이전 승인을 폐기하며, 새 provider 협상 전에는 입력을 거부한다. 이미 증거가 지워진 기록을 추정으로 복구하지 않는다.
- 첫 서명은 인증서 한글 이름 조회에서 실패했다. 작은 실행 파일로 재현한 뒤 **같은 인증서의 SHA**를 지정해 성공했다. 인증서·팀·서명 기본 설정을 바꾸지 않았다.
- 앱을 활성화·보완·정리하며 재시작한 동안 기존 보관 세션 **5개가 7일 보존 정책으로 정리됐다**. 세 차례 로그에 각각 2/1/2개 ID와 `retentionDays=7`이 남았다. 기존 24개 중 19개가 남았고 보관 여부는 유지됐다. 보관된 빈 입력 대기 피클 1개는 waiting_for_input에서 cancelled로 바뀌었다.
- 내가 만든 테스트 피클 3개는 실제 작업·결과가 모두 정착한 것을 확인한 뒤 앱을 종료하고 저장 디렉터리/파일을 `.audit/pickle-async-tasks/w8/quarantined-fixtures/`로 옮겨 원본 그대로 보존했다. 증거를 만들어 차단을 해제하지 않았다. 테스트 그룹을 제거했고 실행 중인 QA는 남기지 않았다.

## 확인된 제한

**종료 승인 증거가 없는 이전 owner는 자동 재개되지 않는다.** 실제 CLI 생성 피클 2개도 전체 앱 재시작 후 `blocked/reconciling`으로 남았다. 작업·ticket이 끝났다는 필드만으로 owner 종료 승인을 추정하지 않는 현재 동작이다. W8의 복원 수정은 유효한 종료 승인이 저장된 child에 한정되며, 이 사례까지 자동 재개할 수 있다고 보고하지 않는다. 이후 사용자 요청에 따라 명시적 보관 삭제는 이 제약과 분리한다. 과거 owner가 없거나 상태를 확인 중이라는 이유로 삭제 버튼을 막지 않고, 연결된 실행의 정리는 삭제 경로가 처리한다. 자동 재개가 불가능한 경우 새 피클을 사용하거나 기존 보관 기록을 명시적으로 삭제할 수 있다.

## 후속 UI·명시적 삭제 검증

2026-09-26 후속 요청에 따라 재진입 때의 상태 확인 안내와 빈 작업 영역을 제거했다. 실제 작업·결과·불명 실행·오류는 유지한다. 보관 목록은 이름·경로·복원·삭제만 표시하며, ‘보관된 피클 전체 삭제’는 실행 상태나 상세 로딩 여부로 대상을 제외하지 않는다. 연결된 실행은 삭제 과정에서 정리한다. HUD와 CLI는 삭제 ACK를 최대 30초 기다리며, 그 전에 자동 해제가 child를 종료하지 못하도록 막는다. 자동 해제·TTL·복원 조건은 별도로 유지한다.

- Xcode 16.3에서 선택한 46개 메서드 중 44개가 먼저 통과했다. 나머지 두 테스트에 남아 있던 이전 삭제 정책과 테스트용 5초 기본값을 수정한 뒤 재실행했다. 이 두 건과 명시적 타임아웃·렌더 생성까지 총 4개 메서드가 통과했다. 실행 중·대기 중인 보관 항목의 삭제, 보관하지 않은 항목 보존, ACK 이전 보존, 실패·복원·자동 해제 경합을 확인했다.
- production v2 저장소를 거친 재진입에서 전체·축약 작업 영역의 높이가 모두 0이었다. 실제 작업이 오면 각각 90pt·36pt로 표시됐고, 불명 실행과 오류도 유지됐다. 새 오프스크린 PNG 80개를 생성했다. OCR에서 ‘보관된 피클 전체 삭제’, 복원·삭제와 작업명·상태·시간의 한 행 표시를 확인했다. 이미지 읽기 도구가 비활성화되어 직접 픽셀 검수나 실제 창 조작으로 보고하지 않는다.
- backend의 최종 19개 테스트가 통과했다. 실제 패키지·네이티브 자식·v2 WebSocket 경로에서 실행 중인 보관 항목의 삭제가 약 7.8초 걸렸고, 자식 종료 후 ACK, 저장소 제거, 재연결 시 항목 부재를 확인했다. 정리·저장 실패 시 기록을 유지하는 경우도 검증했다.
- 구조 검사, 디자인 토큰 검사, 번역 검사, TypeScript typecheck·build·변경 파일 lint가 통과했다. 구조 검사의 기존 경고 4개는 유지한다. 앞선 별도 검증에서 발견한 `galleryEnglishLocalizationOverridesAndRestoresKoreanLocaleState()`의 기존 ‘피클’/‘Pickle’ 기대값 불일치는 수정하지 않았다.

이번 후속 작업에서는 실행 중인 앱을 재시작하거나 실제 사용자 기록을 삭제하지 않았다. 원시 실패 기록, 최종 xcresult, 소스 해시와 렌더는 로컬 `.audit/pickle-async-tasks/ui-feedback/`의 `final-reentry-delete-r3*`, `final-reentry-delete-r4*`, `final-reentry-gallery/`, `explicit-delete-after-refactor-*`에 보존했다.

## 사용자가 추가로 확인할 항목

- [ ] **수정 후 실앱 복원**을 먼저 확인한다. UI에서 새 피클을 만들고 60초짜리 bash_async를 시작한다. 계속 실행하며 보관하고 완료를 기다린 뒤 복원해 `OK만 답해`를 보낸다. 응답하고 새 작업도 시작되며, 과거 완료 결과가 다시 전달되지 않아야 한다.
- [ ] 한국어 IME 조합 중 작업이 시작·완료돼도 조합 문자열과 포커스가 유지되는지 확인한다.
- [ ] 라이트·다크 모드와 130% 글꼴에서 긴 제목, 여러 자식, 긴 오류가 잘리지 않는지 확인한다.
- [ ] 보관 버튼이 가로·세로 모두 Dock 안에 있는지 확인한다. 보관 목록에는 이름·경로와 복원·삭제만 보여야 한다. ‘보관된 피클 전체 삭제’는 실행 중·상태 확인 중인 항목도 포함해야 한다. 작업 상세·중지는 복원한 피클에서 확인한다. 이는 W8 이후 사용자 요청 기준이며, 보관 목록 안의 작업 제어를 확인하던 이전 항목을 대체한다.
- [ ] 기존 피클에 다시 들어갈 때 ‘백그라운드 작업 확인 중’ 영역이나 빈 여백이 잠깐 나타나지 않는지 확인한다. 실제 작업·결과·오류는 계속 확인할 수 있어야 한다.
- [ ] VoiceOver와 키보드만으로 상세·개별 중지·보관 선택·복원에 접근하는지 확인한다.
- [ ] macOS 완료 배너·소리가 원하는 설정에서 한 번만 나타나는지 확인한다. ticket과 응답 1회 검증은 OS 배너 검증의 대체가 아니다.
- [ ] 실제 batch/chain/continue, 작업 여러 개와 그룹 보관을 평소 사용 방식으로 확인한다. 실패 행렬의 자동 증거와 전체 네이티브 조작 검증을 구분한다.
- [ ] 긴 세션·대량 출력에서 스크롤과 타이핑이 지연되지 않는지 확인한다. 이번 작업에서 FPS나 body/layout signpost 성능을 측정하지 않았다.
- [ ] 강제 daemon 종료, 네트워크 단절, 디스크 저장 실패 상황은 격리 환경에서 확인한다. 실제 사용자 작업에 장애를 주입하지 않았다.

## 접수 중단과 증거 위치

새 작업 접수만 중단하고 기존 작업의 추적·결과·중지를 유지하려면 다음 명령을 사용한다. 재개할 때는 마지막 인자를 `on`으로 바꾼다.

```bash
node scripts/set-async-task-rollout.mjs "$HOME/Library/Application Support/Picky" drain
```

로컬 증거는 `.audit/pickle-async-tasks/w8/`에 있다. 주요 파일은 `committed-candidate-file-hashes.tsv`, `mixed-compiled-final.log`, `compiled-*-summary.json`, `native-result-consumption-proof.json`, `native-ui-active.json`, `native-ui-after-root-stop.json`, `ui-draft-before-details.json`, `primary-after-stop-archive.json`, `native-release-restore-trace.log`, `compiled-released-owner-final.json`, `recovery-ui-pixels.json`, `fixture-cleanup-result.json`, `native-ui-running.png`다. 원래 실패 로그도 보존했다.
