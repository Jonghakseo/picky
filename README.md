# Picky

Picky is a local-first macOS command center for Pi sessions. It keeps the useful macOS shell primitives from the public Clicky foundation—menu bar presence, global push-to-talk, permission handling, screen capture, and overlay windows—while routing captured context toward a local agent client abstraction.

Phase 1 status: the app captures neutral desktop context and submits it to a local stub `PickyAgentClient`. Later phases connect that abstraction to `picky-agentd` and the Pi SDK.

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

- `Picky/CompanionManager.swift` coordinates push-to-talk, screenshot capture, overlay state, and local agent submission.
- `Picky/PickyAgentClient.swift` defines the app-to-agent submission boundary.
- `Picky/PickyContextPacket.swift` defines neutral context packet models and testable assembly protocols.
- `Picky/AppleSpeechTranscriptionProvider.swift` is the default transcription provider.
- `Picky/CompanionScreenCaptureUtility.swift`, `Picky/OverlayWindow.swift`, `Picky/MenuBarPanelManager.swift`, and `Picky/GlobalPushToTalkShortcutMonitor.swift` preserve the macOS primitives needed for future Pi integration.

## Attribution

Picky uses MIT-licensed public Clicky source as a macOS app foundation. See `docs/CLICKY_UPSTREAM.md` and `LICENSE` for provenance and licensing details.
