#!/usr/bin/env bash
# Phase 1-d feature slice co-change measurement (see ARCHITECTURE.md §12.1).
#
# The question this answers is not "how many directories did a commit touch" but
# "did changing one Hub feature stay inside that feature". So every commit is
# judged individually:
#
#   slice     which feature slice the commit belongs to (2+ slices is not closed)
#   outside   agentd files the commit touched outside that slice's own paths
#   protocol  touched agentd/src/protocol.ts
#   server    touched agentd/src/server.ts
#   swift     touched Picky/Protocol/ (the wire contract's other half)
#   closed    one slice, nothing outside it, and none of the three above
#
# Usage:
#   scripts/measure-slice-cochange.sh                             # post-split window (default)
#   SINCE=2026-07-06 UNTIL=2026-10-04 scripts/measure-slice-cochange.sh   # the recorded baseline
#   EXCLUDE="<sha> <sha>" scripts/measure-slice-cochange.sh      # extra exclusions
#
# The default window starts at the split commit, so a re-run any number of weeks
# later measures only post-split work. A relative SINCE ("42 days ago") drifts
# with the run date and silently mixes pre-split commits back in.
set -euo pipefail

# Commits that are the restructuring itself, not a feature change being measured.
# Counting them would answer "how big was the move", which we already know.
#   4b4aed2e7 the Phase 1-d slice split
#   e357adf34 confining Pi SDK imports to runtime/ (11 renames, no feature change)
DEFAULT_EXCLUDE="4b4aed2e7230d2a5b46120323b29ed5d6f836dd9 e357adf34"

slice_paths() {
  case "$1" in
    settings) echo "agentd/src/features/settings agentd/src/application/settings-control-broker.ts" ;;
    package) echo "agentd/src/features/package agentd/src/runtime/package-operations.ts" ;;
    pi-oauth) echo "agentd/src/features/pi-oauth agentd/src/runtime/pi-oauth-service.ts" ;;
    hub) echo "agentd/src/features/hub agentd/src/runtime/mcp-server-admin.ts agentd/src/application/hub-statistics-service.ts" ;;
  esac
}

SLICES="settings package pi-oauth hub"
paths=()
for slice in $SLICES; do
  for path in $(slice_paths "$slice"); do paths+=("$path"); done
done

# Which slice owns a path, or empty when the file belongs to no slice.
owning_slice() {
  local file="$1" slice path base
  for slice in $SLICES; do
    for path in $(slice_paths "$slice"); do
      case "$path" in
        *.ts)
          base="${path%.ts}"
          # A file's own test file is part of the same unit of change.
          if [ "$file" = "$path" ] || [ "$file" = "${base}.test.ts" ]; then
            echo "$slice"
            return 0
          fi
          ;;
        *) case "$file" in "$path"/*) echo "$slice"; return 0 ;; esac ;;
      esac
    done
  done
  return 0
}

# Abbreviated SHAs are accepted; compare against full ones.
excluded=" "
for entry in $DEFAULT_EXCLUDE ${EXCLUDE:-}; do
  excluded="$excluded$(git rev-parse "$entry") "
done
SPLIT_COMMIT=4b4aed2e7230d2a5b46120323b29ed5d6f836dd9
since="${SINCE:-$(git show -s --format=%cI "$SPLIT_COMMIT")}"
commits=$(git log --since="$since" ${UNTIL:+--until="$UNTIL"} --format=%H -- "${paths[@]}")
if [ -n "${SINCE:-}" ] && [ -n "$(git log --since="$SINCE" ${UNTIL:+--until="$UNTIL"} --format=%H -1 "$SPLIT_COMMIT")" ]; then
  echo "note: this window reaches back past the split commit; commits before it are pre-split work" >&2
fi

total=0
closed_count=0
both=0
dirsum=0
skipped=0
for commit in $commits; do
  case "$excluded" in *" $commit "*) skipped=$((skipped + 1)); continue ;; esac
  files=$(git show --pretty=format: --name-only "$commit" | sed '/^$/d' | sort -u)
  dirs=$(printf '%s\n' "$files" | xargs -n1 dirname | sort -u | wc -l | tr -d ' ')

  touched_slices=""
  outside=0
  protocol=no
  server=no
  swift=no
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    case "$file" in
      agentd/src/protocol.ts) protocol=yes; continue ;;
      agentd/src/server.ts) server=yes; continue ;;
      # Both the current folder and the pre-move `Picky/Picky*Protocol.swift`.
      Picky/Protocol/* | Picky/Picky*Protocol.swift) swift=yes; continue ;;
    esac
    slice=$(owning_slice "$file")
    if [ -n "$slice" ]; then
      case " $touched_slices " in *" $slice "*) ;; *) touched_slices="$touched_slices $slice" ;; esac
    elif [ "${file#agentd/}" != "$file" ]; then
      outside=$((outside + 1))
    fi
  done <<EOF
$files
EOF

  slice_count=$(printf '%s\n' $touched_slices | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$slice_count" = "1" ] && [ "$outside" = "0" ] && [ "$protocol" = "no" ] && [ "$server" = "no" ] && [ "$swift" = "no" ]; then
    closed=yes
    closed_count=$((closed_count + 1))
  else
    closed=no
  fi
  if [ "$protocol" = "yes" ] && [ "$server" = "yes" ]; then both=$((both + 1)); fi

  total=$((total + 1))
  dirsum=$((dirsum + dirs))
  printf '%s %-54s slice=%-18s outside=%s protocol=%s server=%s swift=%s closed=%s dirs=%s\n' \
    "${commit:0:9}" "$(git log -1 --format=%s "$commit" | cut -c1-54)" \
    "$(printf '%s' "${touched_slices# }" | tr ' ' ',')${touched_slices:+ }" \
    "$outside" "$protocol" "$server" "$swift" "$closed" "$dirs"
done

echo "---"
echo "commits=$total (excluded=$skipped)  closed=$closed_count  protocol+server_both=$both  avg_dirs=$(awk "BEGIN{printf \"%.1f\", $dirsum/($total==0?1:$total)}") (reference only)"
if [ "$total" -lt 5 ]; then
  echo "verdict=inconclusive — only $total measurable commit(s); need at least 5 before judging the pilot"
else
  echo "verdict=$(awk "BEGIN{printf \"%.0f\", 100*$closed_count/$total}")% closed, $(awk "BEGIN{printf \"%.0f\", 100*$both/$total}")% changed protocol.ts and server.ts together"
fi
