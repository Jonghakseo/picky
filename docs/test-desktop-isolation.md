# 테스트 데스크톱 격리

Picky의 대부분의 Swift 테스트는 오프스크린 렌더 또는 임시 상태로 실행된다. 이들은 로컬 개발자의 창, 포커스, 입력을 건드리지 않아야 한다. 반면 일부 계약은 WindowServer에서 실제 앱 활성화, key window, 외부 앱으로부터의 포커스 복귀를 확인해야 한다. 두 종류를 같은 로컬 pre-push에서 실행하면 사용 중인 데스크톱을 방해하고, 측정값도 사용자 활동에 흔들린다.

## 실행 경계

| 범위 | 실행 위치 | 대상 |
| --- | --- | --- |
| 일반 테스트와 오프스크린 계약 | 로컬 또는 일반 CI | 저장, 라우팅, 렌더 출력, 접근성 값 |
| WindowServer UI-effect 게이트 | GitHub-hosted `macos-15` VM | 실제 활성화, key-window 순서, Finder에서 Hub로의 포커스 지연 |

`.github/workflows/isolated-ui-tests.yml`만 UI-effect 모드를 호출한다. 이 워크플로는 고정된 GitHub-hosted `macos-15`와 `/Applications/Xcode_16.3.app/Contents/Developer`를 사용한다. self-hosted runner나 저장소 변수를 대체 경로로 쓰지 않는다. GitHub-hosted runner는 각 job에 새 VM을 제공하며, 해당 이미지의 Xcode 목록에 Xcode 16.3 경로가 명시되어 있다.

- [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [macOS 15 runner image, Xcode inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md#xcode)
- [Apple `NSApplication.ActivationPolicy.prohibited`](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/prohibited)

GitHub의 이미지 구성은 변할 수 있다. 따라서 `PICKY_DEVELOPER_DIR`의 Xcode 16.3이 사라지거나 Finder/WindowServer를 사용할 수 없으면, 스크립트가 실행 불가 또는 측정 불가로 실패해야 한다. 없는 데스크톱을 가짜 fixture나 재시도로 통과 처리하지 않는다.

## 소스와 정책의 분리

일반 push와 PR은 검사 대상 checkout의 `scripts/pre-push-checks.sh --ui-effects`를 실행한다. 릴리즈처럼 명시적 `ref`를 넘길 때는 해당 태그의 앱 소스를 checkout하고, 현재 기본 브랜치의 정책 스크립트를 `.ui-policy`에 별도로 checkout한다. 이는 오래된 태그가 UI 격리 명령을 포함하지 않아도 현재의 필수 검증을 적용하기 위한 것이다.

정책 스크립트는 테스트 소스를 현재 작업 디렉터리의 git root에서 찾고, 자신의 helper는 policy checkout에서 찾는다. 릴리즈의 기존 `release-policy` split checkout과 같은 원칙이다.

## 로컬 사용 규칙

일반 `./scripts/pre-push-checks.sh`와 `--swift-tests`는 상속된 opt-in까지 명시적으로 0으로 덮어쓴다. 별도 opt-in 없는 `xcodebuild test`도 기본적으로 UI-effect 테스트를 끈다. 일반 XCTest 앱 호스트는 run loop를 시작하기 전에 activation policy를 `.prohibited`로 설정해 전면 활성화를 금지한다. 오프스크린 AppKit 객체는 계속 사용할 수 있다. 로컬에서 `--ui-effects`, `--hub-focus-perf`, `--hub-focus-perf-calibrate`를 실행할 수 없다. 이 모드는 `GITHUB_ACTIONS=true`와 `RUNNER_ENVIRONMENT=github-hosted`를 모두 요구하며, 개발자 데스크톱에서 값을 위조해 우회하지 않는다.

오프스크린 렌더, AX 값, OCR, 빌드 성공은 실물 마우스, 키보드 전달, Finder와의 포커스 순서, WindowServer 지연을 증명하지 않는다. 이 경계는 의도적으로 GitHub-hosted UI 게이트가 맡는다.

## 릴리즈 게이트

`beta-notarized-release.yml`은 `isolated-ui-tests.yml`을 재사용하고, `build-notarized-release`는 UI gate가 성공한 뒤에만 시작한다. 따라서 서명, notarization, DMG 업로드, Sparkle appcast 갱신은 실제 WindowServer 검증 실패 또는 측정 불가 상태에서 진행되지 않는다.

격리 VM은 키보드 탐색 계약에 필요한 `AppleKeyboardUIMode=3`을 설정하고 정확한 Xcode 16.3 빌드 번호를 확인한다. 각 UI 계약은 새 호스트에서 한 번만 실행하며, 해당 테스트·suite·1건 실행의 실제 통과 로그를 모두 요구한다. skipped 또는 0건 실행은 실패다. 성능 검사는 기존 예산, 7회 전환, 300ms 대조군, 새 JSON·PNG 증거를 유지한다.

일반 push/PR에도 CI를 실행하지만 저장소 branch protection을 자동으로 변경하지는 않는다. merge 자체도 강제 차단하려면 관리자가 `WindowServer UI effects`를 required status check로 등록해야 한다. 릴리즈 배포는 워크플로의 `needs`로 이미 차단된다.

원격 실행 결과는 GitHub Actions run이 끝난 뒤에만 증거가 된다. 워크플로 정의나 오프스크린 산출물만으로 UI-effect 통과를 주장하지 않는다.
