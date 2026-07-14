# Apple Platform Design References

이 문서는 Picky 디자인 시스템을 검토할 때 우선 확인할 Apple 공식 자료를 모은 인덱스다. `DESIGN-apple.md`의 웹사이트 분석보다 공식 Human Interface Guidelines를 우선한다.

## Core macOS guidance

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
  macOS의 입력 방식, windowing, 메뉴, keyboard 중심 사용 패턴을 이해하는 출발점.

- [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
  콘텐츠 위계, safe area, 플랫폼별 layout 적응 원칙.

- [Windows](https://developer.apple.com/design/human-interface-guidelines/windows)
  window와 panel의 역할, chrome, resizing, restoration 관련 기준.

- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
  상단/하단 control grouping과 toolbar 동작 기준.

- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
  navigation과 content layer 분리 기준.

## Visual foundations

- [Color](https://developer.apple.com/design/human-interface-guidelines/color)
  accent, semantic color, appearance 적응, 색상 사용 원칙.

- [Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)
  semantic color와 asset이 appearance에 적응하는 방식.

- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
  전경과 배경을 기능적으로 분리하는 material 사용 원칙.

- [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
  시스템 폰트, 위계, 가독성, Dynamic Type 관련 원칙.

- [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
  시스템 심볼의 weight, scale, alignment, 접근성 기준.

- [Apple Design Resources](https://developer.apple.com/design/resources/)
  SF Pro, SF Mono와 공식 디자인 리소스.

## Controls and interaction

- [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)
  system button이 제공하는 상태, 접근성, appearance 적응과 계층 기준.

- [Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields)
  입력, focus, placeholder, validation 관련 기준.

- [Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
  macOS menu와 context action 구성 원칙.

- [Drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop)
  session tile과 attachment drag/drop 피드백 기준.

- [Loading](https://developer.apple.com/design/human-interface-guidelines/loading)
  진행 상태, 기다림, progress feedback 원칙.

## Accessibility

- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
  포괄적인 접근성 설계 원칙.

- [Sufficient Contrast](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/sufficient-contrast-evaluation-criteria)
  텍스트와 아이콘 대비 검수 기준.

## Picky usage rules

1. 시스템 control이 Picky의 상태 모델을 충분히 표현하면 시스템 동작을 우선한다.
2. custom control은 hover만 아니라 keyboard focus, accessibility, appearance 상태까지 정의한다.
3. material은 floating layer를 설명할 때만 사용한다.
4. semantic color와 system font를 우선하고 raw value는 token 정의에 한정한다.
5. 웹사이트 레퍼런스와 HIG가 충돌하면 HIG를 따른다.
