# Runbook: Picky 릴리즈

사용자가 "릴리즈" / "release" / "릴리즈 해줘"라고 하면 Picky 레포(`github.com/Jonghakseo/picky`)에 아래 절차로 릴리즈를 만든다. **confirm 단계 없이 끝까지 자동으로 진행한다.** 채널을 지정하지 않은 일반 릴리즈 요청은 beta로 처리하고, "스테이블"을 명시한 요청만 stable로 처리한다.

## 0. 버전 정책

향후 생성하는 태그와 GitHub Release에는 다음 규칙을 적용한다.

| 채널 | Git 태그 | GitHub Release | 앱 `MARKETING_VERSION` |
| --- | --- | --- | --- |
| beta | `X.Y.Z-beta.N` | Pre-release, Latest 아님 | `X.Y.Z` |
| stable | `X.Y.Z` | 일반 Release, Latest | `X.Y.Z` |
| alpha(공개 CI 사용 시) | `X.Y.Z-alpha.N` | Pre-release, Latest 아님 | `X.Y.Z` |

- 태그에는 `v` 접두사를 붙이지 않는다.
- stable 태그에 `-stable`을 붙이지 않는다.
- beta 번호 `N`은 1부터 시작하고 같은 버전 트레인에서 1씩 증가시킨다. 어느 자리를 올릴지는 2절의 버전 증가 규칙을 따른다.
- `CFBundleVersion`/build number는 같은 채널의 후속 소스에서 감소하면 안 된다. 같은 커밋을 beta에서 stable로 승격할 때는 명시적으로 같은 build number를 공유할 수 있다.
- 이미 존재하는 숫자형 beta 태그와 `*-stable` 태그·릴리즈는 이름을 바꾸거나 삭제하지 않는다.
- 과거 태그를 수동 재실행할 때만 workflow의 `allow_legacy_tag=true`와 `create_release_if_missing=false`를 함께 사용한다. 새 릴리즈 생성에는 절대 사용하지 않는다.
- 공개된 태그는 이동하거나 덮어쓰지 않는다. 추가 수정이 필요하면 2절 규칙으로 다음 버전을 정한다.

예시:

```text
0.8.5-beta.1 → 0.8.5-beta.2 → 0.8.5
0.8.6-beta.1 → 0.8.6
```

## 1. user-manual 동기화 확인

태그를 만들기 **전에** 매뉴얼 동기화 여부부터 확인한다.

1. 기준 태그 이후 변경사항과 머지된 PR을 훑어서 `docs/user-manual.md` 업데이트가 필요한지 확인한다.
2. 사용자 노출 동작·단축키·탭·설정·저장 경로·외부 의존성이 바뀌었으면 매뉴얼을 갱신하고 **자기 변경분만** 커밋 → push한다.
3. 매뉴얼 동기화가 빠진 상태에서 릴리즈 태그를 먼저 만들지 않는다. 공개된 태그에 누락을 발견하면 태그를 이동하지 말고 다음 버전에서 정정한다.

## 2. 현재 릴리즈와 기준 태그 확인

```bash
gh release list --limit 20
git fetch --tags origin
git tag --sort=-v:refname | head -20
```

### Beta 버전 결정 (버전 증가 규칙)

직전 릴리즈 태그(beta든 stable이든 가장 최근 태그) 이후 커밋을 모아 아래 표의 **가장 높은 단계 하나**를 적용한다. 판단은 사람의 감이 아니라 커밋 타입과 diff로 한다.

```bash
git log <previous-release-tag>..HEAD --oneline --no-merges
git diff --stat <previous-release-tag>..HEAD
```

| 단계 | 조건 | 다음 태그 |
| --- | --- | --- |
| minor | 호환성 영향이 하나라도 있음 | `X.(Y+1).0-beta.1` |
| patch | 호환성 영향은 없고 `feat:` 커밋이 하나라도 있음 | `X.Y.(Z+1)-beta.1` |
| beta.N | 위 둘 다 없음 (`fix`, `perf`, `refactor`, `docs`, `test`, `chore`, `ci`, `build`, `style`만 있음) | `X.Y.Z-beta.(N+1)` |

호환성 영향으로 보는 경우:

