# Runbook: 릴리즈 롤백과 회수

문제가 있는 stable/beta 릴리즈가 나갔을 때 새 업데이트 제안을 멈추고 수정본을 내보내는 절차. 자동 업데이트 설계는 `docs/auto-update.md`, 릴리즈 절차는 `runbook/release.md`를 따른다.

## 먼저 알아 둘 것

- Picky는 Sparkle로 업데이트한다. 앱은 `appcast.xml`에서 **자기 채널 항목**(stable 앱은 `stable`, beta 앱은 `beta`)만 보고, 설치된 build number(`<sparkle:version>`)보다 높은 항목만 제안받는다. 다운그레이드를 제안하는 기능은 없다.
- 따라서 appcast에서 항목을 빼면 **아직 업데이트하지 않은 사용자**에게 그 버전을 더는 제안하지 않는다. **이미 설치한 사용자**는 그대로 남고, 더 높은 build의 수정본이 나와야 벗어난다.
- appcast는 `auto-update` 릴리즈의 `appcast.xml` 자산이다(`https://github.com/Jonghakseo/picky/releases/download/auto-update/appcast.xml`). `auto-update` 태그/릴리즈는 **절대 삭제하지 않는다**. 지우면 모든 설치본의 업데이트 피드가 끊긴다.
- 공개된 태그는 이동하거나 덮어쓰지 않는다(`runbook/release.md` 2절).
- alpha는 Sparkle이 꺼져 있어 appcast 대상이 아니다. alpha 회수는 배포한 zip/패키지를 직접 거두는 수동 작업이다.
- 업데이트 확인은 4시간마다, 앱 시작 20초 뒤 첫 확인이 돈다. Hub의 **Check for updates**나 앱 메뉴의 `Check for Updates…`로 바로 확인할 수도 있다. 자동 다운로드는 꺼져 있어, 사용자가 Hub의 **Update**를 눌러야 설치가 시작된다.

## 1. 신규 제안 중단: appcast 항목 제거

`scripts/update-sparkle-appcast.py`는 항목을 추가하거나 같은 build number·채널 항목을 교체만 한다. **제거 모드는 없으므로** workflow가 하는 방식(`gh release download` → 수정 → `gh release upload --clobber`)으로 직접 편집한다.

1. 진행 중인 릴리즈 workflow가 없는지 확인한다. appcast 갱신은 태그별 concurrency 그룹만 있어서, 다른 run이 같은 시간에 appcast를 읽고 쓰면 한쪽 변경이 덮어써질 수 있다.

   ```bash
   gh run list --workflow beta-notarized-release.yml --limit 5
   ```

2. 현재 appcast를 내려받고 백업한다.

   ```bash
   work="$(mktemp -d)"
   gh release download auto-update --pattern appcast.xml --dir "$work"
   cp "$work/appcast.xml" "$work/appcast.before.xml"
   ```

3. 문제 릴리즈의 `<item>`을 지운다. 항목은 `<sparkle:version>`(build number)과 `<sparkle:channel>`(`stable`/`beta`)로 식별한다. 같은 커밋에서 beta와 stable을 냈다면 build number가 같을 수 있으니 **채널까지 일치하는 항목만** 지운다. 다른 항목, 특히 이전 정상 버전은 건드리지 않는다.

4. XML이 유효하고 대상만 빠졌는지 확인한다.

   ```bash
   python3 -c "import xml.etree.ElementTree as ET,sys; ET.parse(sys.argv[1])" "$work/appcast.xml"
   diff "$work/appcast.before.xml" "$work/appcast.xml"
   ```

5. 올리고, 공개 URL에서 실제로 빠졌는지 확인한다.

   ```bash
   gh release upload auto-update "$work/appcast.xml" --clobber
   curl -fsSL https://github.com/Jonghakseo/picky/releases/download/auto-update/appcast.xml | grep -c "<sparkle:version>"
   ```

6. 문제 버전의 release workflow를 **다시 실행하지 않는다.** 재실행하면 appcast 갱신 단계가 같은 항목을 다시 추가한다.

릴리즈 페이지의 DMG와 Sparkle zip 자산은 appcast와 별개다. 수동 다운로드를 막으려면 릴리즈 노트 맨 위에 문제와 대체 버전을 적고, 필요하면 해당 자산을 삭제한다. 태그는 지우지 않는다. 자산 삭제는 되돌릴 수 없으니 판단은 릴리즈 담당자가 한다.

