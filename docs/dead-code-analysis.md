# Dead code analysis manual

This project needs two static-analysis tracks because the app is Swift/Xcode and the daemon is TypeScript/Node.

Official references:

- Periphery: <https://github.com/peripheryapp/periphery>
- Knip: <https://knip.dev>

## 1. Guardrails

1. Do not use auto-fix / auto-remove for the first pass.
   - Periphery has `--auto-remove`, but keep it off unless the candidate is already reviewed.
   - Knip has `--fix`, but keep it off unless the candidate is already reviewed.
2. Always run `git status --short` first and protect unrelated local changes.
3. Treat static-analysis output as candidates, not truth. Cross-check with `rg` before deletion.
4. Prefer this order:
   1. build/typecheck succeeds
   2. static scan produces candidates
   3. `rg` confirms no references
   4. remove the smallest safe unit
   5. rerun build/tests/static scan

## 2. Swift / Picky app

Install Periphery once:

```bash
brew install peripheryapp/periphery/periphery
```

Run the app build first. Periphery depends on a valid Xcode index, so a broken Swift build makes the result meaningless.

```bash
xcodebuild -project Picky.xcodeproj \
  -scheme Picky \
  -destination 'platform=macOS' \
  build
```

Then run Periphery with false-positive controls tuned for this app:

```bash
mkdir -p build/dead-code
periphery scan \
  --project Picky.xcodeproj \
  --schemes Picky \
  --targets Picky \
  --format json \
  --relative-results \
  --report-include 'Picky/**/*.swift' \
  --retain-swift-ui-previews \
  --retain-codable-properties \
  --retain-objc-accessible \
  --disable-redundant-public-analysis \
  --disable-update-check \
  -- \
  -destination 'platform=macOS' \
  > build/dead-code/periphery-picky.json
```

Why these options:

- `--report-include 'Picky/**/*.swift'`: report app code only, not generated/package noise.
- `--retain-swift-ui-previews`: avoid Preview-only SwiftUI false positives.
- `--retain-codable-properties`: many protocol/context structs are serialized across app/daemon boundaries.
- `--retain-objc-accessible`: AppKit selectors, delegates, and menu actions can be referenced dynamically.
- `--disable-redundant-public-analysis`: focus this pass on unused code, not access-level cleanup.

Summarize results:

```bash
python3 - <<'PY'
import json, collections, pathlib
p = pathlib.Path('build/dead-code/periphery-picky.json')
data = json.loads(p.read_text())
print('count', len(data))
print('by_kind', dict(collections.Counter(item.get('kind') for item in data)))
for item in data[:100]:
    print(f"- {item.get('kind')} {item.get('location')} {item.get('name')}: {item.get('description')}")
PY
```

Cross-check any candidate:

```bash
rg -n "CandidateSymbol" Picky PickyTests
```

Extra caution for Swift candidates:

- `@objc`, `#selector`, delegate methods, menu actions, and notification callbacks may be dynamic.
- `Codable` models may be used by JSON fixtures, persisted settings, or daemon protocol payloads.
- SwiftUI `View` fragments may be referenced through conditional builders and previews.

## 3. TypeScript / agentd

Use Knip for cross-file unused exports/files/dependencies, and `tsc` for local unused imports/locals.

Current local note: latest Knip may fail on Node `v22.11.0` due an `oxc-parser` native binding issue. `knip@5` worked in this environment.

### 3.1 Full source scan including tests

Create a temporary config and run it from the repo root:

```bash
mkdir -p build/dead-code
cat > build/dead-code/knip.agentd.all.json <<'JSON'
{
  "$schema": "https://unpkg.com/knip@5/schema.json",
  "entry": [
    "src/index.ts",
    "src/**/*.test.ts",
    "src/__tests__/**/*.ts"
  ],
  "project": [
    "src/**/*.ts"
  ],
  "ignore": [
    "dist/**",
    "build/**"
  ]
}
JSON

cd agentd
pnpm dlx knip@5 \
  -c ../build/dead-code/knip.agentd.all.json \
  --reporter json \
  --no-exit-code \
  --no-progress \
  > ../build/dead-code/knip-agentd-all.json
```

This is the best default for cleanup because test-only helpers are counted as live if tests import them.

### 3.2 Runtime-only scan

Use this when you want to distinguish production runtime code from test support code:

```bash
cat > build/dead-code/knip.agentd.runtime.json <<'JSON'
{
  "$schema": "https://unpkg.com/knip@5/schema.json",
  "entry": [
    "src/index.ts"
  ],
  "project": [
    "src/**/*.ts",
    "!src/**/*.test.ts",
    "!src/__tests__/**/*.ts"
  ],
  "ignore": [
    "dist/**",
    "build/**"
  ]
}
JSON

cd agentd
pnpm dlx knip@5 \
  -c ../build/dead-code/knip.agentd.runtime.json \
  --reporter json \
  --no-exit-code \
  --no-progress \
  > ../build/dead-code/knip-agentd-runtime.json
```

Do not use `--production` as the only signal in this repo without checking output carefully. With a minimal config it can under-resolve the daemon entry graph and misreport normal runtime dependencies as unused.

### 3.3 TypeScript compiler unused pass

```bash
cd agentd
pnpm exec tsc -p tsconfig.json \
  --noEmit \
  --noUnusedLocals \
  --noUnusedParameters
```

This catches local issues like unused imports that Knip may not prioritize.

## 4. Cross-check workflow for a candidate

For every candidate symbol:

```bash
rg -n "SymbolName" agentd/src pi-extensions
```

Then classify it:

- **Delete candidate**: no references except its own declaration and tests are not relying on it.
- **Unexport candidate**: used only inside the same file. Remove `export`, not the implementation.
- **Keep candidate**: protocol/schema/public API, dynamic extension hook, or future-facing boundary type.
- **Needs owner decision**: code is unused today but represents an intentional planned feature.

After cleanup:

```bash
cd agentd
pnpm run typecheck
pnpm test
pnpm dlx knip@5 -c ../build/dead-code/knip.agentd.all.json --reporter compact --no-progress --no-exit-code
```

## 5. 2026-05-09 baseline observations

- Swift build succeeded after retest.
- Periphery with the tuned command reported `0` Picky Swift unused-code candidates.
- Knip found no unused TypeScript files.
- Strong TypeScript cleanup candidates were:
  - unused test import in `agentd/src/runtime/pi-sdk-runtime.test.ts`
  - unused `PiQuickTaskRouter` implementation in `agentd/src/task-router.ts`
  - same-file-only export `hasActiveTools` in `agentd/src/domain/tool-activity.ts`
