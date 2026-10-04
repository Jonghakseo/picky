---
name: picky-commit
description: Picky 저장소에서 변경사항을 커밋하거나 커밋 메시지를 작성할 때 사용한다. 이 저장소의 커밋 범위·메시지·훅·worktree 규칙의 정본이다.
---

# Picky Commit

Picky의 커밋 규칙은 이 문서 하나에 모은다. `AGENTS.md`와 다른 문서는 이 스킬을 가리키기만 한다. 규칙을 바꿀 때는 여기만 고친다.

커밋 메시지는 나중에 `git log`/`git blame`으로 "이 코드가 왜 생겼나"를 찾는 사람이 읽는다. 무엇을 바꿨는지는 diff가 이미 말해 준다. 메시지는 diff가 말하지 못하는 것, 특히 **이 작업이 무엇을 고치거나 더하려고 시작됐는지**를 남겨야 한다.

## 1. 언제 커밋하나

- 작업 단위가 끝나고 필요한 검증을 통과하면 별도 확인 없이 커밋한다.
- 한 커밋에는 하나의 논리적 변경만 담는다. 리팩터는 작은 체크포인트 단위로 커밋한다(`docs/refactoring-principles.md` 5절).
- push, PR 생성, 태그는 이 스킬의 범위가 아니다. 사용자가 명시적으로 요청할 때만 한다(push는 `ship` 스킬).

## 2. 범위 고르기

1. `git status --short`와 `git diff`로 작업 트리를 확인한다.
2. 자신이 이번 작업에서 만든 변경만 stage한다. 경로를 지정해 `git add <path>...`를 쓰고, `git add -A`/`git add .`는 쓰지 않는다.
3. 같은 파일에 다른 사람의 변경이 섞여 있으면 `git add -p`로 자기 hunk만 고르거나, 분리할 수 없으면 사용자에게 알린다.
4. `git diff --cached --stat`로 stage 결과를 다시 확인한다. 설정 파일·로그·`.env`류에 비밀값이 들어가지 않았는지 본다.

## 3. 메시지 형식

commit-msg 훅이 `commitlint.config.cjs`(`@commitlint/config-conventional` + `english-only`)로 검사한다. 통과 조건:

- 전체 메시지는 English/ASCII만. 한국어 요청·Slack 문구는 영어로 옮겨 적는다. 이모지, em-dash, 스마트 따옴표도 ASCII가 아니므로 실패한다.
- 헤더 `<type>: <subject>`. type은 `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `style`, `build`, `ci`, `chore`, `revert` 중 하나, 소문자.
- subject는 소문자로 시작하는 명령형, 끝에 마침표 없음, 헤더 전체 100자 이하.
- 본문·footer 각 줄 100자 이하(72자 안팎으로 줄바꿈 권장). 헤더와 본문 사이에 빈 줄.

### 본문 구조 (필수)

```text
<type>: <subject>

<Origin 문단: 이 작업을 시작하게 만든 문제나 필요>

<Change 문단: 무엇을 어떻게 바꿨고, 왜 이 방식인지>

<Validation 문단: 무엇으로 확인했는지, 남은 한계> (선택)

Refs: #123
```

**Origin 문단이 이 스킬의 핵심 요구사항이다.** 본문 첫 문단에 반드시 쓴다.

- `fix`: 사용자가 겪은 증상과 재현 조건, 그리고 확인된 원인. 예: "After aborting a Pickle from the HUD, the cursor stayed in the waiting state because ...".
- `feat`: 어떤 사용자 요구나 제품 결정 때문에 필요했는지. 예: "Users asked to ... so that ...".
- `refactor`/`perf`/`test`/`chore`: 무엇이 불편하거나 위험했는지(측정값, 중복 버그, 리뷰 지적 등).
- 출처가 있으면 함께 적는다: GitHub 이슈 번호, Slack 피드백, 리뷰 단계, 상위 계획 문서 경로. 이슈·PR 번호는 `Refs:` footer로 둔다.
- 작은 후속 커밋이라도 생략하지 않는다. 앞선 커밋의 후속이면 그 커밋 해시와 무엇이 남아 있었는지 적는다.

Origin은 지어내지 않는다. 현재 대화의 사용자 요청, 연결된 이슈·피드백, handoff 문서, 이전 커밋에서 찾는다. compaction으로 잘렸으면 `vcc_recall`로 사용자 요청을 다시 찾는다(`role: "user"`). 그래도 계기를 알 수 없으면 추측하지 말고 사용자에게 한 문장으로 묻는다.

Change 문단은 diff를 다시 나열하지 않는다. 대안 대신 이 방식을 고른 이유, 바뀐 계약·불변식, 의도적으로 남긴 것을 적는다. 여러 항목이면 `- ` 목록을 써도 된다.

### 예시

```text
fix: keep the queued follow-up when a Pickle aborts mid-turn

A follow-up typed while a Pickle was running disappeared if the user
aborted the turn: the composer cleared, but the daemon never received
the message. Reported from Slack beta feedback on 0.42.0-beta.3.

abort() dropped the pending queue together with the in-flight turn.
The supervisor now keeps queued follow-ups and replays them after the
cancelled frame, matching how steering messages already behave.

A supervisor test drives abort with one queued follow-up and asserts it
is delivered once after cancellation.

Refs: #812
```

## 4. 실행

메시지는 임시 파일에 쓰고 `-F`로 넘긴다. 셸 quoting 때문에 줄바꿈이나 따옴표가 깨지지 않는다.

```bash
MSG="$(mktemp /private/tmp/picky-commit-msg.XXXXXX)"
# MSG 파일에 메시지 작성
git commit -F "$MSG"
rm -f "$MSG"
```

- 커밋 훅(`.githooks/pre-commit`의 agentd lint snapshot, `.githooks/commit-msg`의 commitlint)이 오래 걸리므로 `git commit`은 `bash_async`로 실행하고 완료 알림을 받은 뒤 커밋 해시를 확인해 보고한다.
- 훅을 우회하는 `--no-verify`와 기존 커밋을 고치는 `--amend`는 쓰지 않는다. 사용자가 명시적으로 요청한 경우만 예외다.
- 훅이 실패하면 출력을 읽고 원인을 고친 뒤 다시 stage해서 새로 커밋한다. 메시지 실패면 메시지만 고쳐 재시도한다.
- 커밋 후 `git log -1 --format='%h %s'`와 `git status --short`로 결과와 남은 변경을 확인한다.

### 임시 worktree에서 커밋할 때

커밋 훅은 루트와 `agentd` 의존성 트리를 모두 쓴다. worktree에 설치된 의존성이 없으면 primary worktree에서 둘 다 symlink하고, 커밋 뒤 링크를 지운다. `agentd/node_modules`만 연결하면 루트 `commitlint`가 없어 실패한다. worktree에 자체 의존성이 있거나 버전이 훅 기대와 달라질 수 있으면 이 절차를 건너뛴다.

```bash
ln -sfn "$MAIN/node_modules" node_modules
ln -sfn "$MAIN/agentd/node_modules" agentd/node_modules
git commit -F "$MSG"
rm node_modules agentd/node_modules
```

## 5. 보고

최종 응답에는 커밋 해시와 헤더, 포함한 범위, stage하지 않고 남긴 변경이 있으면 그 사실만 짧게 적는다.
