---
name: create-picky-skill
description: Author a new Picky skill (a short behavior recipe for the realtime main agent) when the user asks to add, create, or define one.
---

# Create a new Picky skill

## When to use

- The user says things like "Picky 스킬 만들어줘", "이런 상황엔 이렇게 답하게 해줘", "behavior recipe 추가", "스킬로 등록".
- The user wants Picky's main (voice) agent to behave a specific way for a specific kind of request.

## What a Picky skill is

- A single Markdown file with YAML frontmatter and a short body.
- Lives under `~/Library/Application Support/Picky/skills/<name>.md`.
- Read by the realtime main agent via the `picky_skill` tool. The list of names + descriptions is injected once at session start.

## What to do

1. Confirm the trigger and behavior the user wants. Ask one short clarifying question if the trigger is unclear.
2. Pick a kebab-case `<name>` (e.g. `summarize-pr-link`, `prefer-korean-replies`). Filename and frontmatter `name` must match.
3. Draft the body using the template below. Keep it tight — this is a recipe, not a manual.
4. Before writing, if a file with the same name might exist, check with `picky_skill({ action: "get", name })` and confirm with the user before overwriting.
5. Save with `picky_write_file({ path: "~/Library/Application Support/Picky/skills/<name>.md", content, mode: "overwrite" })`.
6. Tell the user:
   
   - The full path of the new file.
   
   - The skill joins the always-on session list **on the next session start** (the in-session list is a snapshot). Within this session they can still read it via `picky_skill({ action: "get", name })`.

## Template

```
---
name: <kebab-case, must match filename>
description: <one sentence; when to invoke and what to do — shown in the session-start list>
---

# <Human-readable title>

## When to use
- Short bullets describing the user's intent or phrases that should trigger this skill.

## What to do
1. Step the realtime agent should follow.
2. Reference Picky tools by name when relevant (`picky_start_pickle`, `picky_steer_pickle`, `picky_recall_recent_context`, `picky_remember`, ...).
3. Keep it under ~30 lines. Long workflows belong inside a Pickle's instructions.

## What NOT to do
- (optional) Known anti-patterns to avoid.
```

## 주의

- Picky 스킬은 Pickle/Pi 스킬과 별개다. Picky 메인(음성) 에이전트에만 적용되고, Pickle은 영향받지 않는다. `~/.pi/agent/skills/` 같은 Pi 경로를 참조하지 말 것.
- 본문에 긴 단계별 워크플로우를 넣지 말 것. 파일 편집·다단계 리서치·3개 이상 도구 호출이 필요하면 "Pickle에 위임"하는 스킬로 작성하고 실제 절차는 `picky_start_pickle.instructions` 안에 넣는다.
- 기존 스킬 파일을 사용자 확인 없이 덮어쓰지 말 것.
- 자격증명·API 키·개인정보를 스킬에 적지 말 것 (디스크에 평문으로 저장됨).
