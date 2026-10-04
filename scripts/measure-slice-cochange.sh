#!/usr/bin/env bash
# Phase 1-d feature slice co-change measurement (see ARCHITECTURE.md §12.1).
# Usage: scripts/measure-slice-cochange.sh   (SINCE="42 days ago" to narrow the window)
set -euo pipefail
paths=(
  agentd/src/features/settings agentd/src/features/package
  agentd/src/features/pi-oauth agentd/src/features/hub
  agentd/src/application/settings-control-broker.ts
  agentd/src/runtime/package-operations.ts
  agentd/src/runtime/pi-oauth-service.ts
  agentd/src/runtime/mcp-server-admin.ts
  agentd/src/application/hub-statistics-service.ts
)
commits=$(git log --since="${SINCE:-90 days ago}" --format=%H -- "${paths[@]}")
total=0; both=0; dirsum=0
for c in $commits; do
  files=$(git show --pretty=format: --name-only "$c" | sed '/^$/d')
  dirs=$(printf '%s\n' "$files" | xargs -n1 dirname | sort -u | wc -l | tr -d ' ')
  total=$((total+1)); dirsum=$((dirsum+dirs))
  if printf '%s\n' "$files" | grep -qx 'agentd/src/protocol.ts' && printf '%s\n' "$files" | grep -qx 'agentd/src/server.ts'; then both=$((both+1)); fi
  printf '%s %s dirs=%s\n' "${c:0:9}" "$(git log -1 --format=%s "$c" | cut -c1-54)" "$dirs"
done
echo "---"
echo "commits=$total  avg_dirs=$(awk "BEGIN{printf \"%.1f\", $dirsum/($total==0?1:$total)}")  protocol+server_both=$both ($(awk "BEGIN{printf \"%.0f\", 100*$both/($total==0?1:$total)}")%)"
