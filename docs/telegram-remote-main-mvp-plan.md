# Telegram Remote Main MVP Plan

_Status: proposed; product direction confirmed, implementation not started_

_Last updated: 2026-08-19_

## Summary

This plan adds an owner-only Telegram private-message gateway for the existing Picky main session.

The intended use case is temporary remote operation while the user is away from the Mac: receive Pickle completion reports on a phone, ask the same long-lived Picky main session for status, and send additional instructions so Picky can continue orchestrating Pickles.

The confirmed product decisions are:

1. Telegram is a **hidden background gateway**, not a Dock session.
2. Telegram messages go to the **existing Picky main session**, preserving its conversation and Pickle orchestration context.
3. The configured Telegram owner receives **full main-agent capability**, equivalent to local Picky input. This includes local files, Bash, installed extensions, MCPs, credentials available to Pi, and Pickle tools.
4. Isolation applies to the **network adapter and daemon command surface**, not to the main agent's tools or transcript.
5. The MVP uses Telegram Bot API long polling and requires no public webhook, cloud relay, or Picky SaaS backend.

The core invariant is:

> A Telegram message from the locally approved owner is a trusted Picky main input, but the Telegram sidecar can submit only remote-main commands and can observe only its own results and approved completion notifications.

## Design Decision Card

- **User goal:** continue supervising Picky and its Pickles from a phone while temporarily away from the Mac.
- **Primary surface:** owner-only Telegram private chat.
- **Local surface:** Settings → Remote Access; no Dock tile or Conversation Card is added.
- **First-glance information:** gateway enabled state, connected bot identity, approved Telegram owner, and the latest connection/error state.
- **Primary actions:** enable/disable remote access, save/remove bot token, approve/reset owner pairing.
- **Remote actions:** send a main-session instruction, answer a main-session question, request gateway status, or cancel the active remote request.
- **Session semantics:** all accepted remote instructions enter the existing long-lived Picky main session; no second orchestration agent is created.
- **Required local states:** disabled, awaiting token, awaiting owner approval, starting, connected, reconnecting, and failed.
- **Required remote states:** accepted, queued, running, waiting for input, completed, cancelled, interrupted, and failed.
- **Security boundary:** Telegram owner identity plus the bot token is treated as a remote administrator credential. The sidecar receives a separate capability token and never receives the primary agentd token.
- **Appearance:** reuse native Settings controls and existing semantic status presentation. Do not add decorative HUD chrome, a Dock badge, or a hidden conversation card.
- **Accessibility:** every status uses text and an icon in addition to color; secure token controls have explicit labels and help text.
- **Failure visibility:** configuration, authentication, process, polling, pairing, queue, and delivery failures must surface in Settings and/or Telegram, not only in logs.

## Product contract

### Required behavior

When Remote Access is enabled and healthy:

- Only one locally approved Telegram user may send commands.
- Only private chats are accepted. Group, supergroup, channel, inline, forwarded bot, and other-user messages are rejected before they reach agentd.
- Accepted text is submitted to the existing Picky main session without desktop context, screenshots, selected text, active-window data, or browser metadata.
- Remote input appears in the normal Picky main transcript so local and remote conversation continuity is preserved.
- Remote replies are returned to the approved Telegram private chat.
- Intermediate `quickReply` text is not treated as a final remote response. Telegram receives the terminal result for the correlated main turn.
- Remote requests are FIFO. A second Telegram message does not interrupt the first.
- A remote request arriving while a local main turn is active waits until the main session is available.
- A new local input retains existing local priority. If it interrupts an active remote turn, Telegram receives an explicit interrupted/cancelled result instead of timing out or receiving another turn's text.
- Deferred Pickle completion work is allowed to drain before the next queued remote request.
- A Pickle completion that is already configured to notify Picky main is also delivered to Telegram after the main agent produces its final completion summary.
- Remote-origin main replies remain quiet on the Mac: they update main history but do not create a CLI-style cursor bubble or TTS playback.
- Disabling Remote Access stops long polling and closes the scoped gateway connection without restarting Picky.app.

### Full-main trust warning

The Settings UI must state clearly:

> The approved Telegram account can control Picky with the same agent capabilities as local input. If the Telegram account or bot token is compromised, an attacker may access local files, run commands, invoke installed tools, or steer Pickles.

Enabling full remote access requires an explicit confirmation. This is not a sandbox and is not described as one.