- `feat!:`·`fix!:` 같은 `!` 표기나 `BREAKING CHANGE` 푸터가 있는 커밋
- Picky.app ↔ picky-agentd 프로토콜 비호환(구버전 앱과 신버전 daemon, 또는 그 반대가 함께 동작하지 않음)
- 저장 데이터·설정 파일·세션 형식이 바뀌어 마이그레이션이 필요하거나 이전 버전으로 되돌리면 읽지 못함
- 최소 macOS 버전 상향, 번들 Node/Pi SDK 변경으로 기존 사용자 확장·플러그인·MCP 구성이 깨짐
- 업데이트 경로 변경(appcast URL, Sparkle 키, 번들 identifier, 채널 판정)
- `picky` CLI, Pi handoff 확장, 플러그인/스킬이 의존하는 공개 계약의 비호환 변경

세부 규칙:

- 섞여 있으면 높은 단계가 이긴다: minor > patch > beta.N.
- 올린 자리 아래는 초기화한다. minor면 patch는 `0`, beta 번호는 `1`. patch면 beta 번호는 `1`.
- 내부 구조 변경(리팩터링, 모듈 분리, 의존성 정리)은 위 호환성 목록에 해당하지 않으면 minor 사유가 아니다. 커밋 타입대로 판단한다.
- 커밋 타입만 보고 끝내지 않는다. 프로토콜(`agentd/src/protocol.ts`, `Picky/PickyAgentProtocol.swift`, `contracts/`), 저장 형식·마이그레이션, `Info.plist`의 Sparkle 키, 최소 OS·런타임 버전 파일이 바뀌었으면 diff를 열어 호환성 영향을 확인한다.
- 사용자가 버전을 직접 지정하거나 "마이너"·"patch"를 명시하면 그 지시를 따른다. 단, 호환성 영향이 있는데 minor보다 낮게 요청하면 근거를 들어 한 번 알린다.
- 애매하면 낮은 단계를 고르고, 릴리즈 노트 Highlights 아래에 버전 결정 근거(해당 커밋)를 한 줄 적는다.

예시:

```text
0.12.0-beta.1 이후 fix만 있음            → 0.12.0-beta.2
0.12.0-beta.2 이후 feat 1개 + fix 3개     → 0.12.1-beta.1
0.12.1-beta.1 이후 protocol 비호환 변경   → 0.13.0-beta.1
0.12.1 stable 이후 fix만 있음            → 0.12.2-beta.1
```

- 직전 태그가 stable이면 beta.N 단계라도 같은 숫자 버전을 재사용할 수 없으므로 patch를 올린다.

### Stable 버전 결정

- 검증을 마친 beta의 숫자 버전을 그대로 사용하되 suffix를 제거한다. 예: `0.8.5-beta.2 → 0.8.5`.
- stable 태그는 선택한 최종 beta와 같은 커밋을 가리켜야 한다.
- beta 이후 코드나 문서가 바뀌었다면 기존 버전을 재사용하지 말고, 위 버전 증가 규칙으로 다음 beta를 내 다시 검증한다.

## 3. 릴리즈 노트 작성

### Beta

직전 beta(없으면 직전 실제 stable) 이후 변경사항을 기록한다.

```bash
git log <previous-release-tag>..<new-beta-tag-or-HEAD> --oneline --no-merges
```

### Stable

**직전 실제 stable 배포 태그부터 새 stable 태그까지** 누적 변경사항을 기록한다. 중간 beta의 모든 변경사항이 포함되어야 한다.

```bash
git log <previous-stable-tag>..<new-stable-tag-or-HEAD> --oneline --no-merges
```

기존 마지막 stable이 legacy 태그여도 비교 기준으로 그대로 사용한다. 예:

```markdown
**Full Changelog**: https://github.com/Jonghakseo/picky/compare/0.7.25-stable...0.8.5
```

릴리즈 노트 템플릿:

```markdown
## Highlights
- (사용자 임팩트가 큰 변화 1~3줄)

## Changes
- (그 외 커밋을 type prefix를 살려 정리)

**Full Changelog**: https://github.com/Jonghakseo/picky/compare/<base-tag>...<new-tag>
```

릴리즈 노트 작성 시 사용자에게 다시 묻지 않는다.

## 4. 태그 + push + GitHub Release 발행

### Beta

