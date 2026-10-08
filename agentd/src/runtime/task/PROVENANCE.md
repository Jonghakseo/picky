# Task engine provenance

This folder is Picky's built-in Task engine. It started as a port of the standalone Pi extension and
is now maintained only here; the npm package is no longer the source of truth.

- Package: `@ryan_nookpi/pi-extension-task@0.0.1`
- Source repository: https://github.com/Jonghakseo/pi-extension (`packages/task`)
- Source revision reviewed: `6fa1b45eb1c5b5ce3f2df7b49bd235e8782dbfc1` (package commit `43f91dc`)
- npm integrity: `sha512-V8+GecKbgaXJ67hIz5H3kX5O71rU4UyF3m69cuh9Ls8SElnDc7XN/vjqIrNvujWfuEWYvwWwO3b8BpgM8H3TxQ==`
- Product decision: [`docs/picky-task-routing-plan.md`](../../../../docs/picky-task-routing-plan.md)

## Contracts kept

- The concurrency queue, the synchronous revision fence on edit, and rejection of stale, foreign, or
  duplicate `task_report` results.
- One long-lived RPC worker per Task; an edit resumes the same process and child session, and an
  explicit resume after a restart reuses the saved child session.
- Only a validated `task_report` for the active revision completes a Task. A normal reply,
  `agent_end`, or `agent_settled` does not; an exit or model failure before a report is a failure.
- Recursive delegation (`Task`, `subagent`) is excluded at spawn and blocked by the bridge.
- Unattended dialogs in the worker are cancelled and reported, never auto-approved.
- The parent conversation snapshot with stable refs and the `task_context` recall tool.
- Model tier evaluation and the per-provider preset catalog.

## Contracts changed

- Storage: one Picky-owned store under the app support folder instead of a store partitioned by
  the parent Pi session ID, so compaction, a replaced main session, or a restart keep Tasks reachable.
- Each Task has its own working folder, a display title, and the request it came from.
- The snapshot leads with the original request, neutral desktop context, and attachment paths.
- A user stop shuts the worker down (`stopping` then `cancelled`, with confirmed or uncertain
  cleanup) instead of the model-only `abort`.
- Workers report `escalation: production_code` (as a block) when unapproved production code work
  appears; a Task the user chose over a Pickle is marked scope-approved and skips that rule.
- `pickle_delegation` joins the blocked recursive tools; worker env markers are `PICKY_TASK_*`.
- The worker always runs agentd's bundled Pi CLI. The installed-Pi fallback is gone.
- Routing configuration no longer reads Pi's `settings.json` `task` key or project `.pi/task.json`.
- Completion delivery, interruption notices, and Task control belong to Picky's main-agent service
  (`agentd/src/application/main-task-service.ts`), not to an extension `context` hook. The 30-minute
  model notice was dropped; the app shows elapsed time instead.

## License

The ported code is used under the original MIT license:

```text
MIT License

Copyright (c) 2026 Jonghak Seo

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