### Owner pairing

The preferred MVP pairing flow avoids requiring the user to discover numeric Telegram IDs manually:

1. The user stores a bot token in Keychain and enables Remote Access.
2. The gateway validates the token with `getMe` and enters `awaitingOwner` when no owner is configured.
3. A Telegram user sends `/start` to the bot in a private chat.
4. The sidecar reports the candidate's immutable numeric `user.id` and `chat.id` to Picky Settings. Display name and username are informational only.
5. The local user approves the candidate in Picky.
6. Picky persists the numeric owner and chat IDs in `settings.json` and reconfigures the gateway.
7. Every later update must match the approved user ID, chat ID, and private-chat type.

Resetting the owner requires local Settings access. A new Telegram sender can never replace the owner remotely.

### Main-agent questions

A remote main turn must not hang indefinitely when the main agent invokes `ask_user_question`.

The MVP bridges one pending main form at a time:

- `radio`: render numbered options or Telegram inline buttons and map the selection back to the option value.
- `checkbox`: render numbered options, accept comma-separated selections, and show a Submit action.
- `text`: consume the owner's next non-command message as the answer.
- batched questions: present sequentially and submit one assembled response object to `answerMainExtensionUi`.
- cancellation: `/cancel` cancels the pending form and active remote request visibly.

Pickle-session extension UI is not bridged in this MVP. The bridge covers the Picky main session only.

### Telegram commands

Reserved MVP commands:

- `/start` — begin or refresh local owner pairing.
- `/help` — show supported behavior and the full-main security warning.
- `/status` — show gateway connectivity, active request state, and queue depth without invoking the model.
- `/cancel` — cancel the active remote request or pending main question when owned by Telegram.

All other slash-prefixed input is rejected rather than passed to Pi as a slash command.

## Non-goals

- No Slack integration.
- No Telegram groups, channels, multiple owners, multiple bots, or multi-workspace tenancy.
- No public webhook, public inbound port, cloud relay, Picky backend, or OAuth service.
- No voice messages, images, files, locations, stickers, reactions, edited-message replay, or Telegram Mini App.
- No token storage in `settings.json`, build resources, logs, command arguments, or the agentd connection file.
- No separate Remote Inbox LLM session.
- No Dock icon, Conversation Card, hidden Pickle, or remote-session transcript UI.
- No restriction of main-agent tools for Telegram-origin turns. Full-main access is an explicit product decision.
- No live token streaming, thinking traces, tool logs, screenshots, or raw local artifacts sent to Telegram.
- No direct handling of Pickle `waiting_for_input` forms.
- No guarantee that the gateway operates while the Mac is asleep, powered off, offline, or Picky.app is not running.
- No exactly-once guarantee for Telegram outbound message display across a process crash after Telegram accepts a message but before local delivery state is persisted. Main instruction execution must still be deduplicated.

## Architecture

```text
Picky Settings
  - non-secret config in settings.json
  - Telegram bot token in Keychain
        |
        | authenticated local app-agentd command
        | configureTelegramGateway(token, enabled, owner IDs)
        v
primary picky-agentd
  - TelegramGatewayManager
  - RemoteMainBridge / durable request ledger
  - scoped /remote-gateway WebSocket endpoint
        |
        | spawn + stdin bootstrap config
        | separate random capability token
        v
telegram-gateway sidecar (Node)
  - Telegram Bot API getUpdates long polling
  - exact owner/private-chat policy
  - durable update/outbox journal
  - scoped remote-main WebSocket client
        |
        | outbound HTTPS only
        v
Telegram Bot API

RemoteMainBridge
  -> existing SessionSupervisor main runtime
  -> existing Picky/Pickle orchestration tools
  <- terminal main-turn result
  <- main Pickle-completion result
```

### Why a sidecar

The Telegram transport runs in a separate child process because it parses untrusted remote payloads and maintains long-lived network state. A crash or parser defect should not directly terminate the primary daemon.

The sidecar is still launched and supervised by primary agentd so that:

- Picky.app remains a thin Settings and lifecycle owner;
- the bundled Node runtime and compiled agentd resources are reused;
- the bot token can move from Keychain to agentd over the existing authenticated local connection and then to the sidecar through stdin;
- primary agentd can generate and enforce the scoped gateway capability token;
- enable/disable and restart backoff do not require relaunching Picky.app.

