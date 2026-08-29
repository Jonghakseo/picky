#!/usr/bin/env bash
set -euo pipefail

# Reclaims temporary DerivedData directories left behind by parallel or
# subagent-driven xcodebuild runs (see AGENTS.md). Each abandoned directory
# holds ~1GB and leaves a permanent LaunchServices bundle record, so the
# bundle is unregistered before the directory is removed.

SCAN_ROOT="${PICKY_PRUNE_ROOT:-/private/tmp}"
KEEP_HOURS="${PICKY_PRUNE_KEEP_HOURS:-24}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
APPLY=0

usage() {
  cat <<'EOF'
Usage: prune-build-artifacts.sh [--apply] [--keep-hours N] [--root DIR]

Lists (default) or removes stale Picky DerivedData directories.

  --apply         perform the unregister + delete; without it, dry-run only
  --keep-hours N  protect directories modified within N hours (default 24)
  --root DIR      directory to scan (default /private/tmp)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --keep-hours) KEEP_HOURS="$2"; shift 2 ;;
    --root) SCAN_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -x "${LSREGISTER}" ]]; then
  echo "lsregister not found at ${LSREGISTER}" >&2
  exit 1
fi

# An in-flight build keeps touching its DerivedData, so the keep-hours mtime
# filter below already excludes it. Warn rather than refuse.
if pgrep -x xcodebuild >/dev/null 2>&1; then
  echo "note: xcodebuild is running; directories it touched are protected by --keep-hours" >&2
fi

candidates=()
while IFS= read -r dir; do
  [[ -d "${dir}/Build/Products" ]] && candidates+=("${dir}")
done < <(find "${SCAN_ROOT}" -maxdepth 1 -type d -name '*[Pp]icky*' \
  -mmin "+$((KEEP_HOURS * 60))" 2>/dev/null | sort)

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "nothing to prune under ${SCAN_ROOT} (keep-hours=${KEEP_HOURS})"
  exit 0
fi

echo "found ${#candidates[@]} stale DerivedData directories under ${SCAN_ROOT} (keep-hours=${KEEP_HOURS})"
total_kb=0
for dir in "${candidates[@]}"; do
  size_kb="$(du -sk "${dir}" | cut -f1)"
  total_kb=$((total_kb + size_kb))
  printf '  %6s MB  %s\n' "$((size_kb / 1024))" "${dir}"
done
printf 'total: %s GB\n' "$((total_kb / 1024 / 1024))"

if [[ ${APPLY} -eq 0 ]]; then
  echo "dry run; re-run with --apply to unregister and delete"
  exit 0
fi

removed=0
for dir in "${candidates[@]}"; do
  # -R descends into packages, which is required because Picky.app embeds
  # Sparkle's Updater.app and LaunchServices registers that separately.
  "${LSREGISTER}" -u -R "${dir}" >/dev/null 2>&1 || true
  rm -rf "${dir}"
  removed=$((removed + 1))
done

printf 'removed %s directories, reclaimed ~%s GB\n' "${removed}" "$((total_kb / 1024 / 1024))"
