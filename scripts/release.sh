#!/usr/bin/env bash
set -euo pipefail

# Picky does not yet have a notarized public release pipeline. The imported
# upstream release automation referenced the old app/repo and remote updater,
# so this script now delegates to the safe local signed package builder.
#
# For a local ad-hoc signed package:
#   ./scripts/release.sh
#
# For a Developer ID-signed package:
#   PICKY_CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
#   PICKY_DEVELOPMENT_TEAM="TEAMID" \
#   ./scripts/release.sh
#
# Notarization/DMG/appcast publishing should be added later as a separate,
# explicit pipeline once distribution requirements are finalized.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/package-signed-app.sh" "$@"
