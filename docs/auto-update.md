# Auto-update Guide

Picky uses [Sparkle 2](https://sparkle-project.org) for in-app updates. Updates
are signed with EdDSA, hosted as GitHub Release assets, and delivered through a
single appcast that splits stable and beta into channels.

## Design summary

| Item              | Decision                                                                           |
| ----------------- | ---------------------------------------------------------------------------------- |
| Framework         | Sparkle 2 via SwiftPM (`https://github.com/sparkle-project/Sparkle`)               |
| Signature         | EdDSA (`SUPublicEDKey` in `Info.plist`, private key in GitHub Secrets)             |
| Update payload    | Notarized `.zip` (separate from the user-facing `.dmg`)                            |
| Appcast hosting   | `appcast.xml` uploaded as a GitHub Release asset on a fixed tag (`auto-update`)    |
| Channels          | Single `appcast.xml` with explicit `<sparkle:channel>` tags on every item          |
| stable on appcast | Items with `<sparkle:channel>stable</sparkle:channel>` only                        |
| beta on appcast   | Items with `<sparkle:channel>beta</sparkle:channel>` only                          |
| Auto check        | ON, every 4 hours (`SUEnableAutomaticChecks`, `SUScheduledCheckInterval=14400`)    |
| UX                | Sparkle's standard user driver (prompt on update available)                        |
| alpha builds      | `SPUUpdater` is **not** started — trusted sideload testers update manually via the next internal alpha zip/package |
| Settings entry    | `CompanionPanelStatusView` adds an **Updates** section with a read-only channel    |
| Menu entry        | `Check for Updates…` in the app menu commands                                      |

References:
- Sparkle 2 API: <https://sparkle-project.github.io/documentation/api-reference/>
- Channels: <https://sparkle-project.github.io/documentation/api-reference/Protocols/SPUUpdaterDelegate.html#//api/name/allowedChannelsForUpdater:>
- Programmatic setup: <https://sparkle-project.github.io/documentation/programmatic-setup>
- Code signing & sandboxing: <https://sparkle-project.github.io/documentation/sandboxing/>

## How channel selection works

`PickyUpdaterController` uses the app bundle's own `releaseChannel` from
`PickyBuildInfo.json` and reports that fixed build channel to Sparkle through
`SPUUpdaterDelegate.allowedChannelsForUpdater:`:

| App build channel | `allowedChannels` | Items the updater considers                                     |
| ----------------- | ----------------- | --------------------------------------------------------------- |
| `stable`          | `["stable"]`     | Items tagged `<sparkle:channel>stable</sparkle:channel>` only   |
| `beta`            | `["beta"]`       | Items tagged `<sparkle:channel>beta</sparkle:channel>` only     |

Sparkle always considers default (no-channel) items in addition to explicitly
allowed channels, so Picky's appcast generator writes an explicit `stable` or
`beta` channel tag on every item and migrates older no-channel items to
`stable` the next time it updates `appcast.xml`. This keeps stable apps on
stable updates and beta apps on beta updates.

`alpha` is **not** a Sparkle channel. Builds with `releaseChannel == "alpha"`
in `PickyBuildInfo.json` skip starting the updater entirely.

## One-time setup

### 1. Generate the EdDSA key pair

After Sparkle is added as a SwiftPM dependency, Xcode resolves it under
`~/Library/Developer/Xcode/DerivedData/.../SourcePackages/artifacts/sparkle/Sparkle/bin/`.
The same `bin/` directory ships `generate_keys` and `sign_update`. From a clean
checkout:

```bash
xcodebuild -resolvePackageDependencies -project Picky.xcodeproj -scheme Picky
SPARKLE_BIN="$(/usr/bin/find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin' -type d -print -quit)"
"${SPARKLE_BIN}/generate_keys"
```

`generate_keys` stores the private key in the macOS keychain and prints the
matching public key. Copy that public key into `Picky/Info.plist` under
`SUPublicEDKey`.

### 2. Export the private key for CI

```bash
"${SPARKLE_BIN}/generate_keys" -x ~/picky-sparkle-private.txt
```

Add the exported file's contents to GitHub Secrets:

| Secret name                      | Value                                                                  |
| -------------------------------- | ---------------------------------------------------------------------- |
| `PICKY_SPARKLE_ED_PRIVATE_KEY`   | Contents of `~/picky-sparkle-private.txt` (EdDSA private key)          |
| `PICKY_SLACK_BOT_TOKEN`          | Slack Bot User OAuth Token with `chat:write` for release notifications |

The CI workflow imports this secret into a temporary file and passes it to
`sign_update -f <file> <zip>` per release.

After exporting, **shred the local copy**:

```bash
rm -P ~/picky-sparkle-private.txt
```

### 3. Configure Slack release notifications

The notarized release workflow posts a success message after the DMG is
notarized, uploaded to the GitHub Release, and release notes are updated. It
uses Slack Web API `chat.postMessage`, not the in-app feedback webhook/token.

1. Add a repository secret named `PICKY_SLACK_BOT_TOKEN` with a Slack Bot User
   OAuth token that has the `chat:write` scope.
2. Invite the bot to the release-notification channel.
3. The destination channel is configured in
   `.github/workflows/beta-notarized-release.yml` as
   `PICKY_RELEASE_SLACK_CHANNEL_ID` (`C0B41QL02SU`).

References:
- Slack `chat.postMessage`: <https://api.slack.com/methods/chat.postMessage>
- Slack message formatting: <https://api.slack.com/reference/surfaces/formatting>

### 4. Pre-create the `auto-update` tag

The appcast lives at a stable URL so we never need to update `SUFeedURL` in
`Info.plist`. Create a tag named `auto-update` once and the CI workflow attaches
`appcast.xml` to that tag's release on every notarized build.

```bash
git tag -a auto-update -m "Sparkle appcast asset anchor"
git push origin auto-update
gh release create auto-update --title "Picky appcast" --notes "Sparkle appcast asset anchor — do not delete."
```

`SUFeedURL` in `Info.plist`:

```text
https://github.com/Jonghakseo/picky/releases/download/auto-update/appcast.xml
```

## Release flow

1. Push the version tag (e.g. `v1.0.5`) and publish a normal GitHub Release to
   run `.github/workflows/beta-notarized-release.yml` as a **stable** build.
   Publish a GitHub pre-release or trigger `workflow_dispatch` with
   `release_channel=beta` for a beta build.
2. The workflow:
   - Builds the signed app, notarizes the `.app`, staples it.
   - Builds the user-facing `.dmg` and notarizes/staples that.
   - Builds an additional **zip enclosure** (`Picky-<ver>-<label>-update.zip`).
   - Calls `sign_update` with the imported EdDSA private key on the zip.
   - Updates `appcast.xml` (downloaded from the `auto-update` release, same
     build/channel item replaced on rerun, new `<item>` prepended, then
     re-uploaded with `gh release upload --clobber`).
   - Uploads both the user `.dmg` and the update `.zip` to the version tag's
     release.
   - Sends a Slack notification to the release channel with direct links to the
     GitHub Release page, DMG asset, and GitHub Actions run.
3. When users running stable launch the app, Sparkle fetches `appcast.xml`
   every 4 hours, finds the newest item tagged `stable`, and prompts the user.
4. Beta users do the same and get the newest item tagged `beta`.

## Why a separate zip enclosure (and not the DMG)?

Sparkle technically supports DMG enclosures, but DMGs require a mount step that
inflates install time and increases the chance of a partially-installed update.
Sparkle's own [code-signing guide](https://sparkle-project.github.io/documentation/code-signing/)
recommends zip for delta-friendly, fast installs. The DMG remains the
first-install acquisition path for users who download from the GitHub Release
page.

## Local validation

Without publishing a real release, run a smoke check by:

1. Building a `beta`-channel package:
   ```bash
   PICKY_RELEASE_CHANNEL=beta ./scripts/package-signed-app.sh
   ```
2. Pointing `SUFeedURL` at a local file via `defaults` for the running app:
   ```bash
   defaults write com.jonghakseo.picky SUFeedURL "file:///tmp/test-appcast.xml"
   ```
3. Hosting `/tmp/test-appcast.xml` and a higher-version zip locally, then using
   `Check for Updates…` from the menu.

## Troubleshooting

- **`SUNoUpdateError` when running an alpha build**: expected — alpha builds do
  not start `SPUUpdater`. Repackage with `PICKY_RELEASE_CHANNEL=beta` (or
  `stable`) to test the updater path.
- **`SUSignatureError`**: the `SUPublicEDKey` in `Info.plist` doesn't match the
  private key that signed the appcast item. Verify with
  `sign_update -p ~/picky-sparkle-private.txt`.
- **Daemon crashes on relaunch**: Sparkle relaunch handling flows through
  `PickyUpdaterController.updaterWillRelaunchApplication(_:)`; `PickyApp`
  wires that callback to terminate Pickle child daemons and stop the bundled
  `picky-agentd` before Sparkle replaces the bundle. If the daemon crashes
  during an update, check `~/Library/Application Support/Picky/Logs/agentd.stderr.log`
  around the relaunch timestamp.
