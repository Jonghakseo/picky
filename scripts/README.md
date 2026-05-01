# Picky Release / Package Scripts

## `package-signed-app.sh` — local signed package smoke

Builds `Picky.app` with command-line signing overrides and verifies the result with:

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
- output zip: `build/package/Picky-Release-signed.zip`

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
| `PICKY_CREATE_ZIP` | `1` | Set `0` to skip zip creation. |
| `PICKY_CLEAN` | `1` | Set `0` to reuse package DerivedData. |

### Runtime smoke

After packaging, run the signed app against the local daemon source in mock mode:

```bash
PICKY_AGENTD_RUNTIME=mock \
PICKY_AGENTD_ROOT="$PWD/agentd" \
build/package/export/Picky.app/Contents/MacOS/Picky
```

Expected daemon log:

```text
picky-agentd listening on 127.0.0.1:17631
```

## `release.sh`

Currently delegates to `package-signed-app.sh`.

A notarized DMG/appcast/GitHub release pipeline is intentionally **not** configured yet. Add that later as a separate explicit distribution workflow once Developer ID, notarization credentials, update strategy, and release repository are finalized.
