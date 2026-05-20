---
name: create-picky-skill
description: Author a new Picky skill (a short behavior recipe for the realtime main agent) when the user asks to add, create, or define one.
---

# Create a new Picky skill

## When to use
- The user says things like "Picky 스킬 만들어줘", "이런 상황엔 이렇게 답하게 해줘", "behavior recipe 추가", "스킬로 등록".
- The user wants Picky's main (voice) agent to behave a specific way when a specific kind of request shows up.

## What a Picky skill is
- A single Markdown file with YAML frontmatter and a short body.
- Lives under `~/Library/Application Support/Picky/skills/<name>.md`.
- Read by the realtime main agent via the `picky_skill` tool. The list of names + descriptions is also injected once at the start of every realtime session.
- Picky skills are NOT the same as Pi skills. They only affect Picky's main (voice) agent, never Pickle. Do not reference `~/.pi/agent/skills/` here.

## What to do
1. Confirm with the user what trigger and behavior they want. Ask one short clarifying question if the trigger is unclear.
2. Pick a kebab-case `<name>` (e.g. `summarize-pr-link`, `prefer-korean-replies`). The filename and the frontmatter `name` must match.
3. Draft the body using the template below. Keep it tight — this is a recipe, not a manual.
4. Save the file with `picky_write_file({ path: "~/Library/Application Support/Picky/skills/<name>.md", content, mode: "overwrite" })`. Confirm with the user before overwriting an existing file (use `picky_skill({ action: "get", name })` first if unsure).
5. Tell the user:
   - The full path of the new file.
   - That the new skill becomes part of the always-on session list **on the next session start** (the in-session list is a snapshot). Inside this session they can still use `picky_skill({ action: "get", name })` to read it.

## Template
```
---
name: <kebab-case, must match filename>
description: <one sentence; when to invoke and what to do — this is shown in the session-start list>
---

# <Human-readable title>

## When to use
- Short bullets describing the user's intent or phrases that should trigger this skill.

## What to do
1. Step the realtime agent should follow.
2. Reference Picky tools by name when relevant (`picky_start_pickle`, `picky_steer_pickle`, `picky_recall_recent_context`, `picky_remember`, ...).
3. Keep it under ~30 lines. Long workflows belong inside a Pickle's instructions, not in a main skill.

## What NOT to do
- (optional) Known anti-patterns to avoid.
```

## What NOT to do
- Do not put long step-by-step Pickle workflows here. If the recipe needs file edits, multi-step research, or 3+ tool calls, write the skill as "delegate to a Pickle with these instructions" and put the workflow inside `picky_start_pickle.instructions`.
- Do not reference Pi skills, `~/.pi/agent/skills/`, or Pi extensions. Picky skills are independent.
- Do not silently overwrite an existing skill file. Always confirm with the user first.
- Do not seed credentials, API keys, or personal data into a skill file. Skills are plain text on disk.
