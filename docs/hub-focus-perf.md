# HUB 포커스 실측과 성능 회귀 방지

이 문서는 HUB 포커스 성능을 **사용자의 수동 클릭이나 실행 중인 Picky 재시작 없이** GitHub-hosted macOS VM에서 측정하는 절차다. 로컬 데스크톱은 일반·오프스크린 테스트만 실행한다. 상세 격리 규칙은 [test-desktop-isolation.md](test-desktop-isolation.md), 스택 분석은 [perf-profiling.md](perf-profiling.md)를 참고한다.

## 1. 무엇을 실행하는가

`PickyHubFocusPerformanceTests`는 실제 `PickyHubRootView`의 설정 화면을 별도 테스트 호스트에서 렌더한다. 외부 daemon/client 경계는 fixture로 대체하지만, SwiftUI/AppKit 화면과 포커스 전환은 실제 구현이다.

- 임시 설정 디렉터리와 defaults suite를 사용한다. 실제 세션, 설정, keychain을 변경하거나 daemon을 시작하지 않는다.
- 이미 실행 중인 Finder를 활성화해 테스트 앱이 비활성화됐는지 확인한 뒤, 테스트 HUB를 활성화한다. 같은 앱의 두 창 사이만 전환하는 실험과 다르다.
- Finder의 창이나 파일을 조회·변경하지 않는다. Finder가 없으면 새로 실행하지 않고 실패한다.
- 자체 창 두 개를 만든다. 보조 창은 워밍업과 지연 감지 확인에만 사용한다.
- 종료 시 자체 창과 임시 상태를 정리하고, 가능하면 시작 전의 전면 앱을 복원한다. 실행 중인 사용자 Picky는 그대로 둔다.

GitHub-hosted `macos-15` VM의 WindowServer와 Finder가 필요하다. 워크플로는 고정된 `/Applications/Xcode_16.3.app/Contents/Developer` 도구체인에서 실행한다. Finder가 없거나 앱 활성화가 실패하면 측정 불가로 실패한다. fixture나 오프스크린 렌더로 대체해 통과 처리하지 않는다.

## 2. CI에서 실행할 명령

일반 UI-effect gate는 GitHub Actions에서 실행한다. 기본 브랜치의 워크플로를 수동 실행하려면 다음을 사용한다.

```bash
gh workflow run isolated-ui-tests.yml --ref main
gh run list --workflow isolated-ui-tests.yml --limit 1
```

명시적 태그나 커밋을 검사할 때는 현재 기본 브랜치의 정책 스크립트로 해당 소스를 검사한다.

```bash
gh workflow run isolated-ui-tests.yml --ref main -f ref=<tag-or-sha>
```

기준 수집은 의도적으로 실패하는 calibration 모드로 실행한다.

```bash
gh workflow run isolated-ui-tests.yml --ref main -f mode=hub-focus-perf-calibrate
```

워크플로는 고정 Xcode 도구 체인과 runner 전용 DerivedData를 사용한다. 로컬 `./scripts/pre-push-checks.sh --hub-focus-perf` 명령은 허용되지 않는다. 실행 후 `picky-hub-focus-<run-id>` artifact를 내려받아 아래 산출물을 확인한다.

기본 산출물은 다음과 같다. `build/`는 Git에서 제외된다.

| 파일 | 확인할 내용 |
| --- | --- |
| `build/perf/hub-focus/pre-push.json` | 시나리오, 환경, 각 샘플, 요약값, 예산, 지연 대조군, 판정 |
| `build/perf/hub-focus/pre-push.png` | 실제 fixture 설정 화면이 렌더됐는지 |
| `build/perf/hub-focus/pre-push.log` | 정확한 테스트의 실행·통과 기록과 빌드/실행 오류 |
| `build/perf/hub-focus/pre-push.previous.json` | 같은 이름으로 다시 실행하기 전의 JSON. 현재 실행의 증거가 아님 |

`xcodebuild` 실패는 그대로 전달된다. 성공하더라도 Python 검증기가 현재 JSON/PNG/로그를 다시 확인한다. 오래된 JSON은 실행 전에 이동시키므로 이전 성공 파일을 재사용해 통과할 수 없다. PNG/로그는 같은 출력 이름으로 덮어쓰므로 비교 실험에는 서로 다른 이름을 사용한다.

## 3. 수정 전후 비교 절차

### 조건과 소스 고정

