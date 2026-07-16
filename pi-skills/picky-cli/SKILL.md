---
name: picky-cli
description: Use the Picky CLI only when the user explicitly asks to control Picky.app, create or steer Pickles, submit to the main Picky session, or operate Picky push-to-talk.
---

# Picky CLI

Use this skill only when the user explicitly asks to control Picky.app from Pi or asks for a Picky CLI workflow.

The `picky` CLI is Picky.app's local programmatic interface. It can submit text to the main Picky session, create and manage Pickle sessions in the Picky dock, and control Picky push-to-talk.

## First checks

1. Check whether the CLI is available:

   ```bash
   command -v picky
   ```

2. If `picky` is missing, tell the user to reinstall the Picky CLI from the Picky app menu/settings, then try again.

3. If `picky` is available, inspect the current command surface before choosing arguments:

   ```bash
   picky --help
   picky <command> --help
   ```

## Main commands

- `picky submit <text>` sends text to the main Picky session. By default, Picky.app captures live desktop context.

  - Use `--no-context` when the user explicitly wants a context-free message.
  - Use `--cwd <path>` when the request should be tied to a specific workspace.
  - Use `--wait` when you need the main session's reply in stdout.

- `picky pickle-create [title] --instructions <text>` creates a new Pickle session shown in the Picky dock.

  - Use this when the user says things like "open a Pi session", "create a Pickle", "run this in a separate Picky session", or "delegate this to a separate session".
  - Use `--cwd <path>` to bind the Pickle to a workspace.
  - Use `--no-context` only when live app-side context should be skipped.
  - Use `--wait` only when the caller needs the final Pickle answer before continuing.
  - Use `--group <name>` to assign the Pickle to a dock group.
  - Use `picky pickle-create --empty` only when the user asks for a blank Pickle.

- `picky pickle-list` lists Pickle sessions currently shown in the Picky dock.

  - Prefer `--json` when you need to inspect session IDs programmatically.
  - Use `--include-archived` or `--archived` only when archived Pickles are relevant.
  - Use `--query <text>` to filter sessions by their searchable fields.

- `picky pickle-archive <session-id>` hides a Pickle from the dock; `picky pickle-unarchive <session-id>` restores it within the retention window.

- `picky pickle-group-list` lists dock groups. Prefer `--json` for programmatic use.

- `picky pickle-followup <session-id> <text>` sends a follow-up to an existing Pickle.

- `picky pickle-abort <session-id>` aborts an in-flight Pickle.

- `picky ptt press` starts Picky push-to-talk.

- `picky ptt release` ends Picky push-to-talk.

## Safety rules

- Do not steer the current session by accident. Before sending `pickle-followup` or `pickle-abort`, inspect `picky pickle-list --json` and make sure the target session is the user's intended Pickle.
- Be especially careful with `picky submit`: it sends text to the main Picky session. If you are already acting inside the main Picky agent, this may cause self-steering or duplicated work.
- Push-to-talk is stateful. Every `picky ptt press` must be paired with a `picky ptt release` unless the user explicitly asks to keep PTT held.
- Prefer explicit text and explicit session IDs. Do not guess which Pickle to control when multiple sessions match; ask the user or show the candidates.
- Do not use this CLI for ordinary shell/file tasks. Use it only for Picky.app control or Picky session orchestration.
