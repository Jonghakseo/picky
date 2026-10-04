# SwiftUI 1:1 목업과 렌더 갤러리

Picky UI 시안을 SwiftUI로 만들고, 앱을 실행하지 않은 채 상태별 PNG와 실제 크기의 갤러리를 보여주는 절차다. 스킬은 이 런북을 참조하며, 화면별 예제는 스킬의 `references/`에 둔다.

## 정본과 역할

| 위치 | 담당 |
|---|---|
| 이 런북 | 경로 선택, 실행, 검수, 안전 조건 |
| [렌더 갤러리 문서](../docs/render-gallery.md) | production target 목록·지원 장면·오프스크린 제약 |
| [프로젝트 목업 스킬](../.agents/skills/picky-swift-ui-mockup/SKILL.md) | 요청 트리거와 도구·레퍼런스 진입점 |
| [디자인 가이드](../design/DESIGN.md), [UX writing](../design/UX_WRITING.md) | 시각·상태·문구 기준 |
| [작업 막대 예제](../.agents/skills/picky-swift-ui-mockup/references/async-work/README.md) | 해당 시안의 치수·상태·재현 명령 |
| `build/render-gallery/<작업명>/README.md` | 해당 실행의 구성·검증 범위. 공통 절차의 정본으로 쓰지 않는다 |

## 1. 요청에 맞는 경로 선택

| 목적 | 경로 | 결과의 의미 |
|---|---|---|
| 현재 구현 또는 수정한 실제 UI의 시각 검증 | 기존 `scripts/render-ui-gallery.sh <target>`와 production component scene | 해당 구현의 정적 렌더 증거 |
| 앱에 적용하기 전 제안안을 Swift로 검토 | production 컴포넌트·토큰을 재사용한 proposal View + 링크 하네스 | 제안 목업. production 구현 완료의 증거가 아님 |

실제 구현 검증을 위해 별도의 모사 UI를 만들지 않는다. 제안 목업에서는 바뀌는 영역만 새 View로 만들고, 인접한 입력창·헤더·도구 기록 등은 가능하면 실제 컴포넌트를 사용한다. 목업 요청만으로 앱 구현을 변경하지 않는다.

## 2. 범위와 치수 확인

1. `git status --short`로 다른 변경을 보호한다.
2. 스크린샷의 영역을 production View와 backing store/model에 대조한다. 현재 상태에서 실제로 가능한 상태와 클릭 결과를 먼저 확인한다.
3. [디자인 스킬](../.agents/skills/picky-design-guide/SKILL.md)의 관련 문서를 읽고, 목표·첫 시선·표시할 상태·유지할 동작·검증 한계를 정리한다. 새 레이아웃이면 해당 스킬의 Design Decision Card를 비례해서 사용한다.
4. 실제 card/content 폭, padding, 행 높이, radius, 폰트 배율, 최대 목록 높이를 코드에서 가져온다. HTML/CSS로 비슷하게 흉내 낸 화면을 Swift 1:1 목업이라고 부르지 않는다.
5. 목록이 길면 실제 뷰포트 높이를 유지한다. 별도의 전체 문서 렌더는 `전체 목록 검수용, 실제 막대 높이와 다름`이라고 표시한다.

`1:1`은 논리 좌표의 치수와 typography를 뜻한다. SwiftUI PNG의 pixel grid를 2배로 저장해도 HTML에서는 논리 폭·높이로 표시한다. 브라우저 zoom 100%를 기준으로 하며, 오프스크린 material과 글리프 품질까지 실제 창과 동일하다고 약속하지 않는다.

## 3. 제안 목업 작성

- 소스·시나리오·시간·ID를 고정한다. `Date.now`로 화면이 매번 달라지는 타이머 대신 정적 fixture를 사용하고 이를 설명한다.
- 프로덕션의 `DS`, `PickyHUDTypography`, 해당 layout policy를 재사용한다. 외부 배경 등 fixture 예외는 좁게 표시한다.
- 기본 상태, 접힘/펼침, 실행/대기/완료/실패, 여러 작업 혼합, 결과 처리, 확인 불가를 실제 모델에 있는 범위에서 포함한다. 알 수 없는 상태를 실패나 성공으로 단정하지 않는다.
- dark/light, 일반 폭, 좁은 폭 또는 긴 CJK 텍스트, 130% 글자 크기를 필요한 범위에서 포함한다. env 폰트 배율을 바꿨다고 모든 production static font가 커졌다고 가정하지 않고 PNG로 확인한다.
- 에이전트 개수는 `개`를 사용한다. 에이전트 수와 비동기 명령 수를 하나의 총개수로 섞지 않는다.
- 결과 생성 성공과 부모 에이전트의 결과 수신·처리 완료를 구분한다. UI의 `상태 확인 불가`를 `결과 전달 실패`로 치환하지 않는다.
- production 주변 UI를 사용하는 하네스에는 fake client를 주고, 실제 발신 명령이 없음을 확인한다.