1. 변경 전에 기준값을 먼저 수집한다. 두 버전 모두 같은 하네스 구현과 시나리오를 사용한다.
2. 같은 GitHub-hosted runner image, macOS, Xcode/Debug 구성, 언어, 폰트 크기를 유지한다. GitHub 이미지 갱신이나 runner 부하도 기록한다. JSON은 이 조건을 모두 자동 기록하지 않는다.
3. 각 소스의 커밋을 기록한다. 깨끗한 작업 트리에서 실행하는 것이 가장 명확하다. 미커밋 변경이 있다면 diff와 신규 소스도 별도로 보존한다.
4. 다른 빌드·테스트를 동시에 돌리지 않는다. 일부러 느린 실행을 버리고 가장 빠른 값만 고르지 않는다.

```bash
# 기준 소스의 SHA를 기록한 뒤 CI calibration을 실행한다.
git rev-parse HEAD
gh workflow run isolated-ui-tests.yml --ref main \
  -f ref="$(git rev-parse HEAD)" \
  -f mode=hub-focus-perf-calibrate
```

완료된 run의 `picky-hub-focus-<run-id>` artifact를 내려받아 `before.json`으로 보관한다.

**Calibration은 샘플과 화면을 저장한 뒤 의도적으로 테스트를 실패시킨다.** `calibrationCompleted(...)`와 새 `before.json`의 `mode: calibration`, `gateStatus: calibration`을 함께 확인한다. 보통 종료 코드는 65지만, 65 자체는 기준 측정 완료의 증거가 아니다. 컴파일 오류나 호스트 실행 실패도 같은 코드를 반환할 수 있다.

변경 후에는 일반 게이트로 실행한다.

```bash
gh workflow run isolated-ui-tests.yml --ref main \
  -f ref="$(git rev-parse HEAD)" \
  -f mode=hub-focus-perf
```

통과한 run의 `picky-hub-focus-<run-id>` artifact를 내려받아 `after.json`으로 보관한다.

통과한 변경본의 산출물은 별도로 재검증할 수 있다.

```bash
python3 scripts/tests/test_hub_focus_perf_runner.py \
  --report build/perf/hub-focus/after.json \
  --xcode-log build/perf/hub-focus/after.log
```

검증된 두 결과를 비교한다. 아래 코드는 비교 편의를 위한 것이며 위의 산출물 검증을 대체하지 않는다.

```bash
python3 - <<'PY'
import json
from pathlib import Path
root = Path('build/perf/hub-focus')
before = json.loads((root / 'before.json').read_text())
after = json.loads((root / 'after.json').read_text())
assert before['mode'] == before['gateStatus'] == 'calibration'
assert after['mode'] == 'gate' and after['gateStatus'] == 'passed'
assert before['scenario'] == after['scenario'] == 'finder-to-isolated-hub-settings'
assert before['environment'] == after['environment'], '측정 환경 차이를 먼저 확인할 것'
for metric in ('totalReady', 'mainThreadCPU', 'keyAcquisition', 'renderReadyAfterKey'):
    a = before['summary'][metric]['medianMilliseconds']
    b = after['summary'][metric]['medianMilliseconds']
    direction = '증가' if b > a else '감소'
    change = f'{abs(1 - b / a) * 100:.1f}% {direction}' if a else '기준값 0, 비율 계산 불가'
    print(f'{metric}: {a:.2f} -> {b:.2f} ms ({change})')
PY
```

과거 커밋에 하네스가 없다면 그 커밋의 일반 테스트를 성능 기준값이라고 부르지 않는다. 동일한 하네스가 이전 production 코드에도 붙어 있어야 비교할 수 있다. 앱 재시작이나 사용자 소스를 덮어쓰는 작업은 이 명령의 일부가 아니다.

## 4. 측정값과 통과 조건

두 번 워밍업한 뒤 실제 앱 간 전환을 일곱 번 측정한다. 앱·보고서·터미널 폰트 메뉴가 실제로 존재하는지 검사해, 가벼운 대시보드나 빈 화면으로 잘못 통과하는 것을 막는다.

| JSON 지표 | 측정 경계 | 현재 게이트 |
| --- | --- | --- |
| `keyAcquisition` | `NSApp.activate` / `makeKeyAndOrderFront` 직전부터 실제 `didBecomeKey` 통지까지 | 중앙값 ≤ 100ms, p95 ≤ 150ms, 최대 ≤ 250ms |
| `renderReadyAfterKey` | key 통지 이후 앱 활성화 확인, 다음 `RunLoop.main.perform`, 실제 host layout/display 완료까지 | p95 ≤ 100ms |
| `totalReady` | 각 샘플의 위 두 지연 합계 | 보고용. 별도의 합산 임계값은 없음 |
| `mainThreadCPU` | 전체 전환 구간의 메인 스레드 CPU 시간 | 보고용. 별도 CPU 임계값은 없음 |