### Scoped gateway credential

The existing primary token authorizes the full WebSocket protocol and receives global broadcasts. The sidecar must never receive it.

Primary agentd creates a separate random token for `/remote-gateway`. That endpoint:

- accepts only the remote gateway protocol;
- rejects normal Picky command envelopes;
- does not join the regular broadcast client set;
- can submit, cancel, answer, synchronize, and acknowledge only remote-main requests/notifications;
- receives only request-correlated results, main questions owned by its request, and allowed Pickle completion notifications.

### Remote gateway protocol

Keep this provider-neutral protocol in a separate TypeScript schema instead of adding Telegram fields to the app-agentd protocol.

Commands:

- `remoteHello`
- `remoteSubmit { requestId, provider, providerUpdateId, text }`
- `remoteCancel { requestId }`
- `remoteAnswerQuestion { requestId, uiRequestId, value }`
- `remoteSync { requestIds, notificationCursor? }`
- `remoteAckNotification { notificationId }`

Events:

- `remoteReady`
- `remoteAccepted { requestId, state }`
- `remoteQuestion { requestId, uiRequestId, form }`
- `remoteCompleted { requestId, outcome, text? }`
- `remoteNotification { notificationId, kind, sessionId?, title?, text }`
- `remoteError { requestId?, code, message, retryable }`

Provider-specific destination identifiers remain in the sidecar journal and never enter `SessionSupervisor`.

## Main-turn ownership and ordering

### Request identity

The sidecar derives a stable request ID from the bot identity and Telegram `update_id`. Resending the same Telegram update therefore uses the same remote request ID.

Primary agentd persists the request before acknowledging it. Duplicate request IDs return the existing state or terminal result and never execute the main instruction twice.

### Admission rules

A small pure policy determines what may run next:

1. The current main turn continues until terminal, waiting for input, or explicit interruption.
2. Pending Pickle completion delivery runs before a newly queued remote request.
3. Remote requests run FIFO.
4. Remote input never interrupts local input.
5. Local input may preserve its existing interrupt behavior. If it preempts a remote turn, the remote request becomes `interruptedByLocalInput` and receives a terminal event.
6. A remote form answer resumes only its matching active request.
7. Stale terminal, question, or cancellation events cannot settle a newer request.

The mutable owner remains `SessionSupervisor`; the ordering rule is extracted into a pure policy and covered independently.

### Terminal result contract

`quickReply` is not a reliable remote terminal signal because one logical turn can emit intermediate text before tools and another reply at the end.

Add an internal provider-neutral main-turn terminal event emitted exactly once for every main context:

```ts
{
  contextId: string;
  outcome: "completed" | "failed" | "cancelled" | "interrupted";
  finalText?: string;
  replyKind: "main" | "pickleCompletion";
  sessionId?: string;
}
```

This internal event feeds `RemoteMainBridge`; it does not need to be broadcast to normal app clients. Existing `quickReply`, TTS, cursor, and HUD behavior remains unchanged.

### Remote-origin context

Add `remote` to `PickyContextPacket.source` and build a transcript-only packet:

- no screenshots;
- no active app/window;
- no browser or selected text;
- main-agent cwd unchanged;
- source visible to the model as `remote`;
- quick-reply presentation maps `remote` to the existing quiet `system` origin so the Mac does not speak or show a CLI cursor reply.

## Pickle completion reporting

The existing per-Pickle `notifyMainOnCompletion` policy remains the source of truth.

When enabled for a Pickle:

1. The Pickle completes.
2. Existing main completion delivery asks Picky main to summarize the result.
3. The internal main-turn terminal event carries `replyKind: "pickleCompletion"` and the Pickle `sessionId`.
4. `RemoteMainBridge` writes a durable notification containing the final main summary, session ID, and title.
5. The connected gateway receives it and posts it to Telegram.
6. The sidecar acknowledges delivery; unacknowledged notifications replay after reconnect.

Do not send raw tool logs, screenshots, local artifact contents, or full Pickle transcripts automatically. The user may ask the main session for more detail in a later Telegram message.

## Persistence and recovery

### Agentd request ledger

Store under Picky Application Support, separate from normal sessions:

```text
RemoteAccess/remote-main-requests.json
```

Persist:

- request ID and source provider;
- accepted/queued/running/waiting/terminal state;
- context ID when assigned;
- terminal outcome and final text;
- pending main UI request ID;
- durable Pickle completion notifications and acknowledgement state;
- bounded timestamps for retention and cleanup.

