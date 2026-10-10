# Picky 정식 출시 준비 체크리스트

기준 커밋 `a6228c29c`(0.14.4 직후). 9개 영역을 읽기 전용으로 점검한 결과다. P0와 핵심 근거는 코드에서 다시 확인했다. 파일:라인은 점검 시점 기준이라 수정이 진행되면 어긋날 수 있다.

**2026-10-10 갱신**: 판단 없이 처리할 수 있는 항목을 11개 레인으로 나눠 반영했다(커밋 `90f8d53e1`..`ad3ac14fa`). 처리한 항목은 `[x]`와 커밋 해시로, 일부만 처리한 항목은 `(부분)`으로 표시했다. 새로 드러난 항목은 5장에 모았다.

- **P0**: 출시 차단. 데이터 손실, 보안, 크래시, 첫 실행 실패
- **P1**: 출시 전에 처리 권장
- **P2**: 출시 후 처리 가능

항목을 끝내면 체크하고, 처리한 커밋이나 PR을 줄 끝에 적는다.

## 0. 먼저 정할 것

코드만으로 끝나지 않는 항목이다. 아래 작업 일부가 이 결정에 달려 있다.

- [ ] 최종 bundle ID와 appcast 저장소 소유자. 지금은 `com.jonghakseo.picky`와 `Jonghakseo/picky`다. 출시 후에 바꾸면 TCC 권한, 키체인, 업데이트 피드가 끊긴다.
- [ ] Pi CLI가 필수인지. 일반 대화는 번들 SDK로 돌지만, Cron 설치에는 `pi` 바이너리가 필요하다.
- [ ] 가이드 콘텐츠. `hub-guides.json`을 채울지, 준비될 때까지 섹션을 숨길지 정한다.
- [ ] Intel Mac 지원 여부. 지금 Node는 arm64만 번들된다.

## 1. P0: 출시 차단

### 1.1 데몬 비정상 종료와 무표시 실패

- [x] 메인 에이전트 이벤트 처리 격리. `agentd/src/application/main-agent-coordinator.ts:925`의 `void this.applyMainRuntimeEvent(...)`에 catch가 없다. `picky.json` 쓰기가 실패하면 `agentd/src/extension-crash-guard.ts:100`이 다시 던져 데몬이 종료된다. `90f8d53e1` (Pickle 런타임 이벤트 구독부의 같은 패턴도 함께 막음)
- [x] 시작 시 세션 복원을 세션 단위로 격리(`agentd/src/session-supervisor.ts:255`, `agentd/src/main.ts:48`). 실패한 세션만 blocked로 둔다. `90f8d53e1`
- [x] 런처 재시작 횟수에 상한을 둔다(`Picky/PickyAgentDaemonLauncher.swift:1011-1023`). `601f3fca3` (연속 5회, 30초 넘게 살면 리셋)
- [ ] (부분) 데몬 상태(기동 실패, 재시작 중, 크래시)를 Hub와 HUD에 표시하고 원인별 복구 안내를 붙인다. 대상: Node 없음·구버전(`:955-960`, `:1043-1053`), 포트 17631 점유(`:1055`). 지금은 이 상태를 구독하는 UI가 없다(`Picky/PickyApp.swift:312`). `601f3fca3`에서 원인별 `terminalFailure`를 공개했고, 표시 UI 형태는 결정 대기다.
- [x] 회귀 테스트: 상태 파일 쓰기 실패와 손상 세션 하나가 있어도 데몬이 살아 있고 나머지 세션이 복원되는지 `90f8d53e1`

## 2. P1: 출시 전 권장

### 2.1 안정성과 데이터 보존