지연은 `DispatchTime.uptimeNanoseconds`, CPU는 `clock_gettime(CLOCK_THREAD_CPUTIME_ID)`로 잰다. CPU 값에는 스레드가 대기하거나 실행 기회를 받지 못한 시간이 포함되지 않는다. 각 구간의 중앙값을 더한 값은 전체 구간 중앙값과 다를 수 있다.

일곱 샘플의 nearest-rank p95는 최대값과 같다. 모집단의 정밀한 p95 추정이나 통계적 유의성 주장에 쓰지 않는다.

제품 샘플 뒤에는 보조 창의 `didResignKey` 콜백을 300ms 막는다. 그 지연을 시계가 관측하고, **같은 예산 판정이 해당 샘플을 거절하는지** 확인한다. 이 대조군은 제품 요약값에 섞지 않는다.

통과에는 실제 활성화·key 전환, 렌더 준비, 예산, 대조군, 현재 산출물과 정확한 테스트 통과 기록이 모두 필요하다. `TEST SUCCEEDED`만 있거나 테스트가 0개 선택된 것은 충분하지 않다. 반대로 Swift Testing 실행 전에 XCTest가 출력하는 `Executed 0 tests`만 보고 실패로 판정하지도 않는다.

## 5. 회귀 방지 구조

| 층 | 막는 회귀 | 실행 지점 |
| --- | --- | --- |
| 네이티브 메뉴 | 동일 옵션으로 포커스 갱신 100회 시 실제 `NSMenu` 항목 변경 0회. 실제 라벨 변경으로 관측기도 검증 | `PickyNativeMenuPickerTests` |
| 선택·접근성 | 중복 표시 이름, 미지원 선택값, disabled, 폰트 변경, 값/접근성 역할, 중복 binding 쓰기 | 같은 네이티브 컨트롤 테스트 |
| 페이지 수명 | 미방문 페이지 미생성, 방문한 페이지의 상태 유지, 포커스 환경 갱신 시 불필요한 마운트 방지 | `PickyHubPageMountTests` |
| 실제 UI 연결 | 메뉴 액션 → 설정 파일 저장, 영어/한국어 전환, 첫 Settings 딥링크 → 펼쳐진 도구의 렌더 출력 | `PickyHubSettingsRuntimeContractTests` |
| 소스 경계 | `PickyHubSettingsPage.swift`에 직접 SwiftUI `Picker` 또는 menu style 재도입 방지. 스타일 생략도 macOS에서는 메뉴이므로 차단 | `check-architecture-rules.js` |
| 실행 격리 | 일반 테스트의 창 활성화 금지, 성능 suite 중복 실행·전체 suite 혼합 방지 | `check-test-environment-isolation.py` |
| 런타임 | 실제 Finder ↔ 격리 HUB 활성화와 렌더 준비 지연 | 전용 성능 게이트 |

Settings 딥링크 테스트는 offscreen SwiftUI의 AX 텍스트 트리가 비어 있기 때문에 실제 렌더 이미지의 도구 식별자를 Apple Vision OCR로 확인한다. 데스크톱 캡처나 권한 요청은 없다. 이 fixture의 애니메이션 억제와 OCR 초기화 대기 한도는 성능 예산이 아니며, 런타임 하네스의 정상 motion 환경과 구분한다.

일반 `./scripts/pre-push-checks.sh`와 `xcodebuild test`에서는 WindowServer 성능 suite가 비활성화된다. GitHub-hosted `isolated-ui-tests.yml`만 UI-effect 모드를 호출하며, 각 WindowServer 테스트는 새 테스트 호스트에서 한 번씩 실행한다. runner 직렬화만으로 다른 Swift Testing 작업이나 잔여 비동기 작업의 영향을 없앴다고 가정하지 않는다.

`TEST_RUNNER_PICKY_PRE_PUSH_UI_EFFECT_TESTS=1`을 임의로 설정하지 않는다. UI-effect opt-in은 격리 워크플로가 호출한 pre-push 스크립트만 소유한다.

빠른 구조·산출물 검증기 검사:

```bash
node scripts/check-architecture-rules.js --self-test=hub-focus
python3 scripts/check-test-environment-isolation.py
python3 -m unittest discover -s scripts/tests -p test_hub_focus_perf_runner.py
```

## 6. 실패했을 때

