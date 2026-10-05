# 원격 PWA 접근 계획

_상태: 1~4단계 구현됨(실행 중인 앱에는 재시작해야 반영), 실기기 확인 일부 남음 · 작성일: 2026-10-04 · 갱신: 2026-10-05_

Picky와 Pickle 세션은 지금처럼 내 맥에서 실행하고, 밖에서는 폰(iPhone 홈 화면 PWA)으로 보고 조작한다. 실행 위치는 옮기지 않는다. Picky가 운영하는 서버는 두지 않고, 사용자가 고른 망과 맥 앱이 발급한 기기 인증으로만 연결을 연다.

## 범위

- 한다: 세션 목록·상세·진행 상황 실시간 보기, follow-up·steer·중단·질문 응답, Pickle 생성, 메인 대화, 알림, 사진 첨부, 입력창 받아쓰기, 산출물과 대화 속 파일 미리보기.
- 안 한다: 클라우드·VM 런타임, 세션 이전, Linux 패키징, Picky가 운영하는 중계 서버, 네이티브 iOS 앱, 다른 앱에서 공유해 보내기(Web Share Target은 iOS Safari가 지원하지 않는다, [MDN](https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Manifest/Reference/share_target#browser_compatibility)).

## 결정

1~5는 2026-10-04, 6~9는 2026-10-05에 정했다. 8과 9는 구현을 시작하며 코드를 확인하고 바꾼 결정이고, 자세한 근거는 `docs/remote-pwa-implementation.md` 1절에 있다.

| # | 결정 | 이유 |
|---|---|---|
| 1 | 접속 망은 Tailscale Serve와 Cloudflare Tunnel을 모두 지원하고 사용자가 고른다 | Tailscale은 한 기기가 동시에 tailnet 하나만 쓸 수 있다([문서](https://tailscale.com/kb/1225/fast-user-switching)). 회사 tailnet을 쓰는 사람은 개인 tailnet을 함께 붙일 수 없다 |
| 2 | 원격 권한은 셸을 포함해 전부 허용한다. 폰은 HUD와 같은 권한을 가진다 | 에이전트가 어차피 bash를 실행하므로 `!` 직접 실행만 막아도 얻는 것이 적다. 대신 기기 토큰이 곧 맥 셸 열쇠가 되므로 페어링과 기기 해제가 핵심 방어선이다 |
| 3 | 원격 입력용 프로토콜 출처 값을 새로 만들지 않는다. 허브는 HUD가 쓰는 앱 내부 명령을 그대로 호출한다 | 데몬이 HUD 입력과 똑같이 받으므로 경험이 같아진다. CLI 진입 명령을 쓰면 경험이 달라진다([경험 동일성 규칙](#경험-동일성-규칙)) |
| 4 | local-first 규칙을 좁혀서 고친다 | Picky 운영 백엔드와 계정 인증은 계속 두지 않는다. 원격 접속은 기본 꺼짐이고, 사용자가 고른 망과 앱이 페어링한 기기로만 연다. `AGENTS.md`와 `ARCHITECTURE.md`에 반영했다 |
| 5 | PWA는 새 메신저 기획으로 만든다. Picky와 Pickle을 방 목록에 방처럼 보여 주고, 방 안은 HUD 대화 카드와 똑같이 보여 준다 | 폰에서 익숙한 구조다. HUD 대화 카드는 이미 메신저형(날짜 구분선, 전송 시각, 작업 중 표시)이고 최소 폭 360pt까지 지원해 iPhone 폭에 들어간다. 메신저 B 명세(`docs/picky-b-messenger-ux-spec.md`)와는 별개라서 중단 버튼 제거와 steer 단일화는 적용하지 않는다 |
| 6 | 폰 받아쓰기는 폰에서 녹음하고 맥이 받아쓴다. 맥의 음성 인식 서비스와 언어 설정을 그대로 쓴다 | 맥에서 받아쓸 때와 같은 서비스와 언어 설정으로 받아쓴다. 대신 녹음이 맥으로 가고, 그다음은 맥 받아쓰기와 같은 경로(Apple 음성 인식 또는 사용자가 고른 외부 서비스)를 탄다([폰 받아쓰기](#폰-받아쓰기)) |
| 7 | 대화 속 파일 링크는 폰에서 읽기 전용 미리보기로 연다 | HUD는 링크를 맥의 기본 앱으로 연다. 폰에서 같은 일을 하면 파일이 맥 화면에만 열려 폰 사용자는 볼 수 없다([파일 미리보기](#파일-미리보기)) |
| 8 | gateway가 각 데몬에 v2 projection 구독자로 직접 붙는다. 앱은 프레임을 중계하지 않고 데몬 목록과 세션 소유(child가 있으면 child)만 알려 준다 | 앱은 프레임 원문을 버리고 Swift projection 타입은 디코딩만 한다. 데몬은 구독자를 여럿 받을 수 있고 복구 요청도 소켓별로 막는다. 그래서 앱 메인 스레드 중계 비용이 아예 생기지 않는다 |
| 9 | 세션 명령은 gateway가 HUD와 같은 데몬 명령으로 소유 데몬에 직접 보낸다. Pickle 생성, 메인 대화, 읽음, 보관, 받아쓰기만 허브가 앱 안에서 처리한다 | HUD 세션 명령은 검증 뒤 데몬 명령 하나를 보내는 얇은 래퍼다. 앱에 남는 동작은 `select`와 맥 컴포저 복원처럼 폰에서 피해야 할 부수효과뿐이다. CLI 진입 명령을 쓰지 않으므로 결정 3의 취지는 그대로다 |

## 구조

```mermaid
flowchart TB
  P[iPhone 홈 화면 PWA] -->|tailnet| TS[Tailscale Serve]
  P -->|Cloudflare 엣지, Access는 선택| CF[cloudflared 터널]
  TS --> G
  CF --> G
  G[gateway<br/>Node, 127.0.0.1, 원격 접근을 켜면 앱이 띄움]
  H[원격 허브<br/>Picky.app 안] -->|로컬 WebSocket, 허브 전용 토큰| G
  H --> PR[primary agentd]
  H --> CH[child agentd ×N]
  G -.->|Web Push| PS[Apple·Google 푸시 서비스] -.-> P
```

- **PWA:** 정적 SPA와 서비스 워커로 만든다. 세션 상태는 `agentd/src/domain/session-projection-reducer.ts`로 계산한다. `contracts/projection/conformance/` 시나리오가 Swift reducer와 같은 결과를 보장한다.
- **gateway:** agentd 패키지에 별도 entry로 둔다. 하는 일은 PWA 파일 제공, 페어링과 기기 토큰 발급, 허용 목록 API, 명령 id 중복 제거, Web Push 발송, 감사 로그다. 외부 입력을 받는 코드는 이 프로세스에만 둔다.
- **원격 허브:** 앱이 gateway에 클라이언트로 접속한다. 앱에는 서버 코드를 두지 않는다. 아래 목록 중 상세와 명령은 결정 8·9로 바뀌었다(데몬 직결).
  - 목록: 레지스트리 읽기 모델을 쓴다.
  - 상세: 소유권 원장이 승인한 v2 프레임을 그대로 중계한다.
  - 명령: HUD와 같은 앱 내부 명령(`Picky/HUD/Conversation/PickySessionCommands.swift`)으로 실행한다.
  - 받아쓰기: gateway가 넘긴 폰 녹음을 앱의 음성 인식 서비스로 받아쓴다([폰 받아쓰기](#폰-받아쓰기)).
- **agentd 데몬:** 바꾸지 않는다.

허브를 앱 안에 두는 이유는 두 가지다.
- child 세션의 실시간 상태와 소유권 판정(`Picky/Sessions/Projection/PickyProjectionOwnershipLedger.swift`)이 앱에만 있다.
- 데몬은 앱이 꺼지면 같이 꺼진다(`agentd/src/main.ts`의 parent watchdog). 그래서 원격 접속 중에도 앱은 어차피 켜져 있어야 한다.

맥이 잠들거나 앱이 꺼지면 폰에서 접속할 수 없다.

## 보안

전제는 원격 권한이 곧 맥 셸 권한이라는 점이다(결정 2).

**두 경로 공통 (gateway)**
- 페어링은 맥 앱에서 등록 모드를 켤 때만 가능하다. 맥 화면에 QR을 띄우고, 설치한 홈 화면 앱 안에서 스캔한다. 코드는 한 번만 쓸 수 있고 몇 분 뒤 만료된다.
- iOS 홈 화면 앱은 Safari와 쿠키·저장소가 분리되어 있다([WWDC23](https://developer.apple.com/videos/play/wwdc2023/10120/)). Safari에서 페어링하면 인증이 앱에 남지 않으므로 반드시 앱 안에서 한다.
- 기기 토큰은 추측할 수 없는 길이의 난수로 만들고, gateway 출처의 쿠키(`HttpOnly`, `Secure`, `SameSite=Lax`)에 담는다. 맥에는 토큰의 해시만 저장한다. 짧은 숫자 코드를 쓰게 되면 시도 횟수 제한이 반드시 있어야 한다.
- WebSocket 업그레이드와 상태를 바꾸는 요청은 자기 출처에서 온 것만 받는다(`Origin`, `Sec-Fetch-Site` 확인). 다른 사이트의 페이지가 사용자의 쿠키를 빌려 명령을 보내지 못하게 한다.
- 인증 실패가 반복되면 IP와 기기 단위로 차단한다. 초기값은 같은 IP에서 10분에 5회 실패하면 15분 차단, 페어링 코드는 5회 틀리면 폐기다. Cloudflare 경로의 실제 접속 IP는 `CF-Connecting-IP`에서 읽는다. 인증 없이 열리는 것은 PWA 정적 파일과 페어링 엔드포인트뿐이다.
- 맥에 있는 파일(도구가 읽은 이미지, 산출물, 대화 속 파일 링크)은 그 세션의 메시지와 산출물에 기록된 경로만, 실제 경로로 정규화한 뒤 제공한다. 이미지는 확장자와 파일 첫 바이트로 형식을 확인하고 크기 상한을 둔다. SVG와 HTML 산출물은 CSP `sandbox`로 스크립트를 막거나 다른 출처로 격리해 연다.
- 기기 목록과 해제는 맥에서 한다. 해제하면 그 기기의 연결은 즉시 끊긴다. 원격 명령은 감사 로그에 남긴다.

**Tailscale 경로**
- Serve는 tailnet 멤버만 접근할 수 있고 공개 인터넷에 노출되지 않는다([문서](https://tailscale.com/docs/features/tailscale-serve)). 아이폰도 같은 tailnet에 들어가 있어야 한다.
- tailnet IP에 http로만 열면 보안 컨텍스트가 아니라서 서비스 워커와 Web Push가 동작하지 않는다. pi-pocket도 알림에는 https가 필요하다며 `tailscale serve`를 앞에 두라고 안내한다. 그래서 처음부터 Serve를 쓴다.

**Cloudflare 경로**
- 터널은 맥에서 밖으로만 연결하므로 맥에 열린 포트가 없다([문서](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)).
- 모든 플랜에 DDoS 방어가 기본으로 들어 있다([문서](https://developers.cloudflare.com/ddos-protection/about/)).
- 무료 플랜의 레이트 리밋은 규칙 1개, IP 기준, 집계·차단 모두 10초다([문서](https://developers.cloudflare.com/waf/rate-limiting-rules/)). 세밀한 조정은 어렵다.
- Access는 선택 계층이다. Access 정책을 통과한 사용자만 맥까지 오고, `access.required`를 켜면 cloudflared가 Access JWT 없는 요청을 거부한다([문서](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/origin-parameters/)). Access 일회용 코드의 시도 횟수 제한은 공식 문서에서 찾지 못했다.
- 공개 호스트네임을 쓰려면 Cloudflare에 올린 도메인이 필요하다. Quick Tunnel은 테스트용이고([문서](https://developers.cloudflare.com/tunnel/setup/)) 실행할 때마다 주소가 바뀐다. 홈 화면 앱과 Web Push 구독은 주소(출처)에 묶이므로 주소가 바뀌면 앱을 다시 설치하고 알림을 다시 허용해야 한다. pi-pocket은 Quick Tunnel이 이벤트 스트림을 붙잡아 두는 문제 때문에 롱폴링으로 자동 전환한다. 그래서 쓰지 않는다.

## 경험 동일성 규칙

허브는 CLI 진입 명령(`submitMainFromExternal`, `createPickleFromExternal`, `controlPickle`)을 쓰지 않는다. 쓰면 다음처럼 달라진다.

- 폰에서 보낸 메인 대화의 답을 맥이 커서 말풍선과 음성으로 낸다. `cli` 출처는 `.cli` 소유자로 바뀌고, 이 소유자는 커서 표시와 음성을 쓴다(`Picky/Interaction/PickyInteractionReducer.swift`의 `applyQuickReply`, `Picky/Interaction/PickyInteractionState.swift`의 `usesCursorResponsePresentation`).
- Pickle이 HUD에서 만들 때처럼 전용 child 데몬에 생기지 않고 primary 데몬에 생긴다. 제목과 지시도 반드시 필요하다(`agentd/src/protocol.ts`의 `createPickleFromExternal`, `docs/per-pickle-daemon-topology.md`).
- steer, follow-up, 중단 말고는 할 수 없다(`agentd/src/protocol.ts`의 `controlPickle`).

맥 쪽에서 생기는 차이는 앱이 처리한다.

- 폰 메인 대화는 화면 캡처 없이 컨텍스트를 만든다. 허브가 그 context id를 앱 내부의 원격 소유로 먼저 등록해서 맥 말풍선과 음성을 끈다. 프로토콜 변경은 없다.
- 폰 조작이 맥 HUD에서 선택된 세션을 바꾸지 않게 한다. 지금 `PickySessionViewModel.followUp`은 `select`를 호출한다.
- `abortRestoringQueuedInputs`는 대기 입력을 맥 composer에 되돌린다. 폰에서 중단할 때는 폰 쪽으로 되돌리는 처리가 따로 필요하다.

`remote` 출처 값은 모델이 "사용자가 맥 앞에 없다"는 것을 알아야 하는 문제가 3단계에서 확인될 때만 추가한다.

## 화면

결정 5를 따른다. 대화방은 HUD를 옮기는 작업이고, 방 목록만 새로 설계한다.

### 방 목록 (기본안, 목업 검수에서 확정)

- 맨 위에 Picky 방(메인 대화)을 고정하고, 그 아래 Pickle 방을 최근 활동 순으로 둔다. 고정한 Pickle은 Picky 방 바로 아래에 둔다.
- 행에는 제목, 상태(아이콘과 글자를 함께 써서 색만으로 구분하지 않는다), 마지막 요약 한 줄, 시각, 읽지 않음 표시를 둔다.
- Dock 그룹은 목록 위 필터로 보여 준다. 보관한 Pickle은 목록 맨 아래 "보관함"에서 연다.
- 읽음 상태는 맥과 공유한다. 단일 출처는 앱의 `PickySessionViewModel.unreadSessionIDs`이고, 폰에서 방을 열면 맥 Dock의 읽지 않음 표시도 꺼진다.
- 새 Pickle은 최근·고정 폴더 중에서 골라 만든다(3단계). 폰에서 맥 폴더를 탐색하지 않는다.

### 대화방

- HUD 대화 카드(`Picky/HUD/Conversation/PickyConversationCardView.swift`)의 머리줄, 말풍선 목록, 실행 중 작업 줄, 입력창을 그대로 옮긴다. 말풍선 종류는 `Picky/HUD/Conversation/Bubbles/`에 있는 것(사용자, 에이전트, 질문, 오류, 서브에이전트, 도구 활동, 날짜 구분선, 작업 중 표시)을 따른다.
- HUD 카드는 기본 폭 446pt, 최소 폭 360pt를 지원한다(`Picky/App/Settings/PickySettings.swift`의 `PickyHUDCardSize`). iPhone 세로 폭 375~440pt에서 같은 레이아웃이 다시 배치된다.
- Picky 방도 같은 대화방 구성으로 메인 대화를 보여 준다. 맥에서는 Hub 대화 화면과 커서 말풍선에 나오는 내용이다.
- 폰에서 바뀌는 것:
  - hover로만 보이던 것(말풍선 전송 시각, 보고서로 열기 아이콘, 작업 중 경과 시간)은 탭이나 길게 누르기로 보인다.
  - Option+Return(답 끝나면 보내기) 같은 단축키는 보내기 메뉴에서 고른다.
  - 한글 조합 중 Return은 보내지 않는다(웹 `isComposing`).
  - 누를 수 있는 영역은 44pt 이상으로 둔다.
  - 입력창 마이크는 폰에서 녹음하고 맥이 받아써 입력란에 넣는다. 보내지는 않는다([폰 받아쓰기](#폰-받아쓰기)). 맥은 esc로 취소하지만 폰은 듣는 중 줄 끝의 취소 버튼으로 취소한다. 실패·권한 안내는 다음 행동이 잘리지 않게 줄바꿈한다(HUD는 한 줄에서 자른다).
  - 설정 칩 시트(모델, 생각 수준, Fast, 완료 알림)에서 단축키 안내(⌃P, ⌘N)를 뺀다.
  - 백그라운드 작업이 도는 Pickle을 멈추면 HUD처럼 "응답만 중단"과 "백그라운드 작업도 함께 종료"를 묻는다. 웹은 선택지를 넣은 시스템 알림을 띄울 수 없어서 같은 선택지를 직접 그린다.
  - 작업 패널은 결과물·변경사항 탭만 연다. 터미널 탭은 뺀다.
- 도구가 읽은 이미지와 대화 속 파일 링크는 저널에 맥 경로만 있다. 폰에서는 gateway가 썸네일과 읽기 전용 미리보기를 대신 보여 준다([파일 미리보기](#파일-미리보기)).
- 폰에서 빼는 것: 눌러서 말하기(음성 follow-up), 화면 컨텍스트 지정, 내장 터미널, Pi 터미널 동기화, Dock 드래그. 모두 맥 앞에 있어야 의미가 있는 기능이다.

### 폰 받아쓰기

결정 6을 따른다. 상태는 HUD 입력창 받아쓰기(`Picky/Companion/Dictation/PickyComposerDictationController.swift`)와 같다. 준비 중, 듣는 중, 받아쓰는 중을 거쳐 받아쓴 글을 입력란 끝에 붙이고, 보내지는 않는다. 폰에서만 생기는 실패는 폰 마이크 권한 없음과 맥에서 받아쓸 수 없음 두 가지다. 문구 후보는 시안의 `new-strings.md`에 있다.

- 마이크를 누르면 녹음하기 전에 맥이 받아쓸 수 있는지 확인한다(음성 인식 서비스 설정, Apple 음성 인식 권한). 안 되면 녹음하지 않고 이유를 보여 준다.
- 폰은 `MediaRecorder`로 녹음한다. iOS Safari는 14부터 지원하고([MDN](https://developer.mozilla.org/en-US/docs/Web/API/MediaRecorder#browser_compatibility)), 마이크는 https에서만 열린다. 다시 누르면 녹음을 맥으로 보내고, 취소하면 버린다.
- 녹음 형식은 맥의 `AVAudioFile`이 열 수 있어야 한다. Android Chrome 154 실기기에서 확인하니 기본값 `audio/webm;codecs=opus`와 `audio/mp4`(안에 Opus)는 열리지 않고 `audio/mp4;codecs=mp4a.40.2`(AAC)만 열렸다. 그래서 AAC를 먼저 요청하고, WebKit(iOS)에서는 AAC로 녹음되는 `audio/mp4`를 다음으로 쓰고, 둘 다 안 되면 Web Audio로 16kHz WAV를 만든다(`agentd/web/src/room/policy/recording.ts`).
- 맥은 녹음을 PCM으로 풀어 HUD 받아쓰기와 같은 음성 인식 서비스 세션에 넣는다(`Picky/Companion/Dictation/BuddyTranscriptionProvider.swift`). 맥 마이크는 쓰지 않는다. OpenAI, Azure OpenAI, ElevenLabs 연결은 지금도 녹음을 모았다가 끝날 때 한 번에 올리므로, 녹음 파일을 넣어도 같은 방식으로 받아쓴다.
- 폰 요청으로 맥에 권한 대화상자를 띄우지 않는다. 음성 인식 서비스가 Apple 음성 인식이고 권한을 아직 묻지 않았다면, 맥에서 원격 접속을 켤 때 허용 버튼을 보여 준다.
- 녹음은 받아쓰기가 끝나면 지운다. 길이 상한은 5분(초기값)이고, 넘으면 녹음을 멈추고 받아쓴다. 녹음과 받아쓴 글은 감사 로그에 남기지 않는다.

### 파일 미리보기

결정 7을 따른다.

- 대화 속 파일 링크, 도구 이미지, 산출물은 같은 미리보기로 연다. 편집, 맥에서 열기, Finder에서 보기는 없다.
- 경로는 HUD와 같은 규칙으로 해석한다. 상대 경로는 그 세션의 작업 폴더 기준이고, `~`는 홈 폴더다(`Picky/HUD/Conversation/Bubbles/PickyMarkdownLinkHandler.swift`). 그다음 보안 절의 맥 파일 규칙을 적용한다.
- 텍스트와 코드는 고정폭 글꼴로 보여 준다. 마크다운은 말풍선과 같은 정화 규칙으로 그리고, 이미지와 PDF는 그대로 보여 준다. HTML과 SVG는 보안 절의 격리 규칙으로 연다. 그 밖의 형식과 폴더는 이름과 크기만 보여 준다.
- 텍스트는 앞부분 1MB(초기값)까지만 보여 주고, 잘렸다고 표시한다.
- 미리보기는 지금 맥에 있는 내용이다. 메시지를 쓴 뒤 파일이 바뀌었을 수 있고, HUD에서 열 때도 마찬가지다.
- 미리보기 안의 파일 링크는 따라가지 않는다.
- 파일이 없거나 경로를 알 수 없을 때는 HUD 문구(`hud.markdownLink.*`)를 쓴다. "Finder에서 열어 보세요"는 폰에서 할 수 없으므로 그 안내만 새로 정한다.

### 동일성 유지 장치

HUD는 SwiftUI, PWA는 웹이라 공유하는 화면 코드가 없다. 그대로 두면 HUD가 바뀔 때마다 PWA가 뒤처진다. 대상마다 출처를 하나로 두고 차이를 잡는 장치를 붙인다.

| 대상 | 단일 출처 | 장치 |
|---|---|---|
| 세션 상태 | v2 projection | `agentd/src/domain/session-projection-reducer.ts`와 `contracts/projection/conformance/` 시나리오(완료) |
| 문구 | `Picky/Resources/Localizable.xcstrings` (`hud.*` 595개) | 빌드할 때 PWA가 쓰는 키만 JSON으로 추출한다 |
| 색·간격·글꼴 | `Picky/DesignSystem.swift`, `Picky/HUD/PickyHUDTypography.swift` | CSS 변수를 생성하고, 두 값이 어긋나면 실패하는 가드를 둔다 |
| 표시 정책 | 상태 라벨·톤, 도구 요약, 산출물 배지 같은 Swift 정책(`Picky/HUD/PickySessionStatusPresentation.swift` 등) | TS로 옮길 때 언어 중립 fixture로 양쪽을 함께 검증한다. 1-c conformance와 같은 방식이다 |
| 겉모습 | HUD 렌더 갤러리 | 같은 fixture의 HUD PNG와 PWA 스크린샷을 나란히 놓고 비교한다. 글꼴 렌더링이 달라 픽셀 일치는 요구하지 않는다 |

### 출력 렌더링 보안

맥은 마크다운을 SwiftUI `AttributedString`으로 그려 스크립트가 실행되지 않는다. PWA는 에이전트가 읽은 웹페이지나 저장소 내용을 HTML로 그린다. 이 출처의 요청에는 셸 권한 기기 쿠키가 자동으로 붙으므로, 스크립트가 하나라도 실행되면 `!` 명령을 보낼 수 있다. 에이전트 출력은 HTML 정화(sanitize) 후 그리고, CSP로 인라인 스크립트와 외부 스크립트를 막는다. 1단계부터 적용한다.

### 검수 순서

1. 토큰 CSS와 컴포넌트 HTML을 파트별 파일로 만들고, HUD 렌더 갤러리 PNG 옆에 놓고 검수한다. 시안은 `docs/prototypes/picky-remote-pwa/`에 둔다.
2. 검수가 끝나면 화면 목업(방 목록, 대화방, 페어링, 파일 미리보기)을 만든다.
3. 목업 검수 뒤 1단계 구현에 적용한다. 시안은 프레임워크 없이 HTML·CSS로 만들어 구현으로 옮기기 쉽게 둔다.

## 단계와 통과 기준

1. **맥 안에서 읽기 전용 (외부 노출 없음)**
   - 만들 것: gateway와 원격 허브, 방 목록과 대화방 보기(Picky 방 포함), 도구 이미지 썸네일(세션에 기록된 경로만).
   - 통과 기준:
     - mock 런타임에서 HUD로 만든 child Pickle의 진행이 localhost 브라우저에 실시간으로 보인다.
     - child 해제나 앱 재연결 뒤에도 웹 reducer 상태가 HUD와 같다.
     - 인증되지 않은 연결은 거부된다.
2. **밖에서 접속·설치**
   - 만들 것: 입구 2종, 앱 안 QR 페어링, 기기 목록과 해제, 실패 반복 차단, manifest와 서비스 워커.
   - 통과 기준:
     - 두 입구 모두에서 아이폰 홈 화면 앱이 페어링 후 목록을 본다.
     - 해제한 기기의 연결은 즉시 끊긴다.
     - iOS 홈 화면 앱에서 Access 로그인이 유지되는지 실기기로 확인한다.
     - Cloudflare 경로에서 WebSocket이 프록시에 막히거나 늦게 전달되지 않는지 실기기로 확인한다. 막히면 pi-pocket처럼 SSE와 POST 조합으로 바꾼다.
3. **폰에서 제어**
   - 만들 것: 대화방 입력창(HUD와 같은 보내기 방식, 중단과 중지 선택, 예약 전송, 설정 칩), 질문 응답, `!` 셸, Pickle 생성, Picky 방 입력. 모두 HUD 명령을 재사용한다. 명령 id 중복 제거, 맥 말풍선·음성 끄기. 입력창 받아쓰기는 폰 녹음을 맥의 음성 인식 서비스 세션에 넣는 경로를 새로 만든다.
   - 통과 기준:
     - 재연결 뒤 같은 명령 id를 다시 보내도 follow-up은 한 번만 들어간다.
     - 폰에서 질문에 답하면 Pickle이 이어서 진행한다.
     - 폰에서 보낸 메인 대화에 맥이 말하지 않는다.
     - 맥의 음성 인식 서비스 네 가지(Apple 음성 인식, OpenAI, Azure OpenAI, ElevenLabs)에서 폰 녹음이 입력란에 들어가고, 보내지지는 않는다.
     - 맥에 Apple 음성 인식 권한이 없으면 맥에 대화상자가 뜨지 않고, 폰에 안내가 나온다.
     - iOS 홈 화면 앱에서 마이크 권한 요청이 뜨는지, 거부한 뒤 안내한 설정으로 권한을 되돌릴 수 있는지 실기기로 확인한다.
4. **알림·첨부·가용성**
   - 만들 것: Web Push(질문 대기, 완료, 실패), 사진 첨부, 파일 미리보기(산출물, 대화 속 파일 링크, 도구 이미지 원본), 잠자기 방지 옵션, 감사 로그.
   - Web Push 규칙: 그 방을 보고 있는 동안에는 보내지 않는다. 홈 화면 아이콘 배지에 답을 기다리는 방 수를 표시한다. 구독 주소는 알려진 푸시 서비스(Apple, Google, Mozilla, Microsoft)만 받아서 gateway가 임의 주소로 요청을 보내지 않게 한다. 기기당 구독 수에 상한을 두고, 404·410 응답이 오면 구독을 지운다. VAPID subject는 입구의 https 주소로 한다.
   - 통과 기준:
     - 잠긴 폰에 질문 대기 알림이 온다.
     - 세션 메시지와 산출물에 기록되지 않은 경로를 요청하면 거부된다.
     - 상대 경로 링크가 HUD에서 누를 때와 같은 파일을 연다.
     - 알림을 누르면 그 방이 열린다.

## 참고한 구현: pi-pocket

[pi-pocket](https://github.com/TannerMidd/pi-pocket)(커밋 `c3c55f3`, 2026-10-04)은 Pi를 자체 서버에서 직접 돌리는 모바일 웹 앱이다. Pi Durable과 SQLite에 세션을 저장하고, 같은 서버가 PWA를 제공한다. Picky는 맥 앱이 세션을 가지므로 구조는 다르지만, 원격 접속과 알림 부분은 겹친다. 가져온 것과 가져오지 않은 것을 남긴다.

| 항목 | pi-pocket | 이 계획 |
|---|---|---|
| 실시간 전송 | SSE를 쓰고 막히면 롱폴링으로 바꾼다. 다시 연결하면 전체 상태를 새로 받는다 | WebSocket과 v2 projection의 revision 복구를 유지한다. 2단계 실기기에서 막히면 SSE로 바꾼다 |
| 명령 중복 | 요청 id로 같은 메시지를 두 번 보내지 않는다 | 같은 방식(명령 id 중복 제거) |
| 인증 | 소유자 토큰은 해시로 저장하고 1년짜리 쿠키에 담는다. 초대 코드는 15분짜리 1회용이고, 실패 차단은 없다 | 쿠키 속성과 해시 저장을 가져온다. 기기별 토큰, 즉시 해제, 실패 차단은 유지한다 |
| 다른 사이트 요청 차단 | `Sec-Fetch-Site`로 다른 사이트에서 온 로그인·초대 요청을 거부한다 | WebSocket과 상태를 바꾸는 요청 모두에 출처 확인을 둔다 |
| 접속 방식 | local, LAN, Quick Tunnel, tailnet IP(http) | Tailscale Serve와 도메인 있는 Cloudflare Tunnel만 쓴다. https가 있어야 서비스 워커와 푸시가 동작한다 |
| Web Push | 의존성 없이 직접 구현한다. 푸시 서비스 주소 허용 목록, 기기 10대, 보고 있는 방은 알리지 않기, 아이콘 배지 | 4단계 규칙으로 가져온다 |
| 알림에서 허용·거절 | 알림 버튼으로 답한다. 호출 전체가 한 줄에 보일 때만 허용 버튼을 준다 | iOS에서 안 되므로 열린 확인 사항으로 둔다 |
| 다른 앱에서 공유 | Web Share Target(Android) | iOS에서 안 되므로 범위 밖이다 |
| 파일과 산출물 | 확장자와 파일 첫 바이트로 이미지를 확인하고, SVG와 산출물은 CSP `sandbox`로 연다 | 보안 절의 맥 파일 규칙으로 가져온다 |
| 여러 사람 참여, 지속 런타임, 포크, 계획 모드 | 있다 | 해당 없다. 혼자 쓰고, 런타임은 맥 앱이 가진다 |

## 열린 확인 사항

- iOS 홈 화면 앱에서 Access 로그인이 유지되는지 확인한다(2단계 실기기). 범위 밖 링크는 Safari View Controller로 열리므로, 로그인 뒤 쿠키가 앱에 남는지 확실하지 않다. 안 되면 Cloudflare 경로는 Access 없이 gateway 인증과 엣지 방어로 운영한다.
- 홈 화면 앱 안에서 카메라로 QR을 스캔할 수 있는지 확인한다(2단계). 안 되면 코드 입력 방식에 시도 횟수 제한을 둔다.
- 실기기 확인이 남았다. 2026-10-05 Android(Galaxy Z Fold8, Chrome 154)를 USB로 dev 하네스에 붙여 페어링, 방 목록, 한글 입력과 보내기, 사진 첨부, 연결 끊김과 재연결을 확인했고, 폰 녹음 파일이 맥(`AVAudioFile`)에서 열리는 것까지 봤다. 같은 날 Cloudflare Quick Tunnel 뒤의 dev 하네스에 데스크톱 Chrome으로 접속해 페어링(Secure 쿠키), `wss` 연결, 전송 후 실시간 프레임(27ms), 터널 경유 `/hub` 차단, 교차 출처 403을 확인했다. 그래서 Cloudflare 경로의 WebSocket은 막히지 않는다. 재시작한 실제 앱, iPhone 홈 화면 앱, Tailscale Serve 입구, 폰에서의 Cloudflare 접속, 잠긴 폰의 푸시 수신(그 폰 Chrome이 알림 요청을 거부하도록 설정돼 있었다), 맥 음성 인식 서비스 네 가지는 아직 실기기로 확인하지 않았다.

구현하며 닫은 항목:

- 복구 스냅샷이 앱의 projection 처리와 섞이는 문제와 앱 메인 스레드 중계 비용은 결정 8로 없어졌다. gateway가 데몬에 직접 붙고, 데몬은 복구 요청을 소켓별로 처리한다.
- 방 목록은 목업 검수에서 기본안(Picky 방 고정, 최근 활동 순, 그룹 필터, 읽음 공유)으로 확정했다.
- PWA는 Preact와 `@preact/signals`로 만들었다(`docs/remote-pwa-implementation.md` 4절).
- 알림에서 바로 답하기는 넣지 않는다(2026-10-05 결정). Android Chrome에서만 되고 iOS Safari는 알림 버튼(`actions`)을 지원하지 않는다([MDN](https://developer.mozilla.org/en-US/docs/Web/API/ServiceWorkerRegistration/showNotification#browser_compatibility)). 알림을 누르면 그 방이 열리는 동작만 둔다.
- 텔레그램 원격 계획은 진행하지 않기로 하고 문서를 지웠다(2026-10-05). 원격 감독은 이 PWA로 한다.