```bash
git tag -a <X.Y.Z-beta.N> -m "<X.Y.Z-beta.N>"
git push origin <X.Y.Z-beta.N>
gh release create <X.Y.Z-beta.N> \
  --verify-tag \
  --title <X.Y.Z-beta.N> \
  --prerelease \
  --latest=false \
  --notes-file <release-notes-file>
```

### Stable

```bash
git tag -a <X.Y.Z> <tested-beta-commit> -m "<X.Y.Z>"
git push origin <X.Y.Z>
gh release create <X.Y.Z> \
  --verify-tag \
  --title <X.Y.Z> \
  --latest \
  --notes-file <release-notes-file>
```

- `git push origin <tag>`의 pre-push hook이 실패하면 로그를 확인한다. **`--no-verify` 사용 금지.**
- 일반 Release는 workflow에서 stable, Pre-release는 beta로 해석된다.
- 태그 형식과 GitHub prerelease 상태가 어긋나면 CI가 즉시 실패해야 한다.

## 5. 배포 완료 확인

릴리즈 발행이 트리거한 `.github/workflows/beta-notarized-release.yml`을 끝까지 확인한다.

```bash
gh run list --workflow beta-notarized-release.yml --limit 5
gh release view <tag>
```

완료 조건:

- GitHub-hosted `isolated-ui-tests.yml`의 WindowServer UI-effect gate 성공 (측정 불가는 실패이며, 오프스크린 검증으로 대체하지 않음)
- workflow 성공
- Developer ID 서명 및 Apple notarization 성공
- DMG와 Sparkle update zip 업로드
- beta/stable appcast 채널 등록
- stable이면 GitHub `Latest` 지정
- 릴리즈 노트에 build number, Git SHA, SHA256, notary submission ID 기록

실패한 GitHub Release를 성공한 배포로 보고하지 않는다.

## 6. 보고

릴리즈 URL, 채널, 버전/build, workflow 결과와 주요 노트를 짧게 보고한다.

---

## 참고: Sparkle 자동 업데이트 릴리즈 인프라

정식 채널(stable/beta) 릴리즈는 GitHub Actions가 notarize + Sparkle appcast 갱신까지 처리한다. 전체 설계는 `docs/auto-update.md` 참고.

- **appcast 앵커**: `auto-update` 태그/릴리즈가 `appcast.xml` 호스팅 앵커다. `https://github.com/Jonghakseo/picky/releases/download/auto-update/appcast.xml` — **절대 삭제 금지.**
- **workflow**: `.github/workflows/beta-notarized-release.yml`. 트리거는 `release: published` 또는 `workflow_dispatch`. 패키징 전 `.github/workflows/isolated-ui-tests.yml`을 재사용해 GitHub-hosted `macos-15`에서 WindowServer UI-effect gate를 통과해야 한다.
- **새 태그 검증**: stable=`X.Y.Z`, beta=`X.Y.Z-beta.N`, alpha=`X.Y.Z-alpha.N`.
- **legacy 재실행**: 기존 숫자형 beta 또는 `*-stable` GitHub Release만 manual dispatch에서 `allow_legacy_tag=true`, `create_release_if_missing=false`로 허용한다.
- **동작**: build → notarize app → DMG notarize/staple → Sparkle update zip + `sign_update` → `appcast.xml` prepend → 릴리즈 노트 갱신.
- **alpha 채널은 Sparkle 비활성**: `AppBundleConfiguration.swift`에서 `releaseChannel == "alpha"`면 `SPUUpdater` 시작 자체를 안 함(sideload 전용).
- **rerun 함정**: GitHub Actions `rerun`은 트리거 당시 commit의 workflow 정의를 캐싱한다. workflow 수정 후엔 `workflow_dispatch`로 새 run을 띄워야 새 정의가 적용된다.
- **서명 키**: public 키는 `Picky/Info.plist#SUPublicEDKey`, private 키는 macOS Keychain(계정 `creatrip`) + GitHub Secret `PICKY_SPARKLE_ED_PRIVATE_KEY`.

향후 stable 수동 트리거 예:

```bash
gh workflow run beta-notarized-release.yml \
  -f tag_name=0.8.5 \
  -f release_channel=stable \
  -f create_release_if_missing=true \
  -f prerelease=false \
  -f allow_legacy_tag=false
```
