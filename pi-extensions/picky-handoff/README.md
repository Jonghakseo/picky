# Picky Pi handoff extension

This Pi extension adds a slash command that hands the current Pi session context off to Picky. The behavior depends on whether Pi is idle:

- **Idle**: pins a completed Pickle card in the Picky dock using the current session as neutral context. No new Pickle run is started.
- **Busy (mid-turn)**: calls `ctx.abort()`, waits for the turn to settle, then creates a brand-new visible Pickle that auto-runs from a kickoff message so the work continues in Picky.

Command:

- `/handoff-to-picky [text]` — when idle, `text` is recorded as the handoff request on the pinned card; when busy, `text` is sent as the kickoff instruction (defaults to `continue` if omitted).

The command reads Picky's local daemon capability file:

```text
~/Library/Application Support/Picky/agentd-connection.json
```

Picky writes this file when `picky-agentd` starts. It contains the local WebSocket URL and a bearer token, and should be readable only by the current user.

## Install

Packed Picky builds include this extension but do not install it automatically on launch. Install it from Picky's Extensions/Status UI when you want the `/handoff-to-picky` command. The installer copies the bundled extension into `~/.pi/agent/extensions/picky-handoff` and writes `.picky-extension-install.json` metadata so Picky can detect managed installs, updates, and conflicts. If an unrelated file or symlink already lives at that path, Picky leaves it alone and reports a conflict instead of overwriting it.

For local development against the source tree:

```bash
mkdir -p ~/.pi/agent/extensions
ln -sfn "$PWD/pi-extensions/picky-handoff" ~/.pi/agent/extensions/picky-handoff
```

Then restart Pi or run `/reload` in an existing Pi session.

## Usage

```text
/handoff-to-picky continue this investigation in Picky and produce a final report
```

Both branches seed the new Pickle with the current Pi session file, cwd, and recent branch excerpt. The busy branch additionally sends the kickoff instruction as the first user message of the new Pickle so it resumes the work without further input; omitting the argument defaults the kickoff to `continue`.
