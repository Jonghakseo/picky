# Picky Pi handoff extension

This Pi extension adds a slash command that interrupts the current Pi session and hands the work off to Picky as a brand-new Pickle that auto-runs from a kickoff message.

Command:

- `/handoff-to-picky [kickoff instruction]`

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

If the current Pi turn is still streaming, the command first calls `ctx.abort()` and waits for the turn to settle. It then creates a new visible Pickle session in Picky, seeds it with the current Pi session file, cwd, and recent branch excerpt as context, and sends the kickoff instruction as the first user message so the Pickle resumes the work automatically. When you omit the kickoff text, the default instruction is `continue`.
