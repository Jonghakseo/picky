---
name: picky-debug
description: Picky 개발 중 오디오·텍스트 입력을 재현하고, 실행 중인 앱·데몬의 상태 전이와 지연을 picky-debug CLI로 추적할 때 사용한다.
---

# picky-debug

개발 과정의 재현·측정·진단 전용 스킬이다. 일반 사용자용 Picky 제어나 메인 에이전트의 작업 수행 도구가 아니다. 앱 번들 스킬, 제품 CLI 자동 설치, 런타임 PATH에 추가하지 않는다.

## 시작 전에

1. 이 스킬 디렉터리에서 `../../..`를 저장소 루트로 해석한다. 아래 명령은 루트에서 실행한다.
2. [CLI 계약과 측정 한계](../../../docs/picky-debug.md)를 읽는다. `./scripts/picky-debug --help`로 현재 명령을 확인한다.
3. 진단할 입력 종류, 예상 라우팅 대상, 멈춘 단계 또는 측정할 구간을 정한다. 입력을 직접 넣을지, 사용자가 넣는 입력만 관측할지도 구분한다.
4. 먼저 읽기 전용 `state`를 실행한다. 앱·데몬에 디버그 프로토콜이 없는 경우 실패를 보고한다. 연결 파일을 고치거나 앱을 자동 재시작하지 않는다.

개발 의존성이 없으면 `pnpm --dir agentd install`이 필요하다. 임시 데몬은 `PICKY_APP_SUPPORT_DIR`로 연결 디렉터리를 분리한다. 실행 중인 사용자 앱의 연결 정보나 세션 파일을 덮어쓰지 않는다.

## 관측부터 한다

```sh
./scripts/picky-debug state
./scripts/picky-debug trace --limit 200
```

출력은 JSON이다. `state`의 `result`에서 다음을 대조한다.

- `interaction`: 입력·출력·오버레이 단계와 대기 입력 수
- `voice`: PTT held, 녹음·전사 종료 처리 상태
- `identifiers`: 활성 입력·컨텍스트 ID, 선택 세션과 화면 문맥 대상 세션
- `availability`: 현재 권한·전사 설정·연결 여부
- `trace`: 대기 기록 수, 유실 수, 전송 실패 수

`daemonChannelAvailable`은 요청이 앱에 도달했다는 뜻이지 모델이나 STT가 정상이라는 뜻이 아니다. 권한 조회를 위해 별도 권한 요청을 띄우지 않는다.

짧은 재현 구간은 JSONL로 보관한다. 출력 경로를 기록해 나중에 실제 증거로 제시한다.

```sh
umask 077
TRACE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/picky-debug.XXXXXX")"
./scripts/picky-debug state > "$TRACE_DIR/before.json"
./scripts/picky-debug watch --duration 30 > "$TRACE_DIR/trace.jsonl"
```

`watch`는 별도 터미널이나 지원되는 비동기 셸 도구에서 실행한다. 사용자가 입력하는 동안 관측만 할 수 있다. 캡처가 끝나면 `state`를 `after.json`에 저장한다. 무한 폴링이나 앱 재실행으로 조용한 기록을 채우지 않는다.

## 입력 재현은 명시된 범위에서만 한다

단순 상태 조사 요청에는 입력을 보내지 않는다. 사용자가 해당 입력 재현을 허용했을 때만 `--execute`를 붙인다. 코드 변경 요청만으로 실제 마이크·모델 실행까지 허용됐다고 해석하지 않는다.

```sh
./scripts/picky-debug text '재현용 입력' --execute
./scripts/picky-debug ptt press --execute
# 실제 마이크로 말한 뒤 해제
./scripts/picky-debug ptt release --execute
```

텍스트는 실제 앱 입력 경로로 들어간다. 설정에 따라 화면 문맥 캡처, 외부 STT·모델 호출, TTS가 발생한다. PTT는 실제 마이크이며 음성 파일 주입이 아니다. 이미 다른 입력이 진행 중이면 busy 오류를 먼저 해석한다.

자신이 시작한 PTT는 작업 종료 전에 해제한다. 명령 성공·실패만 보고 해제 여부를 추측하지 말고 `state`의 `voice.pushToTalkHeld`를 확인한다. 기존에 사용자가 누른 PTT를 임의로 해제하지 않는다.