- [x] 손상된 `picky.json`을 빈 상태로 덮어쓰지 않게 한다. 원본을 `.corrupt-<ts>`로 옮겨 둔다(`agentd/src/session-store.ts:104-111`). `90f8d53e1`
- [x] 스키마 검증에 실패한 세션 파일이 독에서 조용히 사라지지 않게 한다. 파일을 보존하고 진단을 남긴다(`session-store.ts:199-213`). `90f8d53e1` (`.corrupt-<ts>`로 보존, UI 안내는 없음)
- [ ] 과거 버전 세션 JSON 픽스처로 마이그레이션 회귀 테스트를 추가한다.
- [ ] 세션 쪽 오류를 사용자에게 보여 줄 채널을 만든다. `PickySessionViewModel.lastError`는 약 50곳에서 쓰는데 읽는 곳이 없다. 이름 변경, Rewind, 그룹 작업, 재연결 오류가 모두 화면에 나오지 않는다.
- [ ] 중단된 작업이 unknown 상태로 남아 런타임 해제를 막는 문제를 확인한다. HUD에서 사용자가 정리할 경로가 있는지 본다(관련 커밋 `cbedb577f`, `537b2ab3f`, `50a8561ba`).

### 2.2 첫 실행과 온보딩

- [ ] 온보딩에 AI 계정 연결 단계와 상태 확인을 추가한다(`Picky/Hub/Pages/PickyHubDashboardPage.swift:96-115`). 인증 없이 보내면 첫 모델로 폴백하는 동작(`agentd/src/runtime/pi-model-resolution.ts:132-137`)도 검토한다.
- [ ] README와 매뉴얼 §1의 Pi 요구사항을 실제 동작에 맞춘다(`README.md:82`, `docs/user-manual.md:13-32`).
- [ ] Cron 설치 전에 `pi` 바이너리를 확인하고 사용자용 문구를 보여 준다(`agentd/src/application/cron-package-lifecycle.ts:96-98`, `Picky/App/PickyCuratedPluginInstaller.swift:61-69`).
- [ ] 화면 기록 허용이 감지되면 "다시 시작" 버튼을 띄운다(`PickyRelauncher` 재사용, `Picky/App/Settings/PickyRestartRequirement.swift`).
- [ ] 화면 기록 false negative 보정 함수를 실제 게이트에 연결하거나 제거한다(`Picky/App/WindowPositionManager.swift:87-112`, 호출처는 테스트뿐).
- [ ] 로그인 시 자동 실행: 동의를 받거나 설정 토글을 둔다. 사용자가 끈 상태를 다시 켜지 않는다(`Picky/PickyApp.swift:911-921`).
- [ ] 지원 아키텍처를 README에 명시한다. Intel에서 나오는 "재설치" 안내를 고친다(`PickyAgentDaemonLauncher.swift:970-983`).

### 2.3 빌드와 배포

- [x] 릴리즈 워크플로에 Xcode 16.3 고정과 검증 단계를 추가한다. 지금은 `runs-on: macos-15`만 지정한다(`beta-notarized-release.yml:72,532`, `docs/known-issues/xcode-26-3-isolated-deinit.md`). `2b476b70d`
- [x] appcast 갱신을 고정 concurrency 그룹으로 직렬화한다. 다운로드 실패를 `|| true`로 넘기지 않는다(`beta-notarized-release.yml:44-45,628,640`, `scripts/update-sparkle-appcast.py:42-45`). `2b476b70d` (`--require-existing`, `--require-no-shrink`)
- [x] 서드파티 고지 전수 수집. 대상: Node, npm, Sparkle, SwiftTerm, Pi SDK, `agentd/node_modules`, 폰트. 앱 안에 라이선스 화면을 둔다(현재 `THIRD_PARTY_NOTICES.md`에는 msedge-tts만 있다). `5511225d7` (앱 안 라이선스 화면은 미구현, 번들 Resources에 고지 포함)
- [x] 롤백·회수 runbook을 작성한다. 내용: appcast 항목 제거, 높은 build number의 핫픽스, 사용자 안내. `357564612` (`runbook/rollback.md`, 실제 절차 리허설 전)
- [x] 릴리즈 산출물에서 Node entitlement를 확인한다: `codesign -d --entitlements :- Picky.app/Contents/Resources/agentd-runtime/bin/node`에 `allow-jit`가 남아 있어야 한다. `2b476b70d` (워크플로 assert로 자동화. 임시 번들 실험에서 `--deep`이 Resources의 node를 건드리지 않음을 확인)

### 2.4 프라이버시와 디스크

