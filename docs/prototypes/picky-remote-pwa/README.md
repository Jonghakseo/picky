# Picky 원격 PWA 컴포넌트 시안

상태: 검수용 시안이다. 제품 코드가 아니며 앱에 연결되지 않는다. 계획과 결정은 [`docs/remote-pwa-plan.md`](../../remote-pwa-plan.md)의 "화면" 절에 있다.

폰 PWA는 메신저 형태다. 방 목록에 Picky와 Pickle이 방으로 나오고, 방 안은 HUD 대화 카드와 똑같이 보인다. 그래서 방 목록만 새로 디자인하고, 나머지 파트는 HUD SwiftUI 소스를 웹으로 옮긴다. 메신저 B 시안(`docs/prototypes/picky-b-messenger/`)과는 별개다.

## 구성

| 파일 | 내용 |
|---|---|
| `index.html` | 검수 보드. 파트별 시안(390pt)과 HUD 렌더 갤러리 이미지를 나란히 놓고, 라이트/다크를 함께 바꾼다 |
| `chat-bubbles`, `presence-and-activity`, `question`, `composer`, `header` | HUD에서 옮긴 파트. 각각 `.html`과 `.css` |
| `room-list` | 새 디자인인 방 목록 |
| `tokens.css` | `Picky/DesignSystem.swift`와 `Picky/HUD/PickyHUDTypography.swift`에서 생성한 토큰. 손으로 고치지 않는다 |
| `base.css`, `theme.js` | 페이지 틀. `?theme=light\|dark`, `?scale=1.3`(앱 글꼴 배율)을 처리한다 |
| `strings.ko.json`, `strings.en.json` | 시안이 쓰는 문구를 `Picky/Resources/Localizable.xcstrings`에서 뽑은 것 |
| `new-strings.md` | 아직 카탈로그에 없는 문구. UX writing 검수 대상 |
| `fixtures/` | 시안에 쓰는 고정 샘플. `tool-image-landscape.png`는 HUD 도구 이미지 렌더(`read-image`)와 같은 합성 이미지 |

## 명령

```bash
python3 tools/extract-tokens.py          # tokens.css 다시 생성
python3 tools/extract-tokens.py --check  # Swift 토큰과 어긋나면 실패
python3 tools/l10n.py check              # 화면 문구가 카탈로그 값과 같은지, 새 키가 new-strings.md에 있는지 확인
python3 tools/l10n.py extract            # strings.*.json 다시 생성
python3 tools/l10n.py find '<문구 또는 키>'
python3 tools/lint.py                    # 정의 안 된 토큰, 16진 색상값, 인라인 스크립트, 외부 리소스 검사
tools/shoot.sh <part> [height] [scale]   # 파트 하나를 390pt·2배로 캡처
tools/shoot-board.sh <part> [height]     # 보드에서 그 파트와 HUD 기준 이미지를 나란히 캡처
```

캡처는 `build/render-gallery/remote-pwa-prototype/`에 저장된다. 보드는 `index.html?part=<파트>`로 파트 하나만 볼 수 있다.

HUD 기준 이미지가 소스보다 오래되면 비교가 틀린다. 2026-10-04 검수에서도 10-02 렌더를 기준으로 삼았다가, 그사이 HUD가 에이전트 답변 접기를 없애고 작업 중 표시 줄을 바꾼 것을 놓칠 뻔했다. 검수 전에 `git log --since=<기준 이미지 시각> -- <해당 Swift 파일>`로 변경을 확인하고, 바뀌었으면 갤러리를 다시 렌더한다.

HUD 기준 이미지는 저장소에 넣지 않는다. 보드 오른쪽을 채우려면 먼저 `./scripts/render-ui-gallery.sh`를 `messenger-ux`, `conversation-activity`, `conversation-context`, `dock-group` 대상으로 실행한다.

컴포저와 도구 이미지 말풍선은 렌더 갤러리 대상이 아니라, 기능을 만들 때 [목업 런북](../../../runbook/swift-ui-mockup.md)의 하네스로 렌더한 production 이미지를 기준으로 쓴다.

- `build/render-gallery/composer-production/`: 설정 칩·마이크·음성 상태 줄이 들어간 컴포저(2026-10-04 22:15, `0bf965d8d` 직전 작업 트리). 이후 커밋은 화면을 바꾸지 않았다.
- `build/render-gallery/read-image/`: 도구 이미지 말풍선(2026-10-04 22:48). 이 렌더 뒤 `d38f6588f`가 캡션의 "이미지 읽음" 문구를 지웠으므로 시안은 현재 코드대로 아이콘과 파일 이름만 쓴다.

두 폴더가 없으면 각 폴더의 하네스 소스(`*.swift`)로 다시 렌더하거나, 컴포저는 `./scripts/render-ui-gallery.sh conversation-composer`로 대신한다. 이 갤러리는 받아쓰기 컨트롤러를 넣지 않아 마이크와 음성 상태 줄이 빠진다.

`tools/shoot.sh`는 실행마다 임시 Chrome 프로필을 쓰고, 끝나면 그 프로필의 프로세스만 정리한다. macOS의 headless Chrome은 캡처 뒤에도 종료되지 않는 경우가 있어서, Chrome을 직접 띄우지 말고 이 스크립트를 쓴다.

## 규칙

- 색, 간격, 반경, 글꼴은 `tokens.css` 변수만 쓴다. 16진 색상값을 직접 쓰지 않는다.
- 사용자 문구는 `data-l10n="키"`를 달고 카탈로그의 한국어 값을 그대로 쓴다. 새 문구는 `data-l10n-new`로 표시하고 `new-strings.md`에 모은다.
- 스크립트는 별도 파일로 두고 인라인 스크립트를 쓰지 않는다. 구현 단계의 CSP 규칙과 맞추기 위해서다.
