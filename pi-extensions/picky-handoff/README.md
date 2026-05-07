# Picky Pi handoff extension

This Pi extension adds a slash command that pins the current idle Pi session context to Picky as a completed side-agent card.

Command:

- `/handoff-to-picky [handoff request]`

The command reads Picky's local daemon capability file:

```text
~/Library/Application Support/Picky/agentd-connection.json
```

Picky writes this file when `picky-agentd` starts. It contains the local WebSocket URL and a bearer token, and should be readable only by the current user.

## Install

Packed Picky alpha builds (`scripts/package-signed-app.sh`) auto-install this extension on first launch by symlinking `~/.pi/agent/extensions/picky-handoff` to the bundle copy. If a different file or symlink already lives at that path, Picky leaves it alone and logs a warning.

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

The command is allowed only while Pi is idle. It does not start a new Picky agent run; it creates a completed Picky side-agent card using the current Pi session file, cwd, and recent branch excerpt as context for future follow-up.
