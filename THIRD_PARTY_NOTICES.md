# Third-Party Notices

## msedge-tts 2.0.7

Picky's optional Edge TTS adapter uses [msedge-tts](https://github.com/Migushthe2nd/MsEdgeTTS), copyright Migushthe2nd and contributors.

Licensed under the MIT License. The package's complete license text is distributed with the dependency at `agentd/node_modules/msedge-tts/LICENSE`.

Picky applies `patches/msedge-tts@2.0.7.patch`, a small reliability patch that propagates initial speech-config and synthesis WebSocket send failures to the package's returned Promise or audio stream. This prevents an unhandled Node rejection from terminating the local daemon before Picky can use its macOS Speech fallback.