제어 응답의 명령 ID와 입력 ID를 보존한다. 수락은 턴 완료가 아니다. 타임아웃이나 연결 종료 후 같은 제어를 자동 재시도하지 않는다. 이미 실행됐을 수 있으므로 상태·기록으로 결과를 확인한다.

## ID로 흐름을 연결한다

```sh
./scripts/picky-debug timeline --input INPUT_ID
./scripts/picky-debug timeline --context CONTEXT_ID
./scripts/picky-debug timeline --command COMMAND_ID
```

`timeline`은 기록에 함께 등장한 명령·입력·컨텍스트 ID를 따라간다. 같은 세션이나 인접 시각만으로 서로 다른 입력을 묶지 않는다. `--session`은 세션 ID가 없는 초기 앱 기록을 제외하므로 입력 전체를 볼 때는 붙이지 않는다.

음성은 press/release, 전사 완료 또는 실패, 컨텍스트 생성, 전송 수락, 응답 순으로 누락 구간을 찾는다. 텍스트는 입력 수신, 컨텍스트 생성, 전송 수락, 응답을 대조한다. 라우팅이 Pickle로 향했다면 선택된 세션과 화면 문맥 대상 세션을 혼동하지 않는다.

- `main.input.buffered` 뒤의 `main.input.resumed`는 같은 입력의 재개다.
- `main.reply.emitted`는 중간 응답일 수도 있다. `main.turn.settled`의 결과와 분리한다.
- `main.turn.superseded`는 이전 턴의 문맥 교체다. `target`은 새 런타임 입력 ID이며 취소 완료 증거는 아니다.
- 기본 연결은 primary 데몬이다. 별도 Pickle 프로세스의 내부 기록까지 수집했다고 보고하지 않는다.

## 시간을 해석한다

`sourceElapsedMs`, `sourceDeltaMs`는 같은 소스의 기록끼리만 비교한다. 앱과 데몬의 `monotonicMs`를 서로 빼지 않는다. 데몬 `sequence`는 수신 순서이지 프로세스 간 발생 순서가 아니다.

`timingDiscontinuity: true`와 `null` 지연은 시계 역전 구간이다. 이를 `0ms`나 프로세스 재시작 확정으로 바꾸지 않는다. `truncated`, `captureLimitReached`, 앱의 `trace.droppedCount`를 먼저 확인한다. 기록이 유실됐다면 없는 이벤트를 실패의 증거로 단정하지 않는다. 앱 전송 실패는 데몬 순번의 빈칸으로 나타나지 않을 수 있다.

링은 최근 2,000개만 보관한다. 더 긴 구간은 사전에 `watch`로 저장한다. `nextSequence`는 같은 `instanceId`에서만 다음 `--after`에 사용한다. 연결이 끊어진 캡처를 조용히 이어 붙이지 않는다.

## 검증과 보고

진단 결과에는 사용한 입력·연결 대상, ID, 관측된 단계, 같은 소스에서 측정한 시간, 유실 여부, 출력 경로를 짧게 남긴다. 사용자 입력 본문이나 원본 오디오를 보고서에 복사할 필요는 없다. 출력 파일의 식별자도 외부 공유 전 확인한다.

구현을 바꿨다면 영향을 받는 테스트부터 실행한다. CLI·데몬 통합 테스트는 다음 경로다.

```sh
pnpm --dir agentd exec vitest run src/debug-slice.test.ts src/cli/__tests__/debug-cli-e2e.test.ts
```

Swift 검증은 저장소 `AGENTS.md`의 Xcode·DerivedData·실제 실행 확인 규칙을 따른다. Mock 통과, 컴파일 통과, 실제 마이크/STT/HUD 확인을 각각 구분한다. 미실행 검증을 통과로 표시하지 않는다.

종료 코드 `1`은 데몬 오류, `2`는 연결 실패, `3`은 응답 대기 시간 초과, `64`는 인자 또는 `--execute` 누락이다. 앱 재시작, 서명 변경, 배포는 이 스킬이 허용하지 않는다.
