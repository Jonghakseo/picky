# 새 문구 후보

시안에 쓴 문구 중 `Picky/Resources/Localizable.xcstrings`에 아직 없는 것이다. 시안 HTML에는 `data-l10n-new="키"`로 표시돼 있다. UX writing 검수(`.agents/skills/picky-ux-writing/SKILL.md`)를 거쳐 카탈로그에 넣는다. `python3 tools/l10n.py check`는 시안의 새 키가 이 표에 빠져 있으면 실패한다.

| 키(제안) | 한국어 | English | 쓰는 곳 | 메모 |
|---|---|---|---|---|
| `hud.composer.placeholder.steer.touch` | 메시지 보내기 | Message | `composer.html` 실행 중 입력창 안내 | 기존 `hud.composer.placeholder.steer`에는 ⌥↵·esc 단축키 안내가 붙어 있어 폰에 맞지 않는다 |
| `hud.composer.voice.listening.hint.touch` | 다시 누르면 입력란에 넣어요 | Press again to add it to the input | `composer.html` 음성 입력 듣는 중 줄 | 기존 `hud.composer.voice.listening.hint`에는 "esc 취소"가 붙어 있다. 폰은 줄 끝의 취소 버튼(`common.cancel`)으로 대신한다 |
| `hud.composer.voice.permission.hint.phone` | iPhone 설정의 Safari에서 마이크 접근을 확인해 주세요 | Check microphone access under Safari in iPhone Settings | `composer.html` 폰 마이크 권한 없음 줄(주 문구는 기존 `hud.composer.voice.permission`) | 기존 hint는 맥 시스템 설정을 안내한다. Apple 지원 문서상 웹사이트 마이크 권한은 설정의 Safari > 마이크(묻기·거부·허용)에서 정한다([Apple](https://support.apple.com/guide/iphone/iphb01fc3c85/ios)). '허용'을 고르면 모든 웹사이트에 적용되므로 '허용해 주세요' 대신 '확인해 주세요'로 쓴다. 홈 화면 앱이 이 설정을 따르는지는 실기기로 확인한다 |
| `hud.composer.voice.macUnavailable` | 맥에서 받아쓸 수 없어요 | Can't transcribe on your Mac | `composer.html` 맥에서 받아쓸 수 없음 줄 | 마이크를 누르면 녹음 전에 맥 쪽 준비를 확인한다. 안 되면 녹음하지 않으므로 기존 `hud.composer.voice.failed.hint`(입력한 글은 그대로, 다시 눌러 말하기)를 쓰지 않는다 |
| `hud.composer.voice.macUnavailable.permission.hint` | 맥의 시스템 설정에서 Picky의 음성 인식을 허용해 주세요 | Allow speech recognition for Picky in System Settings on your Mac | `composer.html` 맥에서 받아쓸 수 없음 줄 | 맥의 음성 인식 서비스가 Apple 음성 인식이고 권한이 거부됐을 때. 폰 요청으로 맥에 권한 대화상자를 띄우지 않는다 |
| `hud.composer.voice.macUnavailable.service.hint` | 맥의 Picky 설정에서 음성 인식 서비스를 확인해 주세요 | Check the speech recognition service in Picky settings on your Mac | 시안에 그리지 않음(같은 줄의 다른 원인) | API 키가 없는 등 서비스 설정이 덜 됐을 때(`isConfigured`가 false). 용어는 설정 화면의 `settings.voice.provider.stt`(음성 인식 서비스)를 따른다 |
| `pwa.room.back.accessibilityLabel` | Pickle 목록으로 돌아가기 | Back to Pickle list | `header.html` 뒤로 버튼의 접근성 이름 | 폰에만 있는 버튼 |
| `pwa.roomList.newPickle` | 새 Pickle | New Pickle | `room-list.html` 상단 버튼, 빈 목록 버튼 | |
| `pwa.roomList.filter.all` | 전체 | All | `room-list.html` 그룹 필터 | |
| `pwa.roomList.pinned` | 고정됨 | Pinned | `room-list.html` Picky 방 고정 아이콘의 접근성 이름 | |
| `pwa.roomList.empty.title` | 아직 Pickle이 없어요 | No Pickles yet | `room-list.html` 빈 목록 | |

키 접두어가 `hud.*.touch`와 `pwa.*`로 섞여 있다. 검수 때 하나로 정한다.

## 다른 화면의 키를 빌려 쓴 것

같은 키를 쓰면 한쪽 문구를 고칠 때 다른 쪽도 바뀐다. 검수 때 그대로 둘지, 새 키로 나눌지 정한다.

| 키 | 값 | 원래 쓰는 곳 | 시안에서 쓴 곳 |
|---|---|---|---|
| `messages.title` | 메시지 | Hub 설정의 메시지 화면(`Picky/Hub/Settings/CompanionPanelMessagesView.swift`) | 방 목록 제목 |
| `hud.archivedList.title` | 보관된 Pickle | HUD 보관함 | 방 목록 맨 아래 보관함 항목 |
| `dock.unread` | 읽지 않음 | Dock 읽지 않음 표시 | 방 목록 읽지 않음 점의 접근성 이름 |
