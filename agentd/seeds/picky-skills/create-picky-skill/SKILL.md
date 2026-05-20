---
name: create-picky-skill
description: Author a new Picky skill (a short behavior recipe for the realtime main agent) when the user asks to add, create, or define one.
---

# Create a new Picky skill

## When to use

- The user asks Picky to create, add, register, or save a skill / behavior recipe / response pattern, in any language.
- The user wants Picky's main (voice) agent to behave a specific way for a specific kind of request.

## What a Picky skill is

- A single Markdown file with YAML frontmatter and a short body.
- Lives under `~/Library/Application Support/Picky/skills/<name>.md`.
- Read by the realtime main agent via the `picky_skill` tool. The list of names + descriptions is injected once at session start.

## What to do

1. Confirm the trigger and behavior the user wants. Ask one short clarifying question if the trigger is unclear.

2. Pick a kebab-case `<name>` (e.g. `summarize-pr-link`, `escalate-to-pickle`, `prefer-concise-replies`). Filename and frontmatter `name` must match.

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

## What NOT to do

- Picky skills only affect the realtime main (voice) agent. They never run inside a Pickle, and they are unrelated to any other agent's skill system.
- Do not put long step-by-step workflows in the body. If the recipe needs file edits, multi-step research, or more than ~3 tool calls, write a skill that delegates to a Pickle and put the actual procedure inside `picky_start_pickle.instructions`.
- Do not overwrite an existing skill file without the user's explicit confirmation.
- Do not put credentials, API keys, or personal data in a skill (it is stored as plaintext on disk).
