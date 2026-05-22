# Alpha Test Build Guide

This guide is for **trusted internal Apple Silicon testers**. It intentionally uses the local/ad-hoc signed package path and does **not** notarize the app.

For external distribution, use Developer ID signing + notarization instead. Apple documents notarization as the expected path for macOS software distributed outside the App Store: <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>.

## Scope

Use this flow when all of the following are true:

- The tester is an internal/trusted colleague.
- The tester uses Apple Silicon macOS.
- The tester already has Pi installed (Node is bundled with the app).
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
- Pi installed (no system-wide `node` required — the app ships a pinned Node 22.x arm64 binary under `Contents/Resources/agentd-runtime/bin/node`)
- macOS permissions granted when prompted:
  - Accessibility
  - Screen Recording
  - Microphone
  - Speech Recognition if using local speech recognition

If the app launches but the daemon does not start, check:

```bash
ls -la ~/Library/Application\ Support/Picky/Logs/
cat ~/Library/Application\ Support/Picky/Logs/agentd.node-preflight.json
tail -200 ~/Library/Application\ Support/Picky/Logs/agentd.stderr.log
```

`agentd.node-preflight.json` records `nodeSource` (`override` / `bundled` / `external`), `nodePath`, and `status` so you can tell which Node the launcher tried to use.

## Runtime behavior

The packaged app resolves `picky-agentd` in this order:

1. `PICKY_AGENTD_ROOT`, when explicitly set.
2. Bundled `Picky.app/Contents/Resources/agentd/dist/index.js`.
3. Friendly startup failure.

For the Node executable the launcher uses (in priority order):

1. `PICKY_NODE_PATH` env var, when set to an executable Node 22.x binary (dev/debug override).
2. Bundled `Picky.app/Contents/Resources/agentd-runtime/bin/node` (Node 22.x arm64, pinned via `agentd/package.json#engines.node`).
3. `/usr/bin/env node` from the inherited PATH (dev builds or `PICKY_SKIP_NODE_BUNDLE=1` packages).

The bundled Node is signed separately with `Picky/NodeRuntime.entitlements` so V8 JIT works under hardened runtime; the main app entitlements are unchanged.

So testers do not need `pnpm`, `tsx`, TypeScript, the source tree, **or a system `node`** at launch time.

## Packager-only knobs

- `PICKY_NODE_VERSION` — override the Node version fetched by `scripts/fetch-node-runtime.sh` (defaults to `agentd/package.json#engines.node`, currently `22.19.0`).
- `PICKY_SKIP_NODE_BUNDLE=1` — package without bundling Node (tester must provide a system Node). Used for niche CI/dev scenarios only.

## When to switch to proper beta distribution

Switch to Developer ID signing + notarization when:

- The tester is outside the trusted internal group.
- You want the app to open without quarantine removal.
- You need a public download link.
- You want to avoid Gatekeeper rejection.

Follow the beta distribution flow in [`docs/beta-test-build.md`](./beta-test-build.md).

References:

- Apple notarization: <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
- Apple distributing apps outside the Mac App Store: <https://developer.apple.com/developer-id/>
- Apple universal binary guidance: <https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary>
