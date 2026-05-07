# Alpha Test Build Guide

This guide is for **trusted internal Apple Silicon testers**. It intentionally uses the local/ad-hoc signed package path and does **not** notarize the app.

For external distribution, use Developer ID signing + notarization instead. Apple documents notarization as the expected path for macOS software distributed outside the App Store: <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>.

## Scope

Use this flow when all of the following are true:

- The tester is an internal/trusted colleague.
- The tester uses Apple Silicon macOS.
- The tester already has Pi/Node installed.
- The tester is willing to remove the downloaded quarantine attribute manually.

Do **not** use this flow for public/external beta distribution.

## Build

From a clean worktree:

```bash
git status --short
./scripts/package-signed-app.sh
```

The script produces a versioned zip:

```text
build/package/Picky-<version>-alpha.<build>-<git-sha>-<timestamp>.zip
```

It also embeds build metadata in:

```text
Picky.app/Contents/Resources/PickyBuildInfo.json
```

The default version metadata is:

- `MARKETING_VERSION`: Xcode `MARKETING_VERSION`, currently `1.0`
- `CFBundleVersion`: git commit count
- `releaseChannel`: `alpha`
- `buildLabel`: `<channel>.<build>-<sha>-<timestamp>`

Override when needed:

```bash
PICKY_MARKETING_VERSION=1.0 \
PICKY_BUILD_NUMBER=431 \
PICKY_RELEASE_CHANNEL=alpha \
./scripts/package-signed-app.sh
```

## Verify before sharing

```bash
ZIP="$(ls -t build/package/Picky-*-alpha.*.zip | head -1)"
echo "$ZIP"

/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/package/export/Picky.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/package/export/Picky.app/Contents/Info.plist
cat build/package/export/Picky.app/Contents/Resources/PickyBuildInfo.json

lipo -info build/package/export/Picky.app/Contents/MacOS/Picky
/usr/bin/codesign --verify --deep --strict --verbose=2 build/package/export/Picky.app
```

Expected for this internal alpha flow:

- `codesign --verify` passes.
- `lipo -info` reports `arm64` for Apple Silicon.
- `spctl -a` may still reject the app because the package is not notarized. That is expected for this flow.

## Share with tester

Send the generated zip, not the raw app bundle.

Tester steps:

```bash
# 1. Unzip and move Picky.app to /Applications.
# 2. Remove the downloaded quarantine attribute.
xattr -dr com.apple.quarantine /Applications/Picky.app

# 3. Launch.
open /Applications/Picky.app
```

The quarantine workaround is only for trusted internal builds. It bypasses the downloaded-file quarantine prompt path for this local/ad-hoc package.

## Tester prerequisites

- Apple Silicon Mac
- Pi installed, including a working `node` executable in normal shell PATH
- macOS permissions granted when prompted:
  - Accessibility
  - Screen Recording
  - Microphone
  - Speech Recognition if using local speech recognition

If the app launches but the daemon does not start, check:

```bash
node --version
ls -la ~/Library/Application\ Support/Picky/Logs/
tail -200 ~/Library/Application\ Support/Picky/Logs/agentd.stderr.log
```

## Runtime behavior

The packaged app resolves `picky-agentd` in this order:

1. `PICKY_AGENTD_ROOT`, when explicitly set.
2. Bundled `Picky.app/Contents/Resources/agentd/dist/index.js`.
3. Friendly startup failure.

The bundled daemon runs with:

```bash
node Picky.app/Contents/Resources/agentd/dist/index.js
```

So testers do not need `pnpm`, `tsx`, TypeScript, or the source tree at launch time.

## When to switch to proper beta distribution

Switch to Developer ID signing + notarization when:

- The tester is outside the trusted internal group.
- You want the app to open without quarantine removal.
- You need a public download link.
- You want to avoid Gatekeeper rejection.

References:

- Apple notarization: <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
- Apple distributing apps outside the Mac App Store: <https://developer.apple.com/developer-id/>
- Apple universal binary guidance: <https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary>
