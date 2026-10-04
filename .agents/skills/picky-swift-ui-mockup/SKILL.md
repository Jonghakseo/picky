---
name: picky-swift-ui-mockup
description: Picky UI를 SwiftUI로 1:1 목업하거나, 상태별 화면을 렌더링해 시안·갤러리로 보여 달라는 요청에 사용한다.
---

# Picky Swift UI Mockup

실제 Picky 컴포넌트·치수·토큰을 재사용해 정적 PNG와 1:1 갤러리를 만든다. 제안 목업은 앱 적용이나 실제 동작 검증과 구분한다.

## 실행

1. [Swift UI 목업 런북](../../../runbook/swift-ui-mockup.md)을 먼저 읽고 따른다. 절차와 안전 조건의 정본이며 여기에서 복제하지 않는다.
2. 시각 판단에는 [디자인 스킬](../picky-design-guide/SKILL.md), 사용자 노출 문구에는 [UX writing 스킬](../picky-ux-writing/SKILL.md)을 함께 사용한다.
3. 기존 production gallery로 충분하면 런북의 구현 검증 경로를 선택한다. 제안 목업을 요청받았을 때만 별도 proposal View를 만든다.
4. 작업 막대·상태 목록을 만들 때 [예제 설명](references/async-work/README.md)을 읽고 [Swift 예제](references/async-work/AsyncWorkMockup.swift)를 참고한다. 다른 화면에 예제의 높이·폭·상태 정책을 그대로 적용하지 않는다.

## 도구와 산출물

- [링크 렌더 하네스](scripts/render-mockup.sh): 기존 Debug 모듈을 재사용하고 앱·데몬에 연결하지 않는 Swift executable을 실행한다.
- [갤러리 생성기](scripts/make-gallery.py): PNG 치수를 확인하고 논리 크기로 표시하는 HTML을 만든다. 입력 manifest 계약은 런북에 있다.
- 산출물은 `build/render-gallery/<작업명>/`에 둔다. 재사용할 소스·설명만 스킬의 `references/`에 보관하고 PNG·manifest·로그·실행 바이너리는 커밋하지 않는다.

## 완료 기준

PNG 직접 검수, manifest 치수 확인, 목업/production 구분과 미검증 범위를 완료 보고에 남긴다. 사용자가 열어 달라고 요청한 경우 갤러리를 `open`한다. 렌더 성공을 실제 클릭·IME·스크롤·상태 전이 검증으로 보고하지 않는다.
