# anti-slop (vendored subset)

Upstream: https://github.com/dmmulroy/anti-slop
Revision: `c44ef22ca116d0ba62a3ff663a0bd13a3f3fa40b`
License: MIT (`LICENSE`)

Copied unchanged from upstream `src/`:

- `rules/no-chained-type-assertions.ts` (+ test)
- `rules/no-module-mocking.ts` (+ test)
- `rules/no-widen-then-assert.ts` (+ test)
- `shared/scope.ts`

Upstream `*.test.ts` files are renamed to `*.rule-test.ts`: they run under `tsx` with Oxlint's
`RuleTester`, and the `.test.ts` suffix would make Vitest collect them as empty suites.

`index.ts` is local: it registers only the rules above. The vendored files are ours to
maintain. When pulling upstream changes, diff against the revision above instead of
replacing the directory.

Run the rule tests with `pnpm --dir agentd run test:lint-rules`.
