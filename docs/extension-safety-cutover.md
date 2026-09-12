# Memory and cron safety cutover

Picky holds curated npm installs and updates for `@ryan_nookpi/pi-extension-memory-layer` and `@ryan_nookpi/pi-extension-cron` in `agentd/src/domain/curated-package-safety.ts`. This also hides their update offers. Removal and explicit setup remain available. The hold is intentionally package-wide, including pinned specs: local fixes are not evidence that a published version contains them. It does not change an already-running Picky app or prevent updates from an external Pi CLI.

## Release gate

Before removing the hold:

1. Publish separately versioned, reviewed extensions containing the compatibility and lifecycle fixes. Do not republish memory 0.4.0 or cron 0.3.0. Confirm the npm artifacts contain the tested sources.
2. Run the Picky Pi 0.84.4 integration test against those artifact contents, not only the extension repository:

   ```bash
   PICKY_TEST_EXTENSION_ROOT=/absolute/path/to/extension-checkout \
     pnpm --dir agentd exec vitest run src/runtime/extension-safety.integration.test.ts
   ```

   The explicit root must contain `packages/memory-layer` and `packages/cron`. The test isolates HOME, agentDir and sessions, loads the real Picky adapter and offline provider, and checks memory persistence/fork isolation plus cron reload/disposal/successor delivery. No running Picky app is involved.
3. Run the extension memory compatibility and cron upgrade tests. Memory tests use historical git objects `27e87d4` and `9f1c2ce`; retain those objects in test checkouts.
4. Require a coordinated maintenance window. Let active cron work finish and stop old writers before changing package files. Back up `~/.pi/memory`, the selected agentDir `cron` directory (including prompts/history), and relevant Pi JSONL sessions. A custom agentDir uses `<agentDir>/memory` after the patch; copy its intended legacy memories explicitly while writers are stopped. The default agentDir, even when explicitly set, still uses `~/.pi/memory`.
5. Replace all old extension runtimes, including external Pi terminals and Picky main/children. Picky's plugin reload does not reload main, skips terminal sessions and aborts streaming sessions rather than reloading them. An app restart needs explicit user permission. Do not use main reset as an update mechanism.
6. Verify daemon runtime identity, one harmless user job, and one session delivery to its original conversation. Only then enable new scoped jobs and remove or narrow the curated hold for the verified release.

## Safety boundaries

- The patched memory writer uses legacy `@entry` topic markers and a versioned tier sidecar keyed by entry identity. A 0.3.3 writer preserves entries; the patched reader restores their tiers. Already-written 0.4.0 v2 markers remain readable. An old 0.4.0 writer can still rewrite a file as v2, which is unsafe for a simultaneous 0.3.3 writer. Reloading every old runtime is required; a package file update alone is insufficient. Preserve sidecars in backups.
- Default-path compatibility is not cross-environment migration. Older versions ignore custom agentDir for memory; do not assume they share the patched custom store.
- Picky snapshot copies receive a fresh Pi header UUID and retain historical custom-entry owner IDs. Existing duplicated JSONL files are not rewritten automatically; inspect them separately before enabling session-scoped features.
- PTT abort reuses its main handle. Reset, deletion and discarded handles dispose the Pi runtime, emit `session_shutdown`, and do not create hidden successor runtimes. Cron intentionally keeps a disposed lease draining until a genuine same-session successor or process exit. Due work can remain deferred while agentd lives, rather than run against a hidden or concurrently open transcript. Persisted session jobs are not cancelled by deleting a Picky card; disable/remove them explicitly if that is the intended outcome.
- Cron's `update-runtime` drains an outdated running scheduler and verifies its replacement. It leaves a stopped daemon stopped. Normal in-place updates do not reinstall LaunchAgents. A mismatched path, Pi binary or agentDir fails closed and requires an explicit migration after all work has stopped. Setup is not a harmless retry: it still installs/reloads launchd.
- Cron 0.2 writers do not understand scope or transaction locks. An old scheduler can execute a session job as `--no-session`. Keep scoped jobs disabled until every scheduler/runtime has been replaced. Delivery acceptance is not task success.

## References

- [Pi package management](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/packages.md)
- [Pi extension shutdown and replacement](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md#session_shutdown)
- [Cron release 0.3.0 operating contract](https://github.com/Jonghakseo/pi-extension/blob/ef621601ffe99d46984f45decd042bedc362f1b7/packages/cron/README.md)

Publishing, installation, LaunchAgent changes and application restarts are separate authorized operations. Local test success does not mean production has been upgraded.