실행 산출물은 `build/render-gallery/<작업명>/`에 둔다. 재사용할 예제를 보존할 때는 Swift 소스와 화면별 설명만 `.agents/skills/picky-swift-ui-mockup/references/<영역>/`로 이관한다. 공통 renderer/gallery 도구는 같은 스킬의 `scripts/`에 둔다. 테스트의 rasterizer/fake를 복제하지 않고 기존 파일을 참조한다.

## 4. 렌더 실행

### Production gallery

[렌더 갤러리 문서](../docs/render-gallery.md)에서 해당 target과 실제 실행 suite를 고른다. 필요한 scene이 없으면 production 컴포넌트 scene을 추가한다. 앱 재실행은 필요 없다.

### 기존 Debug 모듈에 링크하는 proposal harness

저장소 루트에서 다음처럼 실행한다.

```bash
SKILL=.agents/skills/picky-swift-ui-mockup
OUT=build/render-gallery/async-work-proposal
bash "$SKILL/scripts/render-mockup.sh" \
  "$SKILL/references/async-work/AsyncWorkMockup.swift" "$OUT"
python3 "$SKILL/scripts/make-gallery.py" "$OUT" \
  --title "Picky 작업 막대 SwiftUI 목업"
```

이 예제는 16개 상황의 dark/light와 좁은 폭/130%를 합쳐 34개 PNG를 만든다. 제안 막대를 그리되 실제 도구 기록과 입력창을 재사용한다. 출력을 다른 디렉터리로 지정하면 기존 리뷰 자료를 덮어쓰지 않고 보존할 수 있다. 같은 출력 디렉터리를 두 작업에서 동시에 사용하지 않는다.

하네스는 Xcode 16.3과 기존 `/private/tmp/PickyAgentDD/Build/Products/Debug`를 사용한다. `PICKY_DERIVED_DATA_PATH`로 다른 준비된 DerivedData를 지정할 수 있으나, [AGENTS.md](../AGENTS.md)의 공유 경로·고유 경로 소유권 규칙을 따른다. 같은 DerivedData를 쓰거나 DerivedData를 확인할 수 없는 `xcodebuild`가 있으면 완료를 기다린다. 다른 경로를 명시한 Xcode 작업은 선택한 모듈을 덮어쓰지 않으므로 기존 모듈에 링크할 수 있다. 하네스는 추가 `xcodebuild`를 시작하지 않는다.

