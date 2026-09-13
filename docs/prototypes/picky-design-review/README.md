# Picky DS.01 design review kit

검수 전 제안만 담은 독립 HTML 자료다. 메신저 목업과 native Picky에는 적용하지 않는다.

- `index.html`: semantic color, typography, spacing, icon, motion, responsive priorities
- `controls.html`: buttons, fields, choices, tabs, menu, dialog keyboard contracts
- `patterns.html`: roster/status/unread, messages, ask/result, split composer, management and Routine patterns
- `review.js`: graceful local/temporary feedback storage, theme, keyboard behavior and all-page Markdown export

모든 페이지는 네트워크 의존성 없이 `file://`에서 동작한다. 의견은 localStorage를 우선 사용하고 불가능하면 현재 화면의 메모리에만 남긴다. 이때는 이동·새로고침 전에 Markdown을 내려받아야 한다. 내보낸 Markdown은 디자인 제안에 대한 의견이며 제품 실행 증거나 승인 기록이 아니다. 의견은 200개, 각 4,000자까지 보관한다. 작성 중인 의견의 페이지·검수 대상도 함께 저장한다.

사용자가 검수 완료를 명시한 뒤에만 메신저 목업에 적용하고 최종 리뷰한다. HTML 생성·브라우저 검증·커밋은 디자인 승인이나 제품 구현 승인이 아니다.

```bash
node docs/prototypes/picky-design-review/verify-browser.js
```

검증 스크린샷은 `/private/tmp/picky-design-ds01-evidence/`에 만든다. 2026-09-13에 8개 브라우저 검증을 통과했으며 오류·외부 요청은 0건이었다. 세 페이지의 라이트·다크와 1440/1024/390 폭, 키보드, 의견·검수 대상 복원과 내보내기, 저장 차단·손상, Reduce Motion, 기본·hover·키보드 pressed 버튼 대비를 확인했다. 대표 캡처와 내려받은 원문도 직접 읽었다. 이후 루틴 행 정렬과 모의 기록 표시 간격을 다듬고 라이트 1440·다크 390에서 해당 컴포넌트를 다시 캡처해 확인했다.

브라우저 시연은 native VoiceOver, IME, macOS material, 실제 Pi/Routine/Computer 실행 또는 HUD 성능을 증명하지 않는다.
