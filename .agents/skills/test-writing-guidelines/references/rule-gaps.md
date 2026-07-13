# Picky 테스트 Rule Gap 처리

스킬은 저장소에 없는 규칙을 팀 합의처럼 발명하지 않는다.

## Rule gap으로 표시할 상황

- 대상 영역에 가까운 테스트나 원본 문서가 없다.
- 문서와 실제 테스트 패턴이 다르다.
- 같은 영역에 actor isolation, fake, timeout, serialization 패턴이 갈린다.
- 기존 테스트가 실제 사용자 환경, 긴 sleep, 과한 mock, implementation detail에 의존한다.
- UI/E2E가 필요하지만 permission, initial state, cleanup, stable oracle이 없다.
- package/runtime smoke의 범위나 실행 안전성이 불명확하다.
- protocol field의 backward compatibility 정책이 명시되지 않았다.

## 처리 순서

1. `AGENTS.md`와 관련 원본 문서를 읽는다.
2. 같은 구현 경계의 테스트를 찾는다.
3. 신뢰도를 High/Medium/Low로 표시한다.
4. 일반적인 fallback을 쓰더라도 Picky 확정 규칙이 아니라 임시 추천이라고 밝힌다.
5. 계층, mock 경계, 실제 환경 사용 여부처럼 결정 가능한 질문을 `ask_user_question`으로 묻는다.
6. 반복되는 gap은 소유권이 있는 원본 문서의 보강 후보로 남긴다.

## Test Plan Card 형식

```markdown
- rule gap / 확인 질문:
  - Gap:
  - 기존 근거 신뢰도: High / Medium / Low
  - 임시 추천:
  - 확인 질문:
  - 문서화 후보:
```

## 안전한 fallback

근거가 약해도 다음은 기본 안전선으로 사용할 수 있다.

- 실제 사용자 홈과 실행 중인 앱 대신 temporary/injected root를 사용한다.
- core policy/SUT는 실제 구현으로 두고 외부 경계만 fake로 만든다.
- 고정 sleep보다 controlled event/continuation과 bounded timeout을 사용한다.
- UI hierarchy보다 observable projection을 검증한다.
- protocol 변경은 양쪽 언어와 fixture를 함께 검증한다.
- signed package, 앱 재실행, 실제 권한/자격 증명이 필요하면 사용자에게 먼저 확인한다.

## 금지

- Low 신뢰도 패턴을 일관성만을 이유로 복제하지 않는다.
- 실제 앱이나 사용자 데이터를 건드리는 테스트를 암묵적으로 실행하지 않는다.
- E2E가 없다는 이유로 기능 테스트를 E2E 증거처럼 과장하지 않는다.
- protocol compatibility 결정을 질문 없이 추정하지 않는다.