On primary daemon restart, non-terminal requests become `interruptedByRestart`. They are not automatically re-executed because the previous turn may already have performed side effects.

### Sidecar journal

Store under:

```text
RemoteAccess/Telegram/gateway-state.json
```

Persist atomically with mode `0600`:

- Telegram update offset;
- approved bot identity returned by `getMe`;
- pending update → remote request mappings;
- pending Telegram outbox entries;
- last acknowledged remote notification cursor;
- reconnect/backoff metadata that is useful for recovery but contains no token.

Before advancing the Telegram offset, persist the normalized update and deterministic request ID. On reconnect, call `remoteSync` rather than blindly resubmitting a potentially executed instruction.

### Retention

Use bounded local retention:

- terminal remote requests: 7 days or the latest 100, whichever is smaller;
- acknowledged completion notifications: 7 days or the latest 100;
- active/non-terminal entries are never removed by count trimming;
- logs contain IDs, state, and character counts only, never full Telegram text or tokens.

## Telegram transport behavior

### Official API assumptions

- Use `getUpdates` long polling; do not configure a webhook.
- `getUpdates` and webhooks are mutually exclusive.
- Recalculate and persist `offset` to prevent duplicate updates.
- Telegram retains undelivered updates for no longer than 24 hours.
- Use `sendMessage`, `editMessageText`, `sendChatAction`, and `answerCallbackQuery` only.
- Split long plain-text responses below Telegram's 4096-character message limit.

Official references:

- Telegram Bot API: <https://core.telegram.org/bots/api>
- Telegram Bot features and privacy mode: <https://core.telegram.org/bots/features>
- Telegram Bots FAQ: <https://core.telegram.org/bots/faq>

### Input policy

Accept only:

- `message.text` from the approved private chat;
- `callback_query` tied to the active approved main question;
- `/start` from a private chat while awaiting local owner approval.

Reject or ignore:

- wrong user/chat IDs;
- group/channel messages;
- messages authored by bots;
- edited messages;
- media and unsupported update types;
- callback data with stale request/question IDs;
- messages beyond the configured length or queue bounds.

### Output policy

- Send plain text in the MVP; do not use Markdown parse modes that require escaping model output.
- Chunk on Unicode-safe boundaries and add stable part labels when multiple messages are required.
- Retry transient Telegram errors using bounded exponential backoff and `Retry-After` when provided.
- Persist outbox state before sending.
- A crash between Telegram accepting a message and persisting the returned message ID may create a duplicate visible reply; document this residual limitation.

## Settings and lifecycle UX

Add **Remote Access** under the General Settings group.

### Controls

- Enable Telegram Remote Access toggle.
- Secure bot token field with configured/not-configured state.
- Save token and Remove token actions.
- Bot identity/status after `getMe` validation.
- Owner state: unpaired, candidate pending local approval, paired user ID/chat ID.
- Approve candidate and Reset owner actions.
- Gateway process state and latest safe error message.
- Explicit full-main warning and confirmation before first enable.

### Lifecycle

- Picky.app reads the token from Keychain and sends `configureTelegramGateway` over the authenticated primary connection.
- Primary agentd owns sidecar start, stop, crash detection, and bounded restart backoff.
- Settings changes reconcile live; no Picky.app restart.
- On app-agentd reconnect, the app re-sends the current in-memory configuration.
- On disable, agentd stops the sidecar and clears the bot token from daemon/sidecar memory. The Keychain item remains until Remove token is selected.
- On app termination or update relaunch, the existing agentd shutdown terminates the sidecar.

## Change map

### Agentd: main turn and persistence

Modify:

- `agentd/src/session-supervisor.ts`
  - remote request admission, active ownership, question correlation, explicit interruption, terminal event, and queue drain integration.
- `agentd/src/protocol.ts`
  - add `remote` context source and app-side configuration/status command/event contracts only.
- `agentd/src/domain/main-agent-policy.ts`
  - map remote quick-reply presentation to quiet `system` origin.
- `agentd/src/bootstrap.ts`
  - compose the manager, request store, bridge, and server dependencies in primary mode only.
- `agentd/src/server.ts`
  - app command/status dispatch and separate scoped WebSocket upgrade path without global broadcasts.