## 2. 수정본 내기: 더 높은 build number

업데이트 판정은 build number로 한다. 수정본은 문제 버전보다 **높은 build number**여야 업데이트로 제안된다.

- build number는 패키징 시 `git rev-list --count HEAD`로 정해진다(`scripts/package-signed-app.sh`의 `PICKY_BUILD_NUMBER`로 덮어쓸 수 있지만 release workflow는 이 값을 넘기지 않는다). 문제 릴리즈를 낸 브랜치에서 이어 커밋한 수정본은 자동으로 더 높다.
- 오래된 태그에서 가지를 따 핫픽스를 만들면 커밋 수가 문제 버전보다 작을 수 있다. 태그를 만들기 전에 두 값을 비교한다.

  ```bash
  git rev-list --count <문제 릴리즈 태그>
  git rev-list --count <수정 커밋>
  ```

- 릴리즈는 `runbook/release.md`의 일반 절차를 그대로 쓴다. 문제가 stable이면 수정 커밋으로 새 beta를 먼저 내고, 검증한 같은 커밋을 새 stable로 낸다(stable은 테스트한 beta 커밋에서만 낸다). 호환성 영향이 없으면 beta 번호나 patch를 올리는 2절의 규칙을 따른다.
- 새 항목이 올라간 뒤 appcast에 문제 항목이 남아 있지 않은지 1절 5단계의 방법으로 한 번 더 확인한다.

## 3. 채널별 주의

| 문제 릴리즈 | appcast에서 제거할 항목 | 영향받는 설치본 | 비고 |
| --- | --- | --- | --- |
| beta | `channel=beta` 항목 | beta 앱만 | stable 앱은 beta 항목을 보지 않는다. 이전 beta로 되돌려 주는 기능은 없고, 수정 beta를 기다려야 한다. |
| stable | `channel=stable` 항목 | stable 앱만 | beta 앱은 영향이 없다. 같은 build가 beta로도 나갔다면 beta 항목은 따로 판단한다. |
| alpha | 해당 없음 | sideload 설치본 | Sparkle이 꺼져 있어 수동으로 새 alpha를 전달해야 한다. |

- 항목에 채널이 없던 옛 항목은 다음 appcast 갱신 때 `stable`로 바뀐다. 편집할 때 채널 태그가 없는 항목은 stable로 간주한다.
- 제거는 **제안 중단**이지 **회수**가 아니다. 이미 받아 둔 업데이트 파일이 있는 사용자는 Hub 카드에서 그 빌드를 설치할 수 있다(`docs/auto-update.md`의 "An archive Sparkle already holds"). 자동 다운로드가 꺼진 지금 빌드에서는 드물지만, 옛 빌드가 받아 둔 경우는 남는다.

## 4. 사용자 안내

- 릴리즈 노트에 영향받는 버전, 증상, 대체 버전, 해결 방법을 적는다. 사용자가 이미 설치했다면 수정본이 나올 때까지 기다리거나 이전 DMG를 직접 설치해야 한다는 점을 분명히 쓴다.
- 수정본이 나오면 Hub 대시보드의 업데이트 카드에 표시된다. 앱이 열려 있으면 4시간 안에, 바로 받으려면 Hub의 **Check for updates**를 누르라고 안내한다. Sparkle은 진행 중인 세션이 있으면 예약 확인을 건너뛴다.
- 앱이 실행되지 않아 업데이트 카드를 볼 수 없는 경우는 수정본 릴리즈의 DMG를 내려받아 덮어 설치하도록 안내한다.
- 피드백이 들어오는 채널(Slack 피드백, GitHub 이슈)에 같은 문구를 올린다. 문구는 `picky-ux-writing` 기준으로 쓴다.

## 5. 마무리 기록

- 무엇을 어느 시각에 제거했는지(항목의 build number, 채널), 백업한 `appcast.before.xml` 위치, 수정본 태그를 릴리즈 노트나 이슈에 남긴다.
- 원인이 릴리즈 절차의 빈틈이면 `runbook/release.md`나 `docs/release-readiness-checklist.md`에 후속 항목을 추가한다.
