# Runbook: Picky/agentd 로그 기반 세션 디버깅

Picky 세션 hang/crash를 조사할 때 로그를 어떻게 읽을지에 대한 절차.

## 로그 위치

- agentd stdout: `~/Library/Application Support/Picky/Logs/agentd.stdout.log`
- agentd stderr: `~/Library/Application Support/Picky/Logs/agentd.stderr.log`
- 커밋 `6155a06` 이후 모든 라인이 `<ISO8601> picky-agentd <event> ...` 포맷. 그 이전 빌드 로그는 timestamp가 없으므로 시점 비교는 fs mtime으로 근사한다.
- pi 세션 저널(완전한 메시지/툴 결과): `~/.pi/agent/sessions/<encoded-cwd>/<timestamp>_<sessionFileId>.jsonl`. agentd 로그의 `pi runtime resume sessionId="..." cwd="..." sessionFilePath="..."` 라인이 매핑을 알려준다.

## 사용자가 가리키는 세션 정확히 식별

"이 세션 멈췄어"라고 할 때 단순히 "마지막 running 세션"을 잡으면 틀린 세션을 짚을 수 있다(동시에 여러 Pickle이 떠 있을 수 있음). 식별 단서:

- 스크린샷의 cwd 표시(예: `~/product`) → `pi runtime resume cwd="..."` 매칭.
- 스크린샷의 제목/주제 키워드 → 해당 세션 jsonl 안에서 `grep`으로 확정.
- abort/cancel 횟수, "Cancelled by user" pill 갯수 → agentd stdout의 `command received ... type="abort" sessionId="..."` 카운트와 비교.
- 마지막 user message 텍스트 → jsonl의 `"role":"user"` 메시지에서 검색.

## 핵심 로그 라인 종류

- `command received commandId="..." type="<abort|steer|followUp|listSlashCommands|...>" sessionId="..."` — 사용자/HUD가 보낸 명령. abort가 0건인데 사용자는 ESC를 눌렀다면 ESC가 다른 세션으로 갔거나 stopIfPossible guard가 막은 것.
- `pi abort sessionId="..."` — 실제로 pi 런타임에 abort가 도달.
- `session status sessionId="..." status="..."` — 권위적인 상태 전이. 멈춘 세션은 마지막 status=running인데 그 뒤로 messageAppended/Replaced가 끊긴 것.
- `tool activity sessionId="..." tool="..." status="<running|succeeded|failed>"` — 툴 호출. `(late running ignored)`는 stale 이벤트 무시 메시지로 보통 정상.
- `event sent ...`(per client) + `event broadcast type=... clients=N bytes=K`(`6155a06` 이후, fanout당 1회) — 페이로드 크기 추적용. step disclosure freeze 가설 검증 시 bytes가 메가 단위면 SwiftUI 측 mount가 원인일 가능성이 크다.
- `pi runtime create|resume`, `pi session file`, `pickle started` — 세션 라이프사이클 시작점.

## 자주 빠지는 함정

- **stderr의 크래시 stack trace가 현재 사용자가 보는 인스턴스 것이 아닐 수 있음.** Picky 여러 빌드가 같은 `~/Library/Application Support/Picky/Logs/`에 동시에 쓴다. stack의 파일 경로(`Picky.app` prefix)로 어느 빌드인지 확인한다.
- **같은 이벤트가 정확히 두 번 찍히는 건 dup 로깅이 아니라 fanout**(`clients=2`, HUD 본 윈도우 + companion 패널 등). 정상.
- **"멈춤"으로 보이는 게 실제 hung이 아닐 수 있음**: 긴 turn 동안 다수 tool call을 병렬로 돌리느라 답이 안 나오는 상태도 사용자에겐 멈춤으로 느껴진다. jsonl의 tool result timestamp가 계속 진행 중이면 hung이 아니라 plan 비효율.
- **journal상 `running`으로 박혀 있으나 daemon이 이미 죽은 orphan 케이스**도 존재. agentd가 startup 시 orphan running을 reconcile하지 않으면 영원히 running 표시. abort 명령 0건 + 마지막 이벤트 후 침묵 + ps에서 데몬 pid 확인 안 됨/etime 짧음으로 식별.

## 시간순 가설 검증 절차

1. 사용자 스크린샷/메시지에서 cwd, 제목, 마지막 user msg 추출.
2. agentd stdout에서 그 cwd로 매칭되는 sessionId 후보 → `pi runtime resume cwd=` 라인.
3. 후보 세션의 abort/cancel 카운트로 사용자가 가리키는 게 맞는지 cross-check.
4. 해당 세션 jsonl에서 마지막 user msg → 그 이후 timestamp를 추적해 어떤 tool에서 끊겼는지 확인.
5. stderr에 같은 시각대 ENOENT/throw가 있으면 binary path로 인스턴스 매칭 — 우리 인스턴스가 아닐 수도 있음.
6. 패턴이 안 맞으면 가설을 바꾸지 말고 추가 evidence를 찾는다(예: ps etime으로 데몬 재시작 여부).

## 증거와 가설 분리

"증거"와 "가설"을 항상 분리해서 보고한다. stack trace·스크린샷·journal 항목은 evidence, 인과 관계 추론은 hypothesis. 사용자가 "그건 가설이야 증거야?"라고 물으면 둘을 솔직히 분리해 답한다.
