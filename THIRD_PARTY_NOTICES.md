# Third-Party Notices

Picky itself is licensed under the Apache License 2.0 (see `LICENSE`). The packaged Picky.app also contains the third-party software below. Each entry names the component, its version, its license, and where the full text lives.

A packaged app carries this file and the full texts at `Contents/Resources/THIRD_PARTY_NOTICES.md` and `Contents/Resources/licenses/` (copied by `scripts/package-signed-app.sh`). In the repository they are at the top level and in `licenses/`.

Versions and licenses were taken from the pinned inputs: `agentd/package.json`, `Package.resolved`, `pnpm-lock.yaml`, `agentd/async-task-provider-deps/pnpm-lock.yaml`, and each package's own `package.json`. The npm tables in section 6 come from the production dependency trees that `scripts/package-agentd-runtime.sh` packages. Regenerate them when a dependency changes.

## 1. App components (Swift)

| Component | Version | License | Copyright | Full text |
| --- | --- | --- | --- | --- |
| [Sparkle](https://github.com/sparkle-project/Sparkle) (embedded as `Sparkle.framework`) | 2.9.1 | MIT, plus the external licenses Sparkle lists (bsdiff, sais-lite, ed25519, SUSignatureVerifier) | Andy Matuschak, Elgato Systems GmbH, Kornel Lesiński, Mayur Pawashe, C.W. Betts, Petroules Corporation, Big Nerd Ranch, and the authors named in the file | `licenses/sparkle-LICENSE.txt` |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (statically linked, plus `SwiftTerm_SwiftTerm.bundle`) | revision `86456ca32aaa81cadb4ca8dbe8be4546ffbccd18` (no release tag) | MIT | Miguel de Icaza; xterm.js authors; SourceLair Private Company; Christopher Jeffrey | `licenses/swiftterm-LICENSE.txt` |

`swift-argument-parser` 1.7.1 (Apache-2.0) appears in `Package.resolved` only because SwiftTerm's `Termcast` executable uses it. Picky links neither that executable nor the library, so it is not distributed.

## 2. Bundled font

### Symbols Nerd Font Mono (`SymbolsNerdFontMono-Regular.ttf`)

[Nerd Fonts](https://github.com/ryanoasis/nerd-fonts) "Symbols Only" font, release 3.4.0, copyright (c) 2016 Ryan McIntyre. Nerd Fonts lists this font as MIT. The font file is a patched collection of icon sets with their own licenses:

| Glyph set | License |
| --- | --- |
| Codicons | CC BY 4.0 |
| Devicons | MIT |
| Font Awesome (the CC 4.0 icons) | CC BY 4.0 |
| Font Awesome Extension | MIT |
| Font Logos | Unlicensed |
| IEC Power Symbols | MIT |
| Material Design Icons | Apache-2.0 |
| Seti-UI (modified, "Original Source") | MIT |
| Octicons | MIT |
| Pomicons | SIL OFL 1.1 |
| Powerline Extra Symbols | MIT |
| Powerline Symbols | Free License |
| Weather Icons | SIL OFL 1.1 |

Source: Nerd Fonts `license-audit.md` at tag v3.4.0. CC BY 4.0 glyphs (Codicons, Font Awesome) are shared here under <https://creativecommons.org/licenses/by/4.0/>, and the font was changed by the Nerd Fonts patcher. Full texts: `licenses/nerd-fonts-LICENSE.md` (MIT and SIL OFL 1.1), `licenses/nerd-fonts-license-audit.md`, and `Picky/Resources/Fonts/NerdFontsSymbolsOnly-LICENSE.txt` (the copy shipped next to the font).

## 3. Bundled runtime

| Component | Version | License | Full text |
| --- | --- | --- | --- |
| [Node.js](https://nodejs.org) (`Contents/Resources/agentd-runtime/bin/node`, darwin-arm64 build from nodejs.org) | 24.18.1 (pinned by `agentd/package.json#engines.node`) | MIT. Node's license file also lists the licenses of the components compiled into the binary (V8, OpenSSL, ICU, zlib, and others). | `licenses/node-LICENSE.txt` |
| [npm](https://github.com/npm/cli) CLI (`Contents/Resources/agentd-runtime/lib/node_modules/npm`) | 11.16.0 (the version inside Node 24.18.1) | Artistic-2.0 | `licenses/npm-LICENSE.txt` |

npm ships its own bundled dependencies under `agentd-runtime/lib/node_modules/npm/node_modules/`. Each keeps its license file in its own folder.

## 4. Pi runtime and Picky-owned ports

- The Pi SDK and CLI (`@earendil-works/pi-ai`, `pi-coding-agent`, `pi-tui` and their `@earendil-works` dependencies) are MIT, copyright (c) 2025 Mario Zechner (<https://github.com/earendil-works/pi>). The published packages carry no license file, so the text in `licenses/npm-packages.txt` is the upstream repository's `LICENSE`.
- Picky applies `patches/pi-coding-agent@1.1.0.patch` to `@earendil-works/pi-coding-agent` 1.1.0. It makes an abort that arrives while the working-directory check is pending stop the bash tool instead of running the command.
- `@ryan_nookpi/pi-extension-bash-async` 0.2.4 and `@ryan_nookpi/pi-extension-subagent` 0.5.9 are vendored under `agentd/vendor/async-task-providers/` with a local timing patch (see `PROVENANCE.txt` there). Both are MIT, copyright (c) 2026 Jonghak Seo.
- The built-in Task engine under `agentd/src/runtime/task/` is a port of `@ryan_nookpi/pi-extension-task` 0.0.1, MIT, copyright (c) 2026 Jonghak Seo. The license text is in `agentd/src/runtime/task/PROVENANCE.md`.

## 5. msedge-tts 2.0.7

Picky's optional Edge TTS adapter uses [msedge-tts](https://github.com/Migushthe2nd/MsEdgeTTS), copyright Migushthe2nd and contributors.

Licensed under the MIT License. The package's complete license text is in `licenses/npm-packages.txt` and ships with the dependency at `agentd/node_modules/msedge-tts/LICENSE`.

Picky applies `patches/msedge-tts@2.0.7.patch`, a small reliability patch that propagates initial speech-config and synthesis WebSocket send failures to the package's returned Promise or audio stream. This prevents an unhandled Node rejection from terminating the local daemon before Picky can use its macOS Speech fallback.

## 6. npm packages inside the app

Full license and notice texts for every package below are in `licenses/npm-packages.txt`.

### Proprietary components

`@anthropic-ai/claude-agent-sdk` and `@anthropic-ai/claude-agent-sdk-darwin-arm64` 0.2.141 are not open source. They are copyright Anthropic PBC, "All rights reserved. Use is subject to the Legal Agreements outlined here: <https://code.claude.com/docs/en/legal-and-compliance>". The darwin-arm64 package contains the native `claude` executable. They ship only in the async provider capsule (`Contents/Resources/agentd/async-task-providers`).

### Other notes

- `standardwebhooks` 1.1.1 declares MIT in its `package.json`, while its upstream repository `LICENSE` is Apache-2.0. Both texts are in `licenses/npm-packages.txt`.
- Some published packages ship no license file: the `@earendil-works/*` packages, `@esbuild/darwin-arm64`, three `@aws-sdk/*` packages, `agent-base` 6.0.2, `https-proxy-agent` 5.0.1, `proxy-agent-negotiate` 1.1.0, `data-uri-to-buffer` 4.0.1, and the vendored `bash-async` provider. `licenses/npm-packages.txt` states for each which source the text came from.
- Packages that appear in more than one place (the main runtime, the provider capsule, the phone web app) are listed once, with every place named.

### Package list

| Package | Version | License | Shipped in |
| --- | --- | --- | --- |
| @anthropic-ai/claude-agent-sdk-darwin-arm64 | 0.2.141 | Proprietary (Anthropic PBC; "SEE LICENSE IN LICENSE.md") | async provider capsule |
| @anthropic-ai/claude-agent-sdk | 0.2.141 | Proprietary (Anthropic PBC; "SEE LICENSE IN README.md") | async provider capsule |
| @anthropic-ai/sdk | 0.129.0 | MIT | agentd runtime |
| @anthropic-ai/sdk | 0.93.0 | MIT | async provider capsule |
| @aws-sdk/client-bedrock-runtime | 3.1127.0 | Apache-2.0 | agentd runtime |
| @aws-sdk/core | 3.978.0 | Apache-2.0 | agentd runtime |
| @aws-sdk/credential-provider-env | 3.972.71 | Apache-2.0 | agentd runtime |
| @aws-sdk/credential-provider-http | 3.972.73 | Apache-2.0 | agentd runtime |
| @aws-sdk/credential-provider-ini | 3.973.16 | Apache-2.0 | agentd runtime |
| @aws-sdk/credential-provider-login | 3.972.78 | Apache-2.0 | agentd runtime |
| @aws-sdk/credential-provider-node | 3.972.83 | Apache-2.0 | agentd runtime |
| @aws-sdk/credential-provider-process | 3.972.71 | Apache-2.0 | agentd runtime |
| @aws-sdk/credential-provider-sso | 3.973.15 | Apache-2.0 | agentd runtime |
| @aws-sdk/credential-provider-web-identity | 3.972.77 | Apache-2.0 | agentd runtime |
| @aws-sdk/eventstream-handler-node | 3.972.34 | Apache-2.0 | agentd runtime |
| @aws-sdk/middleware-eventstream | 3.972.29 | Apache-2.0 | agentd runtime |
| @aws-sdk/middleware-websocket | 3.972.53 | Apache-2.0 | agentd runtime |
| @aws-sdk/nested-clients | 3.997.45 | Apache-2.0 | agentd runtime |
| @aws-sdk/signature-v4-multi-region | 3.996.46 | Apache-2.0 | agentd runtime |
| @aws-sdk/token-providers | 3.1127.0 | Apache-2.0 | agentd runtime |
| @aws-sdk/token-providers | 3.1129.0 | Apache-2.0 | agentd runtime |
| @aws-sdk/types | 3.974.5 | Apache-2.0 | agentd runtime |
| @aws-sdk/xml-builder | 3.972.40 | Apache-2.0 | agentd runtime |
| @aws/lambda-invoke-store | 0.3.0 | Apache-2.0 | agentd runtime |
| @babel/runtime | 7.29.7 | MIT | agentd runtime, async provider capsule |
| @earendil-works/chord | 1.1.0 | MIT | agentd runtime |
| @earendil-works/pi-agent-core | 1.1.0 | MIT | agentd runtime |
| @earendil-works/pi-ai | 1.1.0 | MIT | agentd runtime |
| @earendil-works/pi-codemode | 1.1.0 | MIT | agentd runtime |
| @earendil-works/pi-coding-agent | 1.1.0 | MIT | agentd runtime |
| @earendil-works/pi-mcp | 1.1.0 | MIT | agentd runtime |
| @earendil-works/pi-telemetry | 1.1.0 | MIT | agentd runtime |
| @earendil-works/pi-tui | 1.1.0 | MIT | agentd runtime |
| @esbuild/darwin-arm64 | 0.28.2 | MIT | agentd runtime |
| @google/genai | 2.21.0 | Apache-2.0 | agentd runtime |
| @hono/node-server | 2.1.1 | MIT | async provider capsule |
| @modelcontextprotocol/sdk | 1.30.1 | MIT | async provider capsule |
| @preact/signals-core | 1.14.4 | MIT | phone web app bundle |
| @preact/signals | 2.11.3 | MIT | phone web app bundle |
| @protobufjs/aspromise | 1.1.2 | BSD-3-Clause | agentd runtime |
| @protobufjs/base64 | 1.1.2 | BSD-3-Clause | agentd runtime |
| @protobufjs/codegen | 2.0.5 | BSD-3-Clause | agentd runtime |
| @protobufjs/eventemitter | 1.1.1 | BSD-3-Clause | agentd runtime |
| @protobufjs/fetch | 1.1.1 | BSD-3-Clause | agentd runtime |
| @protobufjs/float | 1.0.2 | BSD-3-Clause | agentd runtime |
| @protobufjs/path | 1.1.2 | BSD-3-Clause | agentd runtime |
| @protobufjs/pool | 1.1.0 | BSD-3-Clause | agentd runtime |
| @protobufjs/utf8 | 1.1.2 | BSD-3-Clause | agentd runtime |
| @ryan_nookpi/pi-extension-bash-async | 0.2.4 | MIT | async provider capsule (vendored source) |
| @ryan_nookpi/pi-extension-subagent | 0.5.9 | MIT | async provider capsule (vendored source) |
| @silvia-odwyer/photon-node | 0.3.4 | Apache-2.0 | agentd runtime |
| @smithy/core | 3.34.1 | Apache-2.0 | agentd runtime |
| @smithy/credential-provider-imds | 4.5.2 | Apache-2.0 | agentd runtime |
| @smithy/fetch-http-handler | 5.8.0 | Apache-2.0 | agentd runtime |
| @smithy/node-http-handler | 4.12.1 | Apache-2.0 | agentd runtime |
| @smithy/signature-v4 | 5.7.3 | Apache-2.0 | agentd runtime |
| @smithy/types | 4.18.0 | Apache-2.0 | agentd runtime |
| @stablelib/base64 | 1.0.1 | MIT | agentd runtime |
| @types/node | 24.13.3 | MIT | agentd runtime |
| @types/retry | 0.12.0 | MIT | agentd runtime |
| accepts | 2.0.0 | MIT | async provider capsule |
| agent-base | 6.0.2 | MIT | agentd runtime |
| agent-base | 7.1.4 | MIT | agentd runtime |
| agent-base | 9.0.0 | MIT | agentd runtime |
| ajv-formats | 3.0.1 | MIT | async provider capsule |
| ajv | 8.20.0 | MIT | async provider capsule |
| asynckit | 0.4.0 | MIT | agentd runtime |
| axios | 1.18.1 | MIT | agentd runtime |
| balanced-match | 4.0.4 | MIT | agentd runtime |
| base64-js | 1.5.1 | MIT | agentd runtime |
| bignumber.js | 9.3.1 | MIT | agentd runtime |
| body-parser | 2.3.0 | MIT | async provider capsule |
| bowser | 2.14.1 | MIT | agentd runtime |
| brace-expansion | 5.0.12 | MIT | agentd runtime |
| buffer-equal-constant-time | 1.0.1 | BSD-3-Clause | agentd runtime |
| buffer | 6.0.3 | MIT | agentd runtime |
| bytes | 3.1.2 | MIT | async provider capsule |
| call-bind-apply-helpers | 1.0.2 | MIT | agentd runtime, async provider capsule |
| call-bound | 1.0.4 | MIT | async provider capsule |
| chalk | 6.0.0 | MIT | agentd runtime |
| combined-stream | 1.0.8 | MIT | agentd runtime |
| commander | 14.0.3 | MIT | agentd runtime |
| content-disposition | 1.1.0 | MIT | async provider capsule |
| content-type | 1.0.5 | MIT | async provider capsule |
| content-type | 2.1.0 | MIT | async provider capsule |
| cookie-signature | 1.2.2 | MIT | async provider capsule |
| cookie | 0.7.2 | MIT | async provider capsule |
| cors | 2.8.6 | MIT | async provider capsule |
| cross-spawn | 7.0.6 | MIT | agentd runtime, async provider capsule |
| data-uri-to-buffer | 4.0.1 | MIT | agentd runtime |
| debug | 4.4.3 | MIT | agentd runtime, async provider capsule |
| delayed-stream | 1.0.0 | MIT | agentd runtime |
| depd | 2.0.0 | MIT | async provider capsule |
| diff | 8.0.4 | BSD-3-Clause | agentd runtime |
| dunder-proto | 1.0.1 | MIT | agentd runtime, async provider capsule |
| ecdsa-sig-formatter | 1.0.11 | Apache-2.0 | agentd runtime |
| ee-first | 1.1.1 | MIT | async provider capsule |
| encodeurl | 2.0.0 | MIT | async provider capsule |
| es-define-property | 1.0.1 | MIT | agentd runtime, async provider capsule |
| es-errors | 1.3.0 | MIT | agentd runtime, async provider capsule |
| es-object-atoms | 1.1.2 | MIT | agentd runtime, async provider capsule |
| es-set-tostringtag | 2.1.0 | MIT | agentd runtime |
| esbuild | 0.28.2 | MIT | agentd runtime |
| escape-html | 1.0.3 | MIT | async provider capsule |
| etag | 1.8.1 | MIT | async provider capsule |
| eventsource-parser | 3.1.1 | MIT | async provider capsule |
| eventsource | 3.0.7 | MIT | async provider capsule |
| express-rate-limit | 8.7.0 | MIT | async provider capsule |
| express | 5.2.1 | MIT | async provider capsule |
| extend | 3.0.2 | MIT | agentd runtime |
| fast-deep-equal | 3.1.3 | MIT | async provider capsule |
| fast-sha256 | 1.3.0 | Unlicense | agentd runtime |
| fast-uri | 3.1.8 | BSD-3-Clause | async provider capsule |
| fetch-blob | 3.2.0 | MIT | agentd runtime |
| finalhandler | 2.1.1 | MIT | async provider capsule |
| follow-redirects | 1.16.0 | MIT | agentd runtime |
| form-data | 4.0.6 | MIT | agentd runtime |
| formdata-polyfill | 4.0.10 | MIT | agentd runtime |
| forwarded | 0.2.0 | MIT | async provider capsule |
| fresh | 2.0.0 | MIT | async provider capsule |
| function-bind | 1.1.2 | MIT | agentd runtime, async provider capsule |
| gaxios | 7.3.0 | Apache-2.0 | agentd runtime |
| gcp-metadata | 8.1.2 | Apache-2.0 | agentd runtime |
| get-east-asian-width | 1.6.0 | MIT | agentd runtime |
| get-intrinsic | 1.3.0 | MIT | agentd runtime, async provider capsule |
| get-proto | 1.0.1 | MIT | agentd runtime, async provider capsule |
| google-auth-library | 10.9.1 | Apache-2.0 | agentd runtime |
| google-logging-utils | 1.1.3 | Apache-2.0 | agentd runtime |
| gopd | 1.2.0 | MIT | agentd runtime, async provider capsule |
| graceful-fs | 4.2.11 | ISC | agentd runtime |
| grok-mermaid | 0.2.3 | Apache-2.0 | agentd runtime |
| has-symbols | 1.1.0 | MIT | agentd runtime, async provider capsule |
| has-tostringtag | 1.0.2 | MIT | agentd runtime |
| hasown | 2.0.4 | MIT | agentd runtime, async provider capsule |
| highlight.js | 10.7.3 | BSD-3-Clause | agentd runtime |
| hono | 4.13.9 | MIT | async provider capsule |
| hosted-git-info | 9.0.3 | ISC | agentd runtime |
| http-errors | 2.0.1 | MIT | async provider capsule |
| http-proxy-agent | 9.1.0 | MIT | agentd runtime |
| https-proxy-agent | 5.0.1 | MIT | agentd runtime |
| https-proxy-agent | 7.0.6 | MIT | agentd runtime |
| https-proxy-agent | 9.1.0 | MIT | agentd runtime |
| iconv-lite | 0.7.3 | MIT | async provider capsule |
| ieee754 | 1.2.1 | BSD-3-Clause | agentd runtime |
| ignore | 7.0.8 | MIT | agentd runtime |
| inherits | 2.0.4 | ISC | agentd runtime, async provider capsule |
| ip-address | 10.7.2 | MIT | async provider capsule |
| ipaddr.js | 1.9.1 | MIT | async provider capsule |
| is-promise | 4.0.0 | MIT | async provider capsule |
| isexe | 2.0.0 | ISC | agentd runtime, async provider capsule |
| isomorphic-ws | 5.0.0 | MIT | agentd runtime |
| jiti | 2.7.0 | MIT | agentd runtime |
| jose | 6.2.12 | MIT | async provider capsule |
| json-bigint | 1.0.0 | MIT | agentd runtime |
| json-schema-to-ts | 3.1.1 | MIT | agentd runtime, async provider capsule |
| json-schema-traverse | 1.0.0 | MIT | async provider capsule |
| json-schema-typed | 8.0.2 | BSD-2-Clause | async provider capsule |
| jsonrepair | 3.15.0 | ISC | agentd runtime |
| jsqr | 1.4.0 | Apache-2.0 | phone web app bundle |
| jwa | 2.0.1 | MIT | agentd runtime |
| jws | 4.0.1 | MIT | agentd runtime |
| long | 5.3.2 | Apache-2.0 | agentd runtime |
| lru-cache | 11.5.2 | BlueOak-1.0.0 | agentd runtime |
| marked | 18.0.11 | MIT | agentd runtime, phone web app bundle |
| math-intrinsics | 1.1.0 | MIT | agentd runtime, async provider capsule |
| media-typer | 1.1.1 | MIT | async provider capsule |
| merge-descriptors | 2.0.0 | MIT | async provider capsule |
| mime-db | 1.52.0 | MIT | agentd runtime |
| mime-db | 1.54.0 | MIT | async provider capsule |
| mime-types | 2.1.35 | MIT | agentd runtime |
| mime-types | 3.0.2 | MIT | async provider capsule |
| minimatch | 10.2.6 | BlueOak-1.0.0 | agentd runtime |
| ms | 2.1.3 | MIT | agentd runtime, async provider capsule |
| msedge-tts | 2.0.7 | MIT | agentd runtime |
| negotiator | 1.1.0 | MIT | async provider capsule |
| node-domexception | 1.0.0 | MIT | agentd runtime |
| node-fetch | 3.3.2 | MIT | agentd runtime |
| object-assign | 4.1.1 | MIT | async provider capsule |
| object-inspect | 1.13.4 | MIT | async provider capsule |
| on-finished | 2.4.1 | MIT | async provider capsule |
| once | 1.4.0 | ISC | async provider capsule |
| openai | 7.19.0 | Apache-2.0 | agentd runtime |
| p-retry | 4.6.2 | MIT | agentd runtime |
| parseurl | 1.3.3 | MIT | async provider capsule |
| partial-json | 0.1.7 | MIT | agentd runtime |
| path-key | 3.1.1 | MIT | agentd runtime, async provider capsule |
| path-to-regexp | 8.4.2 | MIT | async provider capsule |
| pkce-challenge | 5.0.1 | MIT | async provider capsule |
| preact | 10.29.8 | MIT | phone web app bundle |
| proper-lockfile | 4.1.2 | MIT | agentd runtime |
| protobufjs | 7.6.5 | BSD-3-Clause | agentd runtime |
| proxy-addr | 2.0.8 | MIT | async provider capsule |
| proxy-agent-negotiate | 1.1.0 | MIT | agentd runtime |
| proxy-from-env | 2.1.0 | MIT | agentd runtime |
| qs | 6.16.0 | BSD-3-Clause | async provider capsule |
| quickjs-wasi | 3.6.2 | MIT | agentd runtime |
| range-parser | 1.3.0 | MIT | async provider capsule |
| raw-body | 3.0.2 | MIT | async provider capsule |
| readable-stream | 3.6.2 | MIT | agentd runtime |
| require-from-string | 2.0.2 | MIT | async provider capsule |
| retry | 0.12.0 | MIT | agentd runtime |
| retry | 0.13.1 | MIT | agentd runtime |
| router | 2.2.0 | MIT | async provider capsule |
| safe-buffer | 5.2.1 | MIT | agentd runtime |
| safer-buffer | 2.1.2 | MIT | async provider capsule |
| semver | 7.8.5 | ISC | agentd runtime |
| send | 1.2.1 | MIT | async provider capsule |
| serve-static | 2.2.1 | MIT | async provider capsule |
| setprototypeof | 1.2.0 | ISC | async provider capsule |
| shebang-command | 2.0.0 | MIT | agentd runtime, async provider capsule |
| shebang-regex | 3.0.0 | MIT | agentd runtime, async provider capsule |
| side-channel-list | 1.0.1 | MIT | async provider capsule |
| side-channel-map | 1.0.1 | MIT | async provider capsule |
| side-channel-weakmap | 1.0.2 | MIT | async provider capsule |
| side-channel | 1.1.1 | MIT | async provider capsule |
| signal-exit | 3.0.7 | ISC | agentd runtime |
| standardwebhooks | 1.1.1 | MIT per package.json; upstream repository LICENSE is Apache-2.0 | agentd runtime |
| statuses | 2.0.2 | MIT | async provider capsule |
| stream-browserify | 3.0.0 | MIT | agentd runtime |
| string_decoder | 1.3.0 | MIT | agentd runtime |
| toidentifier | 1.0.1 | MIT | async provider capsule |
| ts-algebra | 2.0.0 | MIT | agentd runtime, async provider capsule |
| tslib | 2.8.1 | 0BSD | agentd runtime |
| type-is | 2.1.0 | MIT | async provider capsule |
| typebox | 1.3.27 | MIT | agentd runtime |
| typebox | 1.3.7 | MIT | agentd runtime |
| undici-types | 7.18.2 | MIT | agentd runtime |
| undici | 8.10.2 | MIT | agentd runtime |
| unpipe | 1.0.0 | MIT | async provider capsule |
| util-deprecate | 1.0.2 | MIT | agentd runtime |
| vary | 1.1.2 | MIT | async provider capsule |
| web-streams-polyfill | 3.3.3 | MIT | agentd runtime |
| which | 2.0.2 | ISC | agentd runtime, async provider capsule |
| wrappy | 1.0.2 | ISC | async provider capsule |
| ws | 8.22.0 | MIT | agentd runtime |
| yaml | 2.9.0 | ISC | agentd runtime, async provider capsule |
| zod-to-json-schema | 3.25.2 | ISC | async provider capsule |
| zod | 4.4.3 | MIT | async provider capsule |
| zod | 4.6.5 | MIT | agentd runtime |

## 7. Names and logos of other companies

The service logos in the app's asset catalog (Figma, GitHub, Google Docs, Drive, Sheets and Slides, Jira, Linear, Notion, Sentry, Slack, Claude and OpenAI) identify those products in the UI. They are trademarks of their owners. Picky is not affiliated with or endorsed by them. Their use is covered by each owner's brand guidelines, not by the licenses above.
