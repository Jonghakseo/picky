# Beta Test Build Guide

This guide is for **Developer ID-signed, notarized macOS beta builds** that can be shared with external or less-trusted testers without asking them to remove quarantine attributes manually.

Use this when the alpha flow in [`docs/alpha-test-build.md`](./alpha-test-build.md) is no longer enough. Apple documents Developer ID + notarization as the expected path for distributing macOS software outside the Mac App Store: <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>.

## Scope

Use this flow when all of the following are true:

- The tester should be able to open the app through Gatekeeper normally.
- The app is distributed outside the Mac App Store.
- You have access to a **Developer ID Application** certificate.
- You have a working `notarytool` credential profile.
- The build is intended for beta distribution, not local-only smoke testing.

Do **not** use this flow for App Store/TestFlight distribution. This project currently prepares a signed/notarized zip, not an appcast, DMG, or automatic-update release.

## GitHub Actions release automation

The repo includes `.github/workflows/beta-notarized-release.yml` for CI-based beta distribution. It runs the same core flow as this guide on a macOS runner:

1. import the Developer ID `.p12` certificate into a temporary keychain,
2. run `./scripts/package-signed-app.sh` with `PICKY_RELEASE_CHANNEL=beta`,
3. re-sign nested native Node add-ons and the final app with secure timestamps,
4. submit the upload zip to Apple Notary service with `notarytool --wait`,
5. staple and validate the app,
6. create the final `*-notarized.zip`,
7. upload the zip to the GitHub Release, and
8. insert/update a release-note block between `<!-- picky-notarized-build:start -->` and `<!-- picky-notarized-build:end -->`.

Supported triggers:

- **Manual:** Actions → **Build notarized beta release** → Run workflow → provide an existing `tag_name`.
- **Release publish:** publishing a GitHub Release automatically builds the release tag and attaches the notarized zip.

The workflow uses `macos-15` by default. If an Apple Silicon runner is required, set repository variable `PICKY_MACOS_RUNNER` to the runner label available to the repository, for example `macos-15-xlarge`. GitHub documents runner labels and custom runner selection here: <https://docs.github.com/actions/using-jobs/choosing-the-runner-for-a-job>.

### Required GitHub Actions secrets

Add these under GitHub repository **Settings → Secrets and variables → Actions → Repository secrets**. GitHub's encrypted secrets documentation is here: <https://docs.github.com/actions/security-guides/using-secrets-in-github-actions>.

| Secret | Example / value source |
| --- | --- |
| `PICKY_DEVELOPER_ID_CERT_BASE64` | Base64-encoded `.p12` export of the Developer ID Application certificate and private key. |
| `PICKY_DEVELOPER_ID_CERT_PASSWORD` | Password used when exporting the `.p12`. |
| `PICKY_CODE_SIGN_IDENTITY` | `Developer ID Application: Dasom Min (84KNP3KS9U)` |
| `PICKY_DEVELOPMENT_TEAM` | `84KNP3KS9U` |
| `PICKY_NOTARY_APPLE_ID` | Apple ID email used for notarization. |
| `PICKY_NOTARY_APP_PASSWORD` | App-specific password for that Apple ID. |

Create the base64 certificate secret from a local `.p12` file:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Then paste the clipboard into `PICKY_DEVELOPER_ID_CERT_BASE64`. Do not commit the `.p12` file or the decoded certificate. Apple documents Developer ID distribution and notarization as the path for distributing outside the Mac App Store: <https://developer.apple.com/developer-id/> and <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>.

### Manual workflow run

Before running CI, create and push a tag:

```bash
git tag picky-beta-YYYYMMDD
git push origin picky-beta-YYYYMMDD
```

Run the workflow with:

```text
tag_name: picky-beta-YYYYMMDD
release_channel: beta
create_release_if_missing: true
prerelease: true
```

The workflow creates the GitHub Release if missing, uploads the final `Picky-<version>-beta.<build>-<sha>-<timestamp>-notarized.zip`, and appends the SHA256/notary metadata to the release notes. GitHub's release automation APIs are documented here: <https://docs.github.com/rest/releases/releases>.