| 증상 | 처리 |
| --- | --- |
| 컴파일 실패, `IDELaunchErrorDomain Code 20`, 샘플/화면 없음 | 측정 불가. 로그의 원인을 해결한다. 서명 설정을 바꾸거나 미실행 테스트를 통과로 표시하지 않는다 |
| Finder/WindowServer 없음, 앱 활성화 시간 초과, 중간 포커스 손실 | 환경 때문에 판정 불가이며 CI 실패다. GitHub-hosted runner image와 실행 로그를 확인한다. 임의 앱 실행이나 권한 요청, fixture 대체로 우회하지 않는다 |
| `calibrationCompleted` + 유효한 새 calibration JSON | 기준 수집 완료, 게이트 통과는 아님 |
| 현재 gate JSON의 예산 초과 | 실제 샘플과 화면을 먼저 확인한 뒤 아래 순서로 원인을 좁힌다 |
| 구조/메뉴 mutation 계약 실패 | 시간 측정이 빨라도 수정해야 한다. 워밍업·캐시가 구조적 회귀를 가릴 수 있다 |
| 전체 pre-push의 다른 검사 실패 | 성능 결과와 구분한다. 전용 명령은 독립 진단에 쓸 수 있지만 전체 게이트 통과를 대신하지 않는다 |

1. 동일 시나리오·언어·디스플레이·소스인지 확인한다. 백그라운드 부하가 의심되면 근거를 남기고 통제된 조건에서 확인한다. 통과할 때까지 반복 실행하지 않는다.
2. 메뉴 변경 계약과 페이지 수명 테스트를 확인한다. 옵션이 그대로인데 메뉴/라벨을 다시 만들거나, 미방문 화면을 미리 구성하지 않는지 본다.
3. 스택 귀속이 필요하면 [Time Profiler와 signpost 절차](perf-profiling.md)를 따른다. `settings_native_menu_update`와 HUB signpost로 앱 작업 구간을 좁힌다.
4. 원인을 수정하고 영향받은 테스트와 같은 런타임 경계를 검증한다.

성능 예산을 실패에 맞춰 올리지 않는다. 하드웨어·OS 또는 제품 목표 변경 때문에 재조정이 필요하면 변경 이유, 동일 조건의 원시 샘플, 이전/새 기준의 비교를 리뷰에 남긴다. 메뉴 mutation 0회 같은 결정적 계약은 시간 예산 조정으로 면제하지 않는다.

## 7. 검증 범위의 한계와 측정 사례

이 하네스는 fixture 워크로드에서의 앱 활성화·렌더 준비를 측정한다. 실제 사용자의 전체 세션 부하, 모든 접근성 설정, 물리 키 입력 전달, WindowServer compositor의 화면 표시 완료, 팝오버 애니메이션 길이를 보장하지 않는다. 전체 CPU 합계는 전환 횟수가 다르면 직접 비교하지 않는다.

2026-09-09, macOS 15.6.1 / Xcode 16.3 Debug / 논리 CPU 14개 / RAM 48GiB / 디스플레이 3개에서 동일한 일곱 전환을 비교했다.

| 지표 | 이전 구현 | 네이티브 메뉴 + 지연 마운트 |
| --- | ---: | ---: |
| 렌더 준비 전체 중앙값 | 37.44ms | 30.27ms |
| 렌더 준비 전체 p95/최대 | 77.73ms | 33.79ms |
| 메인 스레드 CPU 중앙값 | 30.68ms | 21.98ms |
| 메인 스레드 CPU p95/최대 | 71.67ms | 26.48ms |
| key 통지 중앙값 | 6.74ms | 8.76ms |

전체 렌더 준비 중앙값은 19%, 메인 스레드 CPU 중앙값은 28% 감소했다. key 통지 자체는 개선되지 않았다. 최종 게이트가 통과했고, 300ms 대조군은 301.27ms로 관측되어 같은 예산에서 거절됐다.

기준 production root/settings는 `871fb9f58`, 개선 구현은 `e3bff0182`에 커밋했다. 로컬 증거는 `build/perf/hub-focus/{before,final}.{json,png,log}`이며 중간 후보는 `after.*`에 있다. 첫 동일 앱/두 창 실험은 앱 간 시나리오로 교체한 뒤 최종 비교에서 제외했다. 이전 실앱 수동 측정의 127ms CPU와도 직접 비교하지 않는다. 사용자 Picky 프로세스는 재시작하지 않았다.

## 공식 API 참고

- [NSWindow.didBecomeKeyNotification](https://developer.apple.com/documentation/appkit/nswindow/didbecomekeynotification)
- [Swift Testing 병렬화](https://developer.apple.com/documentation/testing/parallelization)
- [Xcode에서 앱 테스트하기](https://developer.apple.com/documentation/xcode/testing-your-apps-in-xcode)
- [Vision 텍스트 인식](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
