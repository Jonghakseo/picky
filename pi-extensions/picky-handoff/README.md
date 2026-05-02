# Picky Pi handoff extension

This Pi extension adds slash commands that hand the current Pi session context to Picky as a new visible side agent.

Commands:

- `/pin-as-side-agent [handoff request]`
- `/handoff-to-picky [handoff request]`

The command reads Picky's local daemon capability file:

```text
~/Library/Application Support/Picky/agentd-connection.json
```

Picky writes this file when `picky-agentd` starts. It contains the local WebSocket URL and a bearer token, and should be readable only by the current user.

## Install for local development

From the Picky repository root:

```bash
mkdir -p ~/.pi/agent/extensions
ln -sfn "$PWD/pi-extensions/picky-handoff" ~/.pi/agent/extensions/picky-handoff
```

Then restart Pi or run `/reload` in an existing Pi session.

## Usage

```text
/pin-as-side-agent continue this investigation in Picky and produce a final report
```

If no argument is provided, the extension asks Picky to continue the current Pi task as a side agent using the recent Pi session branch excerpt as context.