## Required local credentials

Check the Developer ID signing identity:

```bash
security find-identity -v -p codesigning | grep 'Developer ID Application'
```

Expected local identity for the current beta flow:

```text
Developer ID Application: Dasom Min (84KNP3KS9U)
```

Check the notary profile:

```bash
xcrun notarytool history \
  --keychain-profile picky-notary \
  --output-format json \
  --no-progress
```

If the profile is missing, create/store credentials first. See Apple's `notarytool` documentation: <https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow>.

## Build

Start from the Picky repository. Confirm the worktree before building so unrelated local changes are intentional:

```bash
git status --short --branch
```

Build a Developer ID-signed Release package without changing Xcode project defaults:

```bash
PICKY_CODE_SIGN_IDENTITY="Developer ID Application: Dasom Min (84KNP3KS9U)" \
PICKY_DEVELOPMENT_TEAM="84KNP3KS9U" \
./scripts/package-signed-app.sh
```

The script writes:

```text
build/package/export/Picky.app
build/package/Picky-<version>-alpha.<build>-<git-sha>-<timestamp>.zip
```

It also embeds build metadata in:

```text
build/package/export/Picky.app/Contents/Resources/PickyBuildInfo.json
```

The package script signs the app bundle, but the current beta notarization path still does a final explicit re-sign before submitting because notarization validates nested native Node add-ons and release entitlements strictly.

## Re-sign for notarization

Apple notarization rejects archives with debug entitlements such as `com.apple.security.get-task-allow`, unsigned nested binaries, invalid Developer ID signatures, or missing secure timestamps. See Apple's common issue guide: <https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/resolving_common_notarization_issues>.

Run this after `package-signed-app.sh`:

```bash
APP="$PWD/build/package/export/Picky.app"
IDENTITY="Developer ID Application: Dasom Min (84KNP3KS9U)"

# Sign native Node add-ons bundled under agentd.
while IFS= read -r -d '' file; do
  if /usr/bin/file "$file" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/codesign \
      --force \
      --options runtime \
      --timestamp \
      --sign "$IDENTITY" \
      "$file"
  fi
done < <(/usr/bin/find "$APP/Contents/Resources/agentd" -type f -print0)

# Re-sign the final app with the checked-in release entitlements.
/usr/bin/codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp \
  --entitlements Picky/Picky.entitlements \
  --sign "$IDENTITY" \
  "$APP"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/codesign -d --entitlements :- "$APP" 2>/dev/null | /usr/bin/plutil -p -
```

Confirm the printed entitlements do **not** include:

```text
com.apple.security.get-task-allow
```

## Create notarization upload zip

Create a fresh zip after the final re-sign:

```bash
UPLOAD_ZIP="$PWD/build/package/Picky-beta-notary-upload.zip"
rm -f "$UPLOAD_ZIP"
(
  cd build/package/export
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent Picky.app "$UPLOAD_ZIP"
)
```

Do not submit a raw `.app` bundle. Submit a zip, DMG, or pkg container. Apple documents supported notarization upload formats in the notarization workflow guide: <https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow>.

## Submit to Apple Notary service

```bash
xcrun notarytool submit "$UPLOAD_ZIP" \
  --keychain-profile picky-notary \
  --wait
```

Save the submission ID printed by `notarytool`. If the result is `Invalid`, inspect the log:

```bash
SUBMISSION_ID="<submission-id>"
xcrun notarytool log "$SUBMISSION_ID" \
  --keychain-profile picky-notary \
  --output-format json > "build/package/notary-log-$SUBMISSION_ID.json"
```

Common Picky-specific failures:

- `The executable requests the com.apple.security.get-task-allow entitlement.`
  - Re-run the final app re-sign with `Picky/Picky.entitlements`.
- `The binary is not signed` for `*.node` files under `Contents/Resources/agentd/node_modules`.
  - Re-run the nested Mach-O signing loop.