- [ ] 턴마다 캡처한 스크린샷(`$TMPDIR/Picky/Screenshots/`)의 보존 정책과 정리를 구현한다(`Picky/Context/PickyAppSupport.swift:88-131`). 후속 턴이 같은 경로를 다시 읽는지 먼저 확인한다.
- [ ] Task 기록(`context.json`, `session.jsonl`, `tasks.json`)의 보존 기간과 삭제 경로를 정한다(`agentd/src/runtime/task/store.ts`, `docs/picky-task-routing-plan.md:331`).
- [x] 데몬 로그 회전이 자식 데몬과 같은 파일을 공유해도 상한을 지키게 한다(`PickyAgentDaemonLauncher.swift:753,1097-1108`, `PickyAgentDaemonPool.swift:193,209`). `601f3fca3`
- [ ] 긴 세션(메시지 1,000개 이상)에서 세션 저장 시간을 측정한다. 결과가 나쁘면 append형 저장으로 바꾼다(`session-store.ts:74`).

### 2.5 검증 게이트

- [ ] (부분) PR CI에 `pnpm --dir agentd run test:ci`와 Swift 오프스크린 suite를 추가한다. 릴리즈 `publish-release`가 이 결과에 의존하게 한다. 지금 CI에는 lint만 있다. `e452693fc`, `2b476b70d` (agentd만. Swift suite의 CI 편입은 macOS 러너 비용 결정 대기)
- [x] `typecheck:web`을 pre-push나 build에 연결한다(`agentd/package.json:19`). `e452693fc` (pre-push와 CI)
- [x] 원격 gateway Swift 통합 테스트(`PICKY_REMOTE_GATEWAY_INTEGRATION=1`)를 어느 게이트에서든 실행한다. `e452693fc` (pre-push 오프스크린 suite)
- [ ] Remote 실기기 확인 6항목을 끝내고 결과를 기록한다: 재시작한 실제 앱, iPhone 홈 화면 앱, Tailscale Serve, 폰의 Cloudflare 접속, 잠긴 폰 푸시, 맥 음성 인식(`docs/remote-pwa-plan.md:228`).
- [ ] Task 라우팅 실모델 검증과 패키지 앱 smoke(`docs/picky-task-routing-plan.md` 13.4).

### 2.6 콘텐츠, 문구, 접근성

- [ ] 가이드 피드를 채우거나 섹션을 숨긴다(`Picky/Resources/hub-guides.json`이 `[]`).
- [x] 매뉴얼의 Memory Layer·Cron 설치 "보류" 설명을 현행 정책에 맞춘다(`docs/user-manual.md:99`, `agentd/src/domain/curated-package-safety.ts`). `f0cd87a03`
- [x] 워치독 경고창을 현지화한다(`Picky/Watchdog/PickyWatchdogAlertHelper/main.swift:101-111`). `d20ca4d4f`
- [x] 재연결 오류 문구를 현지화하고 내부 용어를 뺀다(`PickyCapabilityRegistrationCoordinator.swift:121`). `d20ca4d4f` (단, 이 문구를 보여 줄 오류 채널은 2.1 `lastError` 항목과 함께 결정 대기)
- [x] 보고서 열기를 키보드와 VoiceOver로 쓸 수 있게 한다. Mac(`PickyAgentBubbleSurfaceView.swift:121,219`)과 PWA(`agentd/web/src/room/styles/room.css:569-585`, `Bubbles.tsx:67,97`) 모두 해당한다. `d1f533e4b`, `9a0d954a6` (VoiceOver 실기기 확인은 4장)

## 3. P2: 출시 후 가능

