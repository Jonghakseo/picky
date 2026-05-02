# Picky

Picky is a local-first macOS command center for Pi sessions. It keeps the useful macOS shell primitives from the public Clicky foundation—menu bar presence, global push-to-talk, permission handling, screen capture, and overlay windows—while routing captured context to a local `picky-agentd` daemon backed by the Pi SDK.

Current status: the app captures neutral desktop context, launches/connects to `picky-agentd` over a local WebSocket protocol, supervises long-running Pi sessions, and shows session state through the top-right HUD. A mock daemon runtime remains available for local UI development and tests.

## Requirements

- macOS 14.2+
- Xcode 15+

## Build and test

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' build
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test
```

## Permissions

Picky asks for the local macOS permissions needed by its shell:

- Microphone — push-to-talk voice capture
- Speech Recognition — Apple Speech transcription
- Accessibility — global Control+Option shortcut
- Screen Recording / Screen Content — screenshots for neutral context packets

## Architecture snapshot

- `Picky/` contains the macOS app shell. Current modules group app/menu bar code, settings, context capture, companion voice/dictation UI, overlay windows, HUD/session UI, and session selection/archive helpers.
- `Picky/PickyAgentProtocol.swift`, `Picky/PickyAgentClient.swift`, and `Picky/PickyAgentDaemonLauncher.swift` define and launch the app-to-daemon boundary.
- `Picky/Context/` and `Picky/PickyAdvancedContext.swift` build neutral context packets: transcript, app/window metadata, browser URL/title/selection, screenshots, cwd, and selected session.
- `Picky/HUD/` plus `Picky/PickySessionViewModel.swift` render and manage long-running session cards, follow-ups, archive/search, artifacts, and Ghostty resume.
- `agentd/` is the TypeScript daemon. It owns WebSocket transport, session supervision, Pi SDK/runtime adapters, event normalization, extension UI bridging, session metadata, and artifacts.
- `pi-extensions/picky-handoff/` contains the optional Pi slash-command bridge for handing an existing Pi conversation off to a new Picky side agent.
- Picky does not hard-code Sentry/Slack/DB routing. It passes context; Pi skills/extensions decide the workflow.

## Optional Pi handoff command

Picky writes a local capability file for Pi extensions while `picky-agentd` is running:

```text
~/Library/Application Support/Picky/agentd-connection.json
```

To enable handoff commands in Pi during local development:

```bash
mkdir -p ~/.pi/agent/extensions
ln -sfn "$PWD/pi-extensions/picky-handoff" ~/.pi/agent/extensions/picky-handoff
```

After restarting Pi or running `/reload`, use:

```text
/handoff-to-picky continue this investigation in Picky and produce a final report
```

This creates a new Picky-managed side agent using the current Pi session file, cwd, and recent branch excerpt as neutral context.

## Attribution

Picky uses MIT-licensed public Clicky source as a macOS app foundation. See `docs/CLICKY_UPSTREAM.md` and `LICENSE` for provenance and licensing details.