- `agentd/src/index.ts`
  - start/stop ordering and bound-port handoff to the gateway manager.

Create:

- `agentd/src/domain/remote-main-admission-policy.ts`
- `agentd/src/application/remote-main-request-store.ts`
- `agentd/src/application/remote-main-bridge.ts`
- `agentd/src/remote-gateway-protocol.ts`
- adjacent `*.test.ts` files for each pure/application boundary.

### Agentd: Telegram sidecar

Create:

- `agentd/src/telegram/telegram-bot-api.ts`
- `agentd/src/telegram/telegram-update-policy.ts`
- `agentd/src/telegram/telegram-message-chunker.ts`
- `agentd/src/telegram/telegram-gateway-store.ts`
- `agentd/src/telegram/telegram-remote-main-client.ts`
- `agentd/src/telegram/telegram-gateway-service.ts`
- `agentd/src/telegram/telegram-question-presenter.ts`
- `agentd/src/telegram-gateway.ts`
- adjacent deterministic tests using fake HTTP, fake WebSocket, fake clock, and temporary directories.

Create the sidecar process owner:

- `agentd/src/application/telegram-gateway-manager.ts`
  - spawn `dist/telegram-gateway.js` using the running Node executable;
  - write bootstrap secrets through stdin;
  - parse structured status lines;
  - restart with bounded backoff;
  - stop and zero in-memory configuration on disable.

Update:

- `agentd/package.json`
  - add a local development entry for the sidecar if useful; no Telegram SDK dependency is required because pinned Node provides `fetch` and the repository already depends on `ws`.
- `scripts/package-signed-app.sh`
  - verify that `dist/telegram-gateway.js` is included with bundled agentd resources.

### Swift app: settings, secret, and configuration sync

Create:

- `Picky/App/Settings/PickyTelegramRemoteAccess.swift`
  - non-secret Codable configuration and validation helpers.
- `Picky/App/Settings/PickyTelegramTokenStore.swift`
  - Keychain read/write/delete behind an injectable protocol.
- `Picky/Companion/PickyTelegramRemoteAccessController.swift`
  - load Keychain + settings, send redacted local configuration, consume status/candidate events, and reconcile after reconnect/settings saves.

Modify:

- `Picky/App/Settings/PickySettings.swift`
  - enabled flag, approved owner user/chat IDs, and first-enable warning acknowledgement; never the bot token.
- `Picky/App/Settings/PickySettingsStore.swift`
  - numeric-ID and enabled-state validation.
- `Picky/App/Settings/PickySettingsViewModel.swift`
  - preserve secret/non-secret ownership and emit save notifications.
- `Picky/Companion/CompanionPanelSettingsModel.swift`
  - add `Remote Access` route under General.
- `Picky/Companion/CompanionPanelSettingsView.swift`
  - native controls, semantic status, local owner approval, reset, warning, and accessible error presentation.
- `Picky/PickyAgentProtocol.swift`
  - configure/status/candidate command and event models; keep bot token redacted from descriptions.
- `Picky/PickyAgentClient.swift`
  - safe command/event descriptions with token length/configured state only.
- `Picky/PickyAgentClientRouter.swift`
  - route gateway configuration only to the primary daemon.
- `Picky/PickyApp.swift`
  - own the controller and reconcile on launch, reconnect, settings save, and termination.
- `Picky/Resources/Localizable.xcstrings`
  - English and Korean Settings/status/security copy.
- `Picky.xcodeproj/project.pbxproj`
  - add new Swift sources if the project group is not filesystem-synchronized.

### Contracts and documentation

Modify/create:

- `contracts/protocol/`
  - gateway configuration/status fixtures and a remote-source context fixture.
- `PickyTests/ProtocolContractTests.swift`
- `agentd/src/protocol.test.ts`
- `ARCHITECTURE.md`
  - optional outbound remote gateway and full-main trust boundary.
- `docs/user-manual.md`
  - setup, pairing, usage, disable/reset, security warning, and awake/online requirements.

## Blast radius

Estimated risk: **8/10 (high)**.

- **Fan-in: 4/4** — `SessionSupervisor`, primary server, protocol, launcher lifecycle, and Settings are shared critical paths.
- **Fan-out: 2/3** — the feature touches main runtime events, persistence, child process management, Keychain, WebSocket auth, and Telegram HTTPS.
- **Recent churn: 2/3** — main-turn queueing and session activity code are active areas.

