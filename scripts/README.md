# Picky Release / Package Scripts

## `run-dev-signed-app.sh` — stable permission-friendly dev relaunch

Builds a Debug `Picky.app` into a stable path, signs it with a real local Apple code-signing identity, quits any running Picky, then launches the packaged app:

```bash
./scripts/run-dev-signed-app.sh
```

This is the preferred way to relaunch Picky while debugging voice/screen permissions. Avoid launching the ad-hoc DerivedData app directly because macOS may treat each rebuild as a different app and ask for Microphone / Accessibility / Screen Recording permissions again.

The script auto-selects an `Apple Development` identity when available. If needed, pass one explicitly:

```bash
PICKY_CODE_SIGN_IDENTITY="Apple Development: Example (TEAMID)" \
PICKY_DEVELOPMENT_TEAM="TEAMID" \
./scripts/run-dev-signed-app.sh
```

Defaults:

- configuration: `Debug`
- output app: `build/dev-signed/export/Picky.app`
- zip creation: disabled
- clean build: disabled, for faster repeated relaunches

## `package-agentd-runtime.sh` — bundled daemon runtime

Builds `agentd` into a production runtime directory suitable for copying into `Picky.app/Contents/Resources/agentd`:

```bash
./scripts/package-agentd-runtime.sh
```

The runtime launches with `node dist/index.js`. It includes production `node_modules`, but excludes the launch-time need for `pnpm`, `tsx`, TypeScript, or the `agentd/src` tree. `node` itself is intentionally **not** bundled; beta users are expected to have Node via Pi.

Default output:

```text
build/package/agentd-runtime
```

## `package-signed-app.sh` — local signed package smoke

Builds `Picky.app`, embeds the bundled `agentd` runtime, re-signs the final bundle, and verifies the result with:

```bash
codesign --verify --deep --strict --verbose=2
```

This keeps the Xcode project defaults unchanged (`CODE_SIGNING_ALLOWED=NO` for fast normal build/test), so package signing does **not** slow down the regular Swift test workflow.

### Local ad-hoc package

```bash
./scripts/package-signed-app.sh
```

Defaults:

- scheme: `Picky`
- configuration: `Release`
- signing identity: `-` (`Sign to Run Locally` / ad-hoc)
- output app: `build/package/export/Picky.app`
- output zip: `build/package/Picky-<version>-alpha.<build>-<sha>-<timestamp>.zip`

### Developer ID package

```bash
PICKY_CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
PICKY_DEVELOPMENT_TEAM="TEAMID" \
./scripts/package-signed-app.sh
```

### Useful environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `PICKY_CONFIGURATION` | `Release` | Xcode configuration to build. |
| `PICKY_CODE_SIGN_IDENTITY` | `-` | Signing identity. Use Developer ID for distribution. |
| `PICKY_DEVELOPMENT_TEAM` | empty | Apple team id, required for some identities. |
| `PICKY_PACKAGE_BUILD_DIR` | `build/package` | Package build output root. |
| `PICKY_MARKETING_VERSION` | Xcode `MARKETING_VERSION` | Override `CFBundleShortVersionString`. |
| `PICKY_BUILD_NUMBER` | git commit count | Override `CFBundleVersion`. |
| `PICKY_RELEASE_CHANNEL` | `alpha` | Build channel used in labels/zip names. |
| `PICKY_BUILD_LABEL` | `<channel>.<build>-<sha>-<timestamp>` | Human-readable build label. |
| `PICKY_ZIP_PATH` | versioned zip under `build/package` | Exact zip output path. |
| `PICKY_CREATE_ZIP` | `1` | Set `0` to skip zip creation. |
| `PICKY_PACKAGE_AGENTD` | `1` | Set `0` to skip embedding `Contents/Resources/agentd`. |
| `PICKY_AGENTD_RUNTIME_DIR` | `build/package/agentd-runtime` | Prebuilt/staging agentd runtime directory. |
| `PICKY_CLEAN` | `1` | Set `0` to reuse package DerivedData. |

Each package writes `PickyBuildInfo.json` into app resources with version, build number, channel, git sha, timestamp, and build label. The final app is re-signed after writing this metadata.

### Runtime resolution

At app launch Picky resolves the daemon in this order:

1. `PICKY_AGENTD_ROOT` if set. Source overrides with `src/index.ts` run via `pnpm exec tsx`; compiled overrides with `dist/index.js` run via `node`.
2. Bundled `Picky.app/Contents/Resources/agentd/dist/index.js`, run via `node`.
3. Friendly startup failure. There is no implicit source-tree fallback.

### Runtime smoke

After packaging, run the signed app against the bundled daemon in mock mode:

```bash
env PICKY_AGENTD_RUNTIME=mock build/package/export/Picky.app/Contents/MacOS/Picky
```

Expected daemon log:

```text
picky-agentd listening on 127.0.0.1:17631
```

## `release.sh`

Currently delegates to `package-signed-app.sh`.

A notarized DMG/appcast/GitHub release pipeline is intentionally **not** configured yet. Add that later as a separate explicit distribution workflow once Developer ID, notarization credentials, update strategy, and release repository are finalized.