모듈·dylib·번역 리소스가 없거나 production 소스/프로젝트 설정이 빌드보다 새로우면 하네스가 중단된다. 이 timestamp 검사는 보수적인 stale 탐지이며, 오래된 binary의 정확한 빌드 커밋을 역으로 증명하지 않는다. 다른 checkout에서 복사한 빌드는 쓰지 않는다. 불확실하면 같은 소스로 아래 incremental build만 수행한다. 새 DerivedData나 전체 제품 테스트를 매번 만들지 않는다.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath /private/tmp/PickyAgentDD build
```

이 빌드는 컴파일만 증명한다. 앱을 실행하지 않는다. toolchain을 바꿔 오류를 우회하거나 서명 설정을 변경하지 않는다.

### 하네스와 manifest 계약

Swift 소스는 `@main` entry point를 가지며 첫 인자로 출력 디렉터리를 받는다. 공통 스크립트가 기존 `PickyRenderGalleryRasterizer.swift`와 `FakePickyAgentClient.swift`를 함께 컴파일한다. 하네스는 `XCTestConfigurationFilePath`로 test isolation을 활성화한다. 임시 executable을 직접 실행하며 `.app`을 `open`하지 않는다. 임시 하네스는 실행 후 정리하고 결과 PNG만 남긴다.

`manifest.json`의 최소 형식은 다음과 같다. 각 `file`은 출력 디렉터리 안의 PNG 상대 경로이고, `width`/`height`는 **논리 크기**, `pixelWidth`/`pixelHeight`는 실제 PNG 크기다. `renderer`에는 proposal/production 구분과 재사용 컴포넌트를 적는다.

```json
{
  "renderer": "SwiftUI proposal / production DS and composer",
  "scenes": [{
    "id": "mixed", "title": "다른 비동기 작업과 혼합",
    "note": "작업 묶음별 상태를 표시합니다.",
    "file": "mixed-dark.png", "appearance": "dark", "scale": 1,
    "width": 446, "height": 362, "pixelWidth": 892, "pixelHeight": 724
  }]
}
```

공통 gallery는 이를 검증하고 dark/light 필터와 1:1 이미지를 만든다. 선택 필드 `ocr`는 하네스가 수집한 문구 검수 자료다. `render-provenance.json`에는 사용한 소스·binary·모듈 hash와 toolchain을 남긴다. 데이터 계약이 다른 production gallery를 억지로 이 형식으로 바꾸지 않는다.

## 5. 검수하고 열기

1. PNG 개수·manifest·pixel dimensions·논리 치수를 확인한다. stale manifest나 이전 실행 PNG를 새 결과로 보고하지 않는다.
2. 실제 PNG를 직접 읽는다. 관심 장면의 dark/light, 실패, 긴 제목, 좁은 폭/큰 글자를 확인한다. 모음 이미지는 보조 자료이고 작은 글자의 상세 검수를 대체하지 않는다.
3. clipping·줄바꿈·상태/시간 정렬·완료 항목 유지·입력창 가시성·색 대비를 확인한다. OCR은 문구 누락을 찾는 보조 수단이지 시각 품질의 판정이 아니다.
4. 전체 완료 장면에서 막대와 불필요한 여백이 사라지는지, 확인 불가·실패가 조용히 사라지지 않는지 확인한다.
5. 사용자가 열어 달라고 요청한 경우 다음으로 갤러리를 연다.

   ```bash
   open build/render-gallery/async-work-proposal/index.html
   ```

완료 보고에는 위치, 상황/이미지 수, 재사용한 컴포넌트, 직접 확인한 범위, 앱 적용 여부를 짧게 쓴다.

## 안전 조건과 한계

- 실행 중인 Picky.app·데몬에 연결하거나 종료·재시작하지 않는다. 화면 검수만을 위해 마이크·권한·Keychain·Updater를 시작하지 않는다.
- `PICKY_PRE_PUSH_UI_EFFECT_TESTS` 등의 desktop opt-in은 사용하지 않는다. `NSWindow`/`NSPanel` 없이 `NSHostingView`를 bitmap cache로 렌더한다.
- test isolation은 production effect를 막는 장치다. 하네스가 임의의 다른 실행 파일이나 production singleton을 호출해도 안전하다는 보장은 아니므로 소스를 먼저 읽는다.
- 검증용 임시 `.app`은 직접 실행하며 LaunchServices에 등록하지 않는다. 정리 때도 `lsregister -u -R` 후 스크립트 소유 임시 디렉터리만 삭제한다. 공유 DerivedData는 삭제하지 않는다.
- 오프스크린 bare `Image(systemName:)`이 누락되면 proposal에서 `Text(Image(systemName:))`를 사용한다. production 뷰를 이미지에 맞춰 모사하지 않는다.
- 렌더는 static geometry·문구·appearance를 보여준다. hover·keyboard·VoiceOver·IME·타이머·실제 상태 전이·스크롤·popover anchoring·material/vibrancy·성능을 검증하지 않는다. [렌더 한계](../docs/render-gallery.md#review-limits)를 따른다.

## 도구 유지보수 검증

공통 스크립트를 바꿨다면 CLI 계약 검사와 영향을 받는 예제 렌더를 실행한다. 문서만 바꿨다면 링크·diff 확인으로 끝내고 앱 빌드나 제품 테스트를 실행하지 않는다.

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s .agents/skills/picky-swift-ui-mockup/tests -v
```

이 검사는 논리 크기 표시, PNG/manifest 치수 불일치, 출력 폴더 밖 파일, 빈/중복 장면, 문구 escaping, 없는 소스의 조기 실패, 동일·별도 DerivedData의 충돌 판정을 확인한다. 예제 렌더와 직접 PNG 검수는 별도다.

## 참고

- [Pi Skills](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/skills.md): 프로젝트 스킬 발견과 `references/`·`scripts/` 구성.
- [NSView.cacheDisplay](https://developer.apple.com/documentation/appkit/nsview/cachedisplay(in:to:)): 기존 rasterizer의 오프스크린 bitmap cache API.