The prior verifier/reviewer/challenger pressure review identified the same blockers this plan addresses: final-result correlation, interrupt semantics, scoped credentials, durable inbox/outbox, cross-origin leakage, context capture, and Pickle completion causation.

Implementation must proceed in narrow vertical slices with characterization tests before changing `SessionSupervisor` behavior.

## Test Plan Card

- **Change target:** owner-only Telegram gateway to the existing Picky main session.
- **User/system contract:** only the locally approved private Telegram owner can submit full-main instructions; every accepted request gets one correctly correlated terminal outcome; configured Pickle completion summaries reach Telegram after reconnect when necessary.
- **Picky invariants:** local-first without a Picky backend; explicit predictable routing; visible failures; persistent/reconnectable long-running orchestration; app-agentd protocol compatibility; no accidental desktop-context capture.

### Selected test layers

- **Pure agentd unit:** owner/update policy, queue admission, message chunking, retry classification, stale callback rejection.
- **Agentd integration:** main-turn terminal correlation, local interruption, request ledger, scoped WebSocket auth, sidecar manager lifecycle, notification replay.
- **Swift orchestration:** Keychain ownership, configuration reconciliation, reconnect, enable/disable, candidate approval, status/error projection.
- **Cross-language contract:** app-agentd configuration/status/candidate events and `remote` context source compatibility.
- **Runtime/package smoke:** compiled sidecar entry exists and starts with fake transport/config; do not contact Telegram or restart the running Picky app.
- **Excluded UI/E2E:** no XCUI test; Settings state can be covered through models/controllers and manual verification without a stable menu-bar UI harness.

### Required automated scenarios

1. Wrong user, wrong chat, group, bot-authored, edited, and unsupported updates never submit to agentd.
2. `/start` creates a local approval candidate but never grants access remotely.
3. Approved owner IDs survive settings reload; bot token exists only in the fake/real Keychain store.
4. Remote access cannot enable without token, owner approval, and explicit full-main acknowledgement.
5. Scoped gateway token is rejected on the normal WebSocket endpoint.
6. Primary token is rejected on the scoped endpoint unless intentionally supported by test-only injection.
7. Scoped clients cannot send normal session/package/auth commands and receive no global broadcasts.
8. Remote context contains transcript/cwd/timestamp only and never requests app capture.
9. Remote input waits behind an active local turn.
10. Two remote inputs execute FIFO without interruption.
11. A local input interrupt produces `interruptedByLocalInput` for the exact remote request.
12. Intermediate `turn_text_complete`/`quickReply` output does not complete the remote request.
13. Exactly one terminal event settles each remote context.
14. Duplicate Telegram update/request IDs never execute twice.
15. Daemon restart marks a previously running request interrupted rather than replaying side effects.
16. Gateway reconnect syncs terminal results and unacknowledged completion notifications.
17. Main `ask_user_question` routes only to the active matching remote request; stale answers are rejected.
18. Radio, checkbox, text, batch, and cancel form paths produce the expected answer payload.
19. Pickle completion notification follows existing `notifyMainOnCompletion` and carries the matching session ID/title.
20. Telegram output is Unicode-safe, plain text, and chunked below the API limit.
21. Transient Telegram failures retry; permanent auth failures enter a visible failed state.
22. Sidecar crash uses bounded restart backoff; disabling cancels restarts and terminates the child.
23. Bot token and full message text are absent from logs, protocol descriptions, status snapshots, and settings JSON.
24. Remote-origin replies do not produce local CLI cursor ownership or TTS.

### Fake/mock boundaries

- Fake Telegram HTTP transport and deterministic update stream.
- Fake scoped WebSocket transport for sidecar unit tests.
- Manual/fake main runtime for `SessionSupervisor` tests.
- Temporary Application Support directories for both journals.
- Fake process factory for sidecar manager tests.
- Fake Keychain store and primary agent client for Swift orchestration tests.
- Fake clock/UUID/backoff scheduler; no arbitrary long sleeps.

### Narrow validation commands

