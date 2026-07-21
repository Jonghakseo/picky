# Runbook: Picky 릴리즈

사용자가 "릴리즈" / "release" / "릴리즈 해줘"라고 하면 Picky 레포(`github.com/Jonghakseo/picky`)에 아래 절차로 릴리즈를 만든다. **confirm 단계 없이 끝까지 자동으로 진행한다.**

## 0. (선행) user-manual 동기화 확인

태그를 만들기 **전에** 매뉴얼 동기화 여부부터 확인한다.

1. 이전 릴리즈 대비 변경사항(`git log <prev-tag>..HEAD`, 머지된 PR 목록)을 훑어서 `docs/user-manual.md` 업데이트가 필요한 변경이 있는지 확인한다. 사용자 노출 동작·단축키·탭·설정·저장 경로·외부 의존성이 바뀌었으면 매뉴얼 동기화가 필요하다.
2. 필요하면 `docs/user-manual.md`를 갱신하고 **자기 변경분만** 커밋 → push.
3. 매뉴얼 동기화가 빠진 상태에서 릴리즈 태그를 먼저 만들지 않는다. 잊었으면 릴리즈 절차 중에라도 즉시 멈추고 매뉴얼부터 정정한 뒤 재개한다.

## 1. 현재 버전 확인

```bash
gh release list --limit 5
git tag --sort=-v:refname | head -5
```

## 2. 패치 버전 bump

마지막 세그먼트를 하나 올린다. 예: `0.3.2 → 0.3.3`, `0.4.7 → 0.4.8`. 사용자가 "마이너"라고 말해도 관습상 patch bump를 의미한다. 태그 형식은 `v` 접두사 없이 숫자 그대로(예: `0.3.4`).

## 3. 릴리즈 노트 작성

직전 릴리즈 이후 커밋을 모아 작성한다.

```bash
git log <prev>..HEAD --oneline --no-merges
```

템플릿:

```markdown
## Highlights
- (feat/주요 refactor 등 사용자 임팩트 큰 변화 1~3줄)

## Changes
- (그 외 모든 커밋을 type prefix 살려 한 줄씩, 비슷한 test/chore는 묶어도 됨)
```

Highlights는 사용자 가시적인 큰 변화(feat, 주요 refactor, 눈에 띄는 fix)만 1~3개로 압축하고, 나머지는 Changes에 커밋 메시지 prefix를 살려 나열한다. **릴리즈 노트 작성 시 사용자에게 다시 물어보지 않는다.**

## 4. 태그 + push + Pre-release publish

사용자 confirm 없이 바로 진행한다.

```bash
git tag -a <ver> -m "<ver>"
git push origin <ver>   # pre-push hook이 xcodebuild 테스트를 돌림 → timeout 길게(600000ms 권장)
gh release create <ver> --title <ver> --prerelease --notes "..."
```

- `git push origin <tag>`의 pre-push hook이 실패하면 로그를 확인하고 사용자에게 보고한다. **`--no-verify` 사용 금지.**

## 5. 보고

릴리즈 URL과 노트를 짧게 보고한다.

---

## 참고: Sparkle 자동 업데이트 릴리즈 인프라

정식 채널(stable/beta) 릴리즈는 GitHub Actions가 notarize + Sparkle appcast 갱신까지 처리한다. 전체 설계는 `docs/auto-update.md` 참고.

- **appcast 앵커**: `auto-update` 태그/릴리즈가 `appcast.xml` 호스팅 앵커다. `https://github.com/Jonghakseo/picky/releases/download/auto-update/appcast.xml` — **절대 삭제 금지.**
- **workflow**: `.github/workflows/beta-notarized-release.yml`. 트리거는 `release: published` 또는 `workflow_dispatch`. 입력: `tag_name`, `release_channel`(stable/beta/alpha), `create_release_if_missing`, `prerelease`.
- **동작**: build → notarize app → DMG notarize/staple → Sparkle update zip + `sign_update` → `appcast.xml` prepend → 릴리즈 노트 갱신.
- **alpha 채널은 Sparkle 비활성**: `AppBundleConfiguration.swift`에서 `releaseChannel == "alpha"`면 `SPUUpdater` 시작 자체를 안 함(sideload 전용).
- **rerun 함정**: GitHub Actions `rerun`은 트리거 당시 commit의 workflow 정의를 캐싱한다. workflow 수정 후엔 `workflow_dispatch`로 새 run을 띄워야 새 정의가 적용된다.
- **서명 키**: public 키는 `Picky/Info.plist#SUPublicEDKey`, private 키는 macOS Keychain(계정 `creatrip`) + GitHub Secret `PICKY_SPARKLE_ED_PRIVATE_KEY`.

수동 트리거 예:

```bash
gh workflow run beta-notarized-release.yml -f tag_name=v1.0.1 -f release_channel=stable
```
