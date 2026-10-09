# picky-debug

`picky-debug`는 **개발 과정의 재현·측정·진단 전용 CLI**다. 실행 중인 Picky의 입력 상태를 읽고, 오디오·텍스트 입력이 상태 머신과 데몬을 지나가는 과정을 추적한다. 일반 사용자 기능이나 메인 에이전트가 사용하는 제품 CLI가 아니다. 앱과 데몬에 디버그 프로토콜이 포함된 빌드가 필요하다. 구버전 앱에 코드를 주입하거나 앱을 자동 재시작하지 않는다.

## 실행

저장소에서는 다음 진입점을 사용한다.

```sh
./scripts/picky-debug --help
./scripts/picky-debug state
# 같은 명령
pnpm --dir agentd dev:debug state
```

제품의 자동 CLI 설치, 메인 에이전트 PATH, 앱의 번들 스킬에 추가하지 않는다. 프로젝트 Pi 스킬은 [picky-debug](../.agents/skills/picky-debug/SKILL.md)에 둔다.

`PICKY_APP_SUPPORT_DIR`로 별도 연결 디렉터리를 선택할 수 있다. 연결 파일의 인증 토큰은 출력하지 않으며, CLI는 루프백 주소에만 연결한다. 원격 PWA에 이 명령을 추가하지 않는다.

## 입력 흐름 측정

터미널 하나에서 먼저 추적을 시작한다. 출력은 한 줄에 JSON 객체 하나인 JSONL이다.

```sh
./scripts/picky-debug watch --duration 30 > trace.jsonl
```

다른 터미널에서 텍스트를 보내거나 실제 앱에서 입력한다.

```sh
./scripts/picky-debug text '짧게 답해줘' --execute
```

음성은 실제 마이크 PTT를 사용한다. 누른 뒤 말을 하고 반드시 해제한다.

```sh
./scripts/picky-debug ptt press --execute
./scripts/picky-debug ptt release --execute
```

제어는 기존 앱 입력 경로를 거친다. 설정에 따라 화면 문맥을 캡처하고 STT·모델 제공자에게 입력을 전송하거나 음성을 재생할 수 있다. `--execute`가 없으면 제어 명령을 보내지 않는다. 응답은 앱의 명령 수락 결과이며, 모델 응답 완료를 뜻하지 않는다. 타임아웃·연결 단절도 실행 취소를 뜻하지 않으며, 이미 시작된 입력은 계속 진행된다. 결과가 불명확하면 상태를 먼저 확인하고 같은 입력을 자동 재전송하지 않는다.

`ptt press`의 응답에는 앱이 만든 음성 입력 ID(`inputId`)와 입력 생성 여부(`inputStarted`)가 들어 있다. 마이크 시작은 비동기이므로 `inputStarted: true`도 녹음 성공을 보장하지 않는다. 이후 상태와 시작 실패 기록을 확인한다. 앱이 눌림만 접수하고 입력을 만들지 않았다면 `applied: true`, `inputStarted: false`, `inputId: null`일 수 있다. 이미 진행 중인 입력과 충돌하면 busy 오류로 거절한다. `ptt release`는 같은 `inputId`를 되돌려주므로 눌림·해제·전사·응답을 연결할 수 있다.

```sh
./scripts/picky-debug timeline --input INPUT_ID   # press 응답의 inputId
```

이번 범위에 음성 파일 주입은 없다. CLI 프로세스가 끝나더라도 이미 누른 PTT를 자동 해제하지 않는다. 관측 명령인 `state`, `trace`, `timeline`, `watch`는 마이크·화면 캡처, 세션 선택, 모델 실행을 시작하지 않는다.

응답이나 추적에서 얻은 ID로 범위를 좁힌다.

```sh
./scripts/picky-debug trace --after 0 --limit 200
./scripts/picky-debug timeline --input INPUT_ID
./scripts/picky-debug timeline --context CONTEXT_ID
./scripts/picky-debug timeline --command COMMAND_ID
```

`timeline`은 기록에 같이 실린 `commandId`, `inputId`, `contextId`를 따라 관련 기록을 찾는다. 같은 세션에 속하거나 시간이 가깝다는 이유로 서로 다른 입력을 합치지 않는다. `--session`은 각 기록의 세션 ID를 비교하는 추가 필터다. 세션 ID가 아직 없는 앱 입력 기록은 제외되므로, 입력 전체를 보려면 `--input` 또는 `--context`만 사용한다. `trace`와 `watch`의 ID 필터는 각 기록의 필드를 그대로 비교하며, 연결된 다른 ID까지 확장하지 않는다.