```bash
pnpm --dir agentd exec vitest run \
  src/domain/remote-main-admission-policy.test.ts \
  src/application/remote-main-request-store.test.ts \
  src/application/remote-main-bridge.test.ts \
  src/telegram/telegram-update-policy.test.ts \
  src/telegram/telegram-message-chunker.test.ts \
  src/telegram/telegram-gateway-store.test.ts \
  src/telegram/telegram-gateway-service.test.ts \
  src/application/telegram-gateway-manager.test.ts

pnpm --dir agentd exec vitest run \
  src/session-supervisor.test.ts \
  src/server.test.ts \
  src/protocol.test.ts

pnpm --dir agentd run test:contracts
pnpm --dir agentd run typecheck
pnpm --dir agentd run lint
pnpm --dir agentd run build

xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" test \
  -only-testing:PickyTests/PickyTelegramTokenStoreTests \
  -only-testing:PickyTests/PickyTelegramRemoteAccessControllerTests \
  -only-testing:PickyTests/PickySettingsSanitizerTests \
  -only-testing:PickyTests/ProtocolContractTests

xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" build

git diff --check
```

Do not run real Telegram network tests in the default suite. Do not restart the running Picky app without explicit permission.

## Implementation sequence

### Task 1: Characterize current main-turn behavior

**Files:**

- Modify: `agentd/src/session-supervisor.test.ts`
- Modify: `agentd/src/server.test.ts`

**Steps:**

1. Add tests proving the current intermediate `quickReply` and terminal status ordering.
2. Add tests proving local input interrupts an active main turn today.
3. Add tests proving Pickle completion is deferred while main is busy.
4. Run the two focused suites and record the characterization baseline.

### Task 2: Define remote contracts and pure policies

**Files:**

- Create: `agentd/src/remote-gateway-protocol.ts`
- Create: `agentd/src/domain/remote-main-admission-policy.ts`
- Create adjacent tests.
- Modify: `agentd/src/protocol.ts`
- Modify: `agentd/src/domain/main-agent-policy.ts`
- Modify protocol fixtures/tests.

**Steps:**

1. Add failing schema tests for scoped commands/events and `remote` context source.
2. Add the main admission policy with FIFO, local priority, Pickle completion priority, and stale identity protection.
3. Map remote presentation to quiet `system` origin.
4. Run pure and contract tests.

### Task 3: Add durable remote request ownership to agentd

**Files:**

- Create: `agentd/src/application/remote-main-request-store.ts`
- Create: `agentd/src/application/remote-main-bridge.ts`
- Modify: `agentd/src/session-supervisor.ts`
- Create/modify focused tests.

**Steps:**

1. Add failing store tests for atomic persistence, dedupe, restart interruption, retention, and notification acknowledgement.
2. Add failing supervisor tests for queued remote input and exactly-once terminal events.
3. Implement the ledger and one mutable remote-turn owner inside `SessionSupervisor`.
4. Emit provider-neutral terminal metadata only after the real terminal runtime event.
5. Correlate main extension UI requests with the active remote request.
6. Integrate Pickle completion terminal notifications and drain ordering.
7. Run focused supervisor/store/bridge suites.

### Task 4: Add the scoped gateway WebSocket surface

**Files:**

- Modify: `agentd/src/server.ts`
- Modify: `agentd/src/bootstrap.ts`
- Modify: `agentd/src/index.ts`
- Create scoped server tests in `agentd/src/server.test.ts` or a focused adjacent file.

**Steps:**

1. Add failing authentication and command-allowlist tests.
2. Add a separate `/remote-gateway` upgrade path and client set.
3. Ensure scoped clients receive no regular broadcasts.
4. Wire submit/cancel/answer/sync/ack to `RemoteMainBridge`.
5. Verify regular Picky/CLI clients remain unchanged.

### Task 5: Implement Telegram transport and durable sidecar journal

**Files:**

- Create modules under `agentd/src/telegram/`.
- Create: `agentd/src/telegram-gateway.ts`
- Create adjacent tests.

**Steps:**

1. Implement the pure update acceptance policy and message chunker test-first.
2. Implement a fakeable Bot API adapter for `getMe`, `getUpdates`, send/edit/action/callback methods.
3. Implement the atomic `0600` sidecar journal and request/outbox recovery.
4. Implement the scoped remote-main client with reconnect and sync.
5. Implement owner pairing candidate emission, reserved commands, FIFO submission, and answer collection.
6. Implement outbound retry/backoff and structured redacted status lines.
7. Run only fake-network tests.

### Task 6: Supervise the sidecar from primary agentd

**Files:**

- Create: `agentd/src/application/telegram-gateway-manager.ts`
- Modify: `agentd/src/bootstrap.ts`
- Modify: `agentd/src/server.ts`
- Modify: `agentd/src/index.ts`
- Add manager/server tests.

