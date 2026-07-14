# Picky Design Review Templates

## Design Decision Card

새 컴포넌트나 의미 있는 시각 변경을 구현하기 전에 작성한다.

```markdown
## Design Decision Card

- 사용자 목표:
- 대상 surface/component:
- 첫 시선 정보:
- Primary action:
- Secondary action:
- Session/status semantics:
- 필요한 상태:
  - Rest:
  - Hover:
  - Pressed:
  - Focused:
  - Disabled:
  - Running/waiting/completed/failed:
- Token plan:
  - Color:
  - Typography:
  - Spacing/shape:
  - Material/elevation:
  - Motion:
- Native macOS behavior:
- Accessibility/appearance:
- 유지할 기존 동작:
- 리스크와 검증:
- 명시적 예외:
```

작은 token 교정은 불필요한 항목을 생략해 한 문단으로 축약할 수 있다.

## Design Audit Report

```markdown
# Design Audit — [surface]

- 범위:
- 구현 경로:
- 검수 appearance/state:
- 관련 Picky invariant:

## Summary

한 문단 총평.

## Score

| 기준 | 점수 | 근거 |
|---|---:|---|
| Information hierarchy | 0–2 | |
| Action/status semantics | 0–2 | |
| Token consistency | 0–2 | |
| Density/spacing | 0–2 | |
| Interaction completeness | 0–2 | |
| Appearance/accessibility | 0–2 | |
| Material/elevation/motion | 0–2 | |
| Product invariants | 0–2 | |

## Findings

1. `[P0–P3]` 제목
   - 근거: `path/to/file.swift:line`
   - 사용자 영향:
   - 위반 기준:
   - 권고:

## Keep

- 이미 잘 작동하며 유지해야 하는 결정

## Recommended sequence

1. 즉시 수정
2. 다음 component pass
3. foundation/token 결정 후 수정

## Validation

- 자동 검증:
- 수동 상태 검증:
- 미검증 항목:
```

## Exception record

```markdown
### Design token exception

- 위치:
- 기본 token으로 해결할 수 없는 이유:
- 사용한 값:
- 적용 범위:
- 제거 또는 재검토 조건:
```