각 기록에는 원래 발생 시각과 소스의 단조 시계, 데몬 수신 시각과 순번이 있다. `sourceElapsedMs`는 선택된 기록 중 같은 소스의 첫 기록부터, `sourceDeltaMs`는 같은 소스의 이전 기록부터 지난 시간이다. 앱과 데몬의 단조 시계 기준점은 다르므로 서로 빼서 지연 시간으로 해석하면 안 된다. 데몬 순번은 **수신 순서**이고, 프로세스 간 발생 순서를 보장하지 않는다. 링에서 앞부분이 빠졌다면 최초 입력부터의 전체 지연을 복원할 수 없다. 같은 소스의 시계가 역전되면 재시작과 지연 도착을 구분할 수 없으므로 `timingDiscontinuity: true`와 `null` 지연을 표시하고 측정 구간을 새로 시작한다.

`main.input.accepted`는 최초 수신, `main.input.buffered`는 compaction 대기, `main.input.resumed`는 대기 후 재진입이다. 같은 입력의 재진입을 새 입력 수신으로 세지 않는다. `main.reply.emitted`는 중간 응답을 포함한 실제 응답 방출이며, `main.turn.settled`의 `outcome`에서 완료·실패·취소를 구분한다. `main.turn.superseded`는 이전 턴의 문맥이 새 턴으로 교체됐다는 뜻이고 `target`은 새 런타임 입력 ID다. 실제 런타임 취소 완료를 보장하지 않는다.

## 기록과 손실 표시

데몬은 최근 2,000개 메타데이터 기록만 메모리에 유지한다. 기본 연결은 primary 데몬이며, 별도 프로세스의 Pickle 데몬 내부 기록을 합쳐 주지는 않는다. 앱의 입력·라우팅 관측과 primary의 메인 턴 관측을 구분한다. `trace`는 한 번에 최대 500개를 반환한다. `nextSequence`를 다음 호출의 `--after`에 그대로 전달한다. 필터로 출력이 비어도 커서는 진행한다.

- `instanceId`는 데몬 인스턴스를 구분한다. 재시작 전 커서를 새 데몬에 재사용하지 않는다.
- `truncated: true`이면 요청한 커서 이후의 일부 기록이 이미 링에서 제거됐다.
- `timeline`은 최대 10페이지를 수집한다. `captureLimitReached: true`이면 더 읽을 기록이 있을 수 있다.
- `watch`는 연결이 끊어지면 종료한다. 앱 상태를 바꾸는 명령을 재시도하지 않는다.
- 앱의 발행 소켓이 멈추면 기록은 앱 버퍼에서 버려진다. 데몬이 순번을 매기기 전이라 순번 공백으로는 드러나지 않으므로, `state`의 `trace.droppedCount`와 `trace.transportFailureCount`, 그리고 복구 후 전송되는 `debug.traceDropped` 기록으로 확인한다.

메인 에이전트로 가는 키보드·Quick Input·PTT 입력은 상호작용 상태 머신을 지나며 앱 기록에 남는다. 예외는 **화면 문맥 대상으로 지정된 Pickle로 보내는 Quick Input**이다. 이 입력은 바로 steer·follow-up 명령으로 나가므로 앱 입력 기록이 없다. 소유 데몬에는 수신 기록이 남지만, 별도 Pickle 데몬이라면 기본 primary 조회에 나타나지 않는다.

전사문, 입력 본문, 화면 문맥, 원본 오디오, 도구 인자, 토큰은 추적 기록에 포함하지 않는다. 입력 길이, 상태 이름, 식별자 같은 허용된 필드만 기록한다. 일반 디버그 추적과 달리 기존 상호작용 저널 원본은 이벤트 본문을 포함할 수 있으므로, 이 CLI에서 그대로 내보내지 않는다. CLI 출력 파일에는 세션·입력 식별자가 남으므로 공유 전에 확인한다.

## 구조와 검증 경계

```text
picky-debug
  -> 기존 인증된 로컬 WebSocket
  -> agentd debug feature (앱 요청 중계 + 메타데이터 링)
  -> Picky debugControl 브리지
  -> 기존 앱 입력/상호작용 경로
```

`debugApp` 요청은 선택한 앱 소켓의 완료 응답만 받는다. 추적 발행도 `debugControl` 기능을 등록한 앱 소켓으로 제한한다. 새 포트나 범용 상태 변경·코드 실행 기능은 없다. 기존 로컬 데몬 인증 토큰을 가진 프로세스는 신뢰하는 기존 보안 경계를 따른다. `--execute`는 CLI의 실수 방지 장치이며 별도 권한 체계가 아니다.

CLI 통합 테스트는 실제 WebSocket 서버와 격리된 저장소를 사용하고, 앱 경계만 대체한다. Swift 테스트는 프로토콜과 실제 상호작용 경로의 메타데이터를 확인한다. 이 검증은 실제 마이크, STT 제공자, 화면 권한, TTS 재생까지 확인했다는 뜻이 아니다. 실제 앱에서의 입력 측정은 새 빌드를 사용자가 적용한 뒤 위 절차로 실행한다.

종료 코드는 성공 `0`, 데몬 오류 `1`, 연결 실패 `2`, 시간 초과 `3`, 잘못된 인자·미승인 제어 `64`다. `--timeout <ms>`로 응답 대기 시간을 지정한다. 예를 들어 `picky-debug --timeout 30000 state`다.