**Steps:**

1. Add a fake child-process seam and lifecycle tests.
2. Spawn the sidecar with the current Node executable and compiled/source entry point.
3. Send bot token, owner IDs, scoped token, endpoint, and state path through stdin.
4. Forward redacted status/candidate events to normal Picky clients.
5. Reconcile idempotently on configure, disable, crash, and daemon stop.

### Task 7: Add Keychain-backed Settings and live configuration sync

**Files:**

- Create Swift settings/token/controller files listed in the change map.
- Modify `PickySettings`, Settings model/view, protocol/client/router, `PickyApp`, localization, and tests.

**Steps:**

1. Add failing Keychain abstraction tests for read/write/delete and no settings persistence.
2. Add backward-compatible settings decode/default tests.
3. Add cross-language configure/status/candidate fixtures.
4. Add controller tests for launch, reconnect, settings save, candidate approval, reset, disable, and error states.
5. Add the native Settings page with explicit full-main warning and confirmation.
6. Reuse existing semantic status tokens and preserve light/dark, keyboard, and VoiceOver behavior.
7. Run targeted Swift suites and build.

### Task 8: Package and document

**Files:**

- Modify: `scripts/package-signed-app.sh`
- Modify: `ARCHITECTURE.md`
- Modify: `docs/user-manual.md`
- Modify package/build tests as needed.

**Steps:**

1. Ensure `dist/telegram-gateway.js` is included and validated in packages.
2. Document setup, pairing, commands, security, reset, and operating requirements.
3. Document that Picky and the Mac must remain running, awake, and online; queued Telegram updates expire after 24 hours.
4. Run agentd build and a fake-config sidecar startup smoke without contacting Telegram.

### Task 9: Final verification and manual acceptance

1. Run targeted agentd and Swift tests.
2. Run `test:contracts`, agentd typecheck/lint/build, and macOS build.
3. Run the full serial agentd suite if targeted suites pass.
4. Do not run a real credentialed test until the user explicitly provides/approves a test bot and authorizes use.
5. Do not restart the running Picky app without explicit permission.
6. Update this document status only after the accepted validation matrix passes.

## Manual acceptance matrix

With an explicitly approved test bot and owner account:

1. Enable Remote Access, validate bot identity, send `/start`, and approve the candidate locally.
2. Confirm another Telegram account and a group mention cannot invoke Picky.
3. Ask for current Pickle status and confirm the existing Picky main context is used.
4. Send two rapid instructions and confirm FIFO responses with no cross-routing.
5. Start a local Picky input during a remote turn and confirm Telegram receives an explicit interruption result.
6. Trigger a main `ask_user_question` flow and answer radio, checkbox, and text questions from Telegram.
7. Complete a notify-enabled Pickle and confirm its main-generated report reaches Telegram.
8. Disconnect/reconnect network and confirm accepted request results and notifications recover without re-executing instructions.
9. Disable Remote Access and confirm polling/process activity stops immediately.
10. Inspect settings JSON, logs, diagnostics, process arguments, and connection info to confirm no bot token is present.
11. Confirm remote responses update main history but do not speak or show a cursor response on the Mac.
12. Put the Mac to sleep and confirm the documented offline limitation rather than claiming background cloud availability.

## Observability

Structured logs may include:

- gateway lifecycle state;
- bot identity ID/username after validation;
- approved owner numeric IDs;
- update/request/context/session IDs;
- queue depth and transition reasons;
- Telegram method name, status code, retry classification, and `Retry-After`;
- sidecar exit code and restart delay;
- notification acknowledgement and retention cleanup.

Never log:

- bot token or scoped gateway token;
- full Telegram message text;
- main or Pickle final answer text;
- local file contents, screenshots, browser context, or tool arguments returned by the model.

## Open implementation details

These do not change the product contract and may be resolved during implementation:

- exact local JSON schema version numbers and retention timestamps;
- whether long Telegram replies use only `sendMessage` chunks or update a temporary processing message first;
- exact restart backoff constants;
- whether the Remote Access Settings route is implemented in the existing large Settings view first or extracted into a focused subview immediately.

Any change to owner-only private-chat scope, full-main authority, hidden-background presentation, public-server requirements, or completion-report behavior requires revisiting this plan before implementation.