**보안**
- [ ] 기기 토큰 유휴 만료(예: 90일), 기기 목록에 마지막 사용 시각 표시(`agentd/src/gateway/device-store.ts`)
- [x] 업로드와 `tmp/` 정리를 주기 실행(`agentd/src/gateway/core.ts:115`) `cb6841ef6` (1시간 주기)
- [ ] 게이트웨이 Host 허용목록(`agentd/src/gateway/http/request-context.ts:84-96`). 보류: 게이트웨이가 터널 호스트를 모르고 Cloudflare Quick Tunnel 주소가 매번 바뀐다. 접미사 허용 여부 결정과 `PickyRemoteGatewayLauncher` 연동이 필요
- [x] PDF 미리보기에 sandbox CSP 적용(`agentd/web/src/screens/FilePreviewScreen.tsx:118-119`) `cb6841ef6` (sandbox는 PDF 뷰어를 막아 `script-src 'none'` 중심 CSP로 대체. iOS Safari 확인 필요)
- [x] 감사 로그의 `!` 명령 전문 마스킹(`agentd/src/gateway/command-executor.ts:117-124`) `cb6841ef6`
- [ ] 잠금화면 푸시에서 Pickle 제목 숨김 옵션(`agentd/src/gateway/push/push-copy.ts:45`)
- [ ] (부분) 세션 원자적 쓰기에 fsync 추가, 실패한 `.tmp` 정리. `.tmp` 정리와 경로별 쓰기 직렬화는 `90f8d53e1`. fsync는 저장마다 지연을 키워 async-task 통합 테스트를 부하 상황에서 흔들어 보류(HEAD 기준 2회 통과, fsync 포함 시 매회 1~2건 실패, fsync만 끄면 2회 통과로 확인)

**문구와 i18n**
- [x] 한국어 "피클"과 "Pickle" 혼용 13건 통일 `d20ca4d4f` (배지 말장난 4건 유지)
- [ ] (부분) 카탈로그의 ja/zh 잔여 18개와 미사용 키(약 114개, 동적 키 확인 후) 정리. ja/zh는 `d20ca4d4f`에서 삭제, 미사용 후보 113개는 동적 키 확인 대기
- [x] git push/pull 실패 알림 현지화(`PickyConversationContextLineView.swift:1183`) `d20ca4d4f`
- [ ] agentd 영어 요약·기본 제목을 표시 코드로 이동. Swift의 `"compacting"` 문자열 판별 제거
- [ ] 다음 행동이 없는 오류 문구 보강(질문 답변, 메시지 전송, Git 실패부터)
- [x] 플러그인 오류 문구에서 로그 경로 대신 피드백 보내기로 안내 `d20ca4d4f`
- [x] `docs/i18n-remediation-plan.md` 현행화 `d20ca4d4f`

**성능**
- [ ] 완료된 Pickle 자식 데몬의 RSS를 측정하고, 유휴 자식을 내리는 정책을 검토
- [x] 툴 이미지 버블 body에서 파일 `stat` 제거 `ad3ac14fa`
- [x] 첨부 썸네일 캐시 상한 `ad3ac14fa` (NSCache 64개)
- [x] 로그 파일 핸들 유지, 자식 stdout 줄 단위 Task 생성 제거 `601f3fca3`
- [x] `appendStdout`의 MainActor 격리 위반 여부 확인 `601f3fca3` (위반이 맞았고 relay로 메인 hop)
- [x] Swift 클라이언트 재연결에 지수 백오프 적용(`Picky/PickyAgentClient.swift:313,434-442`) `c8825e2a6` (상한 30초)

**품질 게이트**
- [ ] oxlint `correctness` 활성화(`agentd/.oxlintrc.json:4-5`)
- [ ] SwiftLint 경고 수 ratchet 또는 릴리즈 전 기록
- [ ] Swift 테스트 호스트 double-free 원인 분리(`scripts/pre-push-checks.sh:248-257`)
- [ ] PWA `check:web-taps`, `check:web-keyboard`를 자동 실행하거나 릴리즈 체크리스트에 포함
- [ ] Pi 실연동 통합 테스트 4종 실행 로그를 릴리즈 기록에 첨부
- [x] stable 태그와 최종 beta 커밋 일치, build number 증가를 워크플로에서 강제 `2b476b70d` (`check-lineage`)
- [x] 패키징 후 `releaseChannel`이 stable이나 beta인지 assert(`Picky/AppBundleConfiguration.swift:47-53`) `2b476b70d`
- [ ] (부분) DMG에 넣기 전에 앱을 staple(`beta-notarized-release.yml:384,428`). `2b476b70d`는 미staple을 경고로만 보고한다. 순서 변경은 공증 1회 추가(약 5분) 여부 결정 대기