- `The signature does not include a secure timestamp.`
  - Ensure the re-sign commands include `--timestamp` and are not using ad-hoc signing.

## Staple and validate

After `notarytool submit --wait` returns `Accepted`, staple the ticket to the app and validate it:

```bash
APP="$PWD/build/package/export/Picky.app"

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/sbin/spctl -a -vvv --type execute "$APP"
/usr/bin/lipo -info "$APP/Contents/MacOS/Picky"
cat "$APP/Contents/Resources/PickyBuildInfo.json"
```

Expected results:

- `stapler validate` prints `The validate action worked!`
- `spctl` prints `accepted` and `source=Notarized Developer ID`
- `lipo` reports `arm64` for the current Apple Silicon beta build

## Create final distribution zip

Create the zip **after stapling**. This is the file to share with testers:

```bash
read MARKETING_VERSION BUILD_LABEL < <(python3 - <<'PY'
import json
from pathlib import Path
info = json.loads(Path('build/package/export/Picky.app/Contents/Resources/PickyBuildInfo.json').read_text())
print(info['marketingVersion'], info['buildLabel'])
PY
)
FINAL_ZIP="$PWD/build/package/Picky-${MARKETING_VERSION}-${BUILD_LABEL}-notarized.zip"

rm -f "$FINAL_ZIP"
(
  cd build/package/export
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent Picky.app "$FINAL_ZIP"
)

shasum -a 256 "$FINAL_ZIP"
```

Verify the final zip by extracting it in a temporary directory:

```bash
TMP_DIR="$(mktemp -d /tmp/picky-notarized-verify.XXXXXX)"
/usr/bin/ditto -x -k "$FINAL_ZIP" "$TMP_DIR"
xcrun stapler validate "$TMP_DIR/Picky.app"
/usr/sbin/spctl -a -vvv --type execute "$TMP_DIR/Picky.app"
rm -rf "$TMP_DIR"
```

## Share with beta testers

Send the final `*-notarized.zip`, not the raw app bundle and not the pre-staple upload zip.

Suggested message:

```text
Picky beta build

Download: <zip link>
Version: <marketing version> (<build number>)
Build label: <build label>
SHA256: <sha256>

Install:
1. Unzip the file.
2. Move Picky.app to /Applications.
3. Open Picky.
4. Grant macOS permissions when prompted: Accessibility, Screen Recording, Microphone, and Speech Recognition if needed.
```

Because this build is Developer ID-signed, notarized, and stapled, testers normally should **not** need:

```bash
xattr -dr com.apple.quarantine /Applications/Picky.app
```

## macOS permissions across updates

macOS privacy permissions are tied to the app identity, including bundle identifier and code signing requirement. Picky's bundle identifier is:

```text
com.jonghakseo.picky
```

Expected behavior:

- Moving from ad-hoc/dev-signed builds to the first Developer ID notarized build may require granting Accessibility, Screen Recording, Microphone, or Speech Recognition again.
- Updating from one Developer ID notarized Picky build to the next should generally preserve permissions if the bundle identifier and signing identity remain stable.
- Ask testers to keep the app at `/Applications/Picky.app` for the least surprising update behavior.

## Runtime troubleshooting

The packaged app resolves `picky-agentd` in this order:

1. `PICKY_AGENTD_ROOT`, when explicitly set.
2. Bundled `Picky.app/Contents/Resources/agentd/dist/index.js`.
3. Friendly startup failure.

If the app launches but the daemon does not start, ask the tester to check:

```bash
node --version
ls -la ~/Library/Application\ Support/Picky/Logs/
tail -200 ~/Library/Application\ Support/Picky/Logs/agentd.stderr.log
```

## References

- Apple notarization overview: <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
- Apple Developer ID distribution: <https://developer.apple.com/developer-id/>
- Apple notarization workflow customization: <https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow>
- Apple common notarization issues: <https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/resolving_common_notarization_issues>
- Apple `stapler` usage is covered as part of notarization workflow guidance: <https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution>
