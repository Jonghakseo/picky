# 새 문구 후보

시안에 쓴 문구 중 `Picky/Resources/Localizable.xcstrings`에 아직 없는 것이다. 시안 HTML에는 `data-l10n-new="키"`로 표시돼 있다. UX writing 검수(`.agents/skills/picky-ux-writing/SKILL.md`)를 거쳐 카탈로그에 넣는다. `python3 tools/l10n.py check`는 시안의 새 키가 이 표에 빠져 있으면 실패한다.

| 키(제안) | 한국어 | English | 쓰는 곳 | 메모 |
|---|---|---|---|---|
| `hud.composer.placeholder.steer.touch` | 메시지 보내기 | Message | `composer.html` 실행 중 입력창 안내 | 기존 `hud.composer.placeholder.steer`에는 ⌥↵·esc 단축키 안내가 붙어 있어 폰에 맞지 않는다 |
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