**문서와 UI**
- [x] 매뉴얼의 사이드바 페이지 수(실제 9개)와 Web access 항목 반영 `f0cd87a03`
- [x] README 매뉴얼 앵커 수정(`#15-remote-access-from-your-phone` → `#15-web-access-this-macs-browser-and-your-phone`), Remote access와 Web access 명칭 통일 `f0cd87a03`
- [x] PWA `?demo=1` 진입점을 개발 빌드 전용으로 이동 `9a0d954a6`
- [x] 런북의 orphan running 설명 현행화(`runbook/log-debugging.md`) `357564612`
- [ ] Hub Action Blue(`#5284FF`)와 HUD 기준색(`#2563EB`) 통합, 토큰 린트 범위에 Hub 경로 추가
- [ ] 고대비 설정 대응(Mac, PWA)
- [ ] (부분) 독 행 키보드 포커스, 아이콘 버튼 3곳 접근성 라벨, 고정 폰트 2곳, QuickInput 버튼 상태. 독 행 외 나머지는 `d1f533e4b`
- [ ] 첫 실행 체크리스트에서 음성 전용 권한 분리, 권한 요청 실패 시 안내
- [ ] 화면 기록 확인 키의 옛 네임스페이스(`com.learningbuddy.*`) 정리 방침 결정

## 4. 실기기·실행으로 확인할 것

정적 점검으로는 판단하지 못한 항목이다.

- [ ] Pi CLI가 없는 맥에서 첫 실행, 일반 대화, Quick Input
- [ ] 번들 Node 실패와 포트 17631 점유 시 실제 화면
- [ ] `SMAppService.register()`가 사용자가 끈 로그인 항목을 다시 켜는지
- [ ] 인증 없이 보낸 첫 메시지의 오류 문구
- [ ] 화면 기록 false negative의 재현 조건과 macOS 버전별 차이
- [ ] 자식 데몬 N개 동시 실행 시 총 메모리, `agentd.stdout.log` 증가율
- [ ] 실제 VoiceOver 낭독(독 행, 모달 Esc)
- [ ] Tailscale Serve의 `X-Forwarded-For` 동작

## 5. 이번 작업에서 새로 드러난 항목

- [ ] **Claude Agent SDK 재배포 검토(P1).** `@anthropic-ai/claude-agent-sdk`와 `-darwin-arm64` 0.2.141은 독점 라이선스("All rights reserved")이고, 약 207MB 네이티브 `claude` 실행파일이 provider capsule로 앱에 들어간다. 재배포 가능 여부를 법무 판단으로 확정해야 한다.
- [ ] `standardwebhooks` 1.1.1의 라이선스 상충(package.json MIT, upstream LICENSE Apache-2.0). 고지에는 둘 다 적었다.
- [ ] 출처 불명 자산 `Picky/Assets.xcassets/steve.jpg`(코드 참조 없음)의 번들 포함 여부와 권리 확인.
- [ ] 서비스 로고(Figma, Slack, Claude 등)의 브랜드 가이드라인 준수 확인. 고지에는 상표 안내만 넣었다.
- [ ] 의존성이 바뀌면 `THIRD_PARTY_NOTICES.md`와 `licenses/npm-packages.txt`를 다시 만드는 스크립트를 `scripts/`에 추가.
- [ ] `Picky/PickyProcessRunner.swift`의 `readabilityHandler`가 EOF에서 분리되지 않는다. 자연 종료한 프로세스에서 핸들러가 계속 불릴 수 있다.
- [ ] 세션 파일 `.corrupt-<ts>` 사본의 보존 기간과 정리.
- [ ] 런처 재시작 상한(5회)과 재연결 상한(30초), 썸네일 캐시(64개)는 제안값이다. 실사용에서 조정한다.
- [ ] 에이전트 말풍선을 접근성 요소(`.group`)로 바꿨다. 자식 마크다운 텍스트가 VoiceOver에 계속 노출되는지 실기기 확인(4장과 함께).
- [ ] PWA 사용자 버블의 전송 시각은 포커스할 요소가 없어 스크린리더로만 읽힌다.
- [ ] Swift 테스트를 CI에서 돌릴지(macOS 러너 비용, `isolated-ui-tests.yml`에 `--swift-tests` 추가 방안).

