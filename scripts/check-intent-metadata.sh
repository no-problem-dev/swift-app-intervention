#!/bin/bash
# Checks that an intent's App Intents metadata really declares background → foreground.
#
#   usage: scripts/check-intent-metadata.sh [--app <Foo.app>] [--intent <Identifier>]... [--expected N]
#          With no --app, builds Examples/InterventionSample and checks PauseBeforeOpeningIntent.
#   needs: jq (brew install jq); xcodegen only when building the sample.
#
# From a host app that depends on this package through Xcode, the script is at
#   <DerivedData>/<Project>/SourcePackages/checkouts/swift-app-intervention/scripts/check-intent-metadata.sh
# (or copy it into your repository). Run it on the built .app, e.g. in a build phase or CI:
#   check-intent-metadata.sh --app "$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME" --intent PauseBeforeOpeningIntent
#
# Why (design review B-M1, reproduced with a negative control):
#   `static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]` written as a
#   literal is extracted as `supportedModes: 9` in Metadata.appintents/extract.actionsdata.
#   The same value through a constant from a package is extracted as `1` (background only), with
#   no warning, and continueInForeground can then never bring the app forward. Build and tests
#   pass either way, so this file is the only place the mistake shows.
#   9 = background (1) | foreground(.dynamic) (8).

set -eo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP=""
INTENTS=()
EXPECTED=9
SIM="${QA_SIM:-iPhone 17e}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --intent) INTENTS+=("$2"); shift 2 ;;
    --expected) EXPECTED="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "✗ jq is required (brew install jq)" >&2; exit 2; }

if [[ -z "$APP" ]]; then
  SAMPLE="$REPO/Examples/InterventionSample"
  DERIVED="$REPO/.build/sample"
  (cd "$SAMPLE" && xcodegen generate --quiet)
  # Same destination and DerivedData as `make sample` / `make qa`, so builds stay incremental.
  xcodebuild -project "$SAMPLE/InterventionSample.xcodeproj" -scheme InterventionSample \
    -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO build -quiet 2>&1 | { grep -v "IDERunDestination" || true; }
  APP="$DERIVED/Build/Products/Debug-iphonesimulator/InterventionSample.app"
  [[ ${#INTENTS[@]} -eq 0 ]] && INTENTS=(PauseBeforeOpeningIntent)
fi

DATA="$APP/Metadata.appintents/extract.actionsdata"
[[ -f "$DATA" ]] || { echo "✗ no metadata at $DATA" >&2; exit 1; }
[[ ${#INTENTS[@]} -gt 0 ]] || { echo "pass at least one --intent" >&2; exit 2; }

FAILED=0
for intent in "${INTENTS[@]}"; do
  modes=$(jq -r --arg id "$intent" '.actions[$id].supportedModes // "missing"' "$DATA")
  if [[ "$modes" == "$EXPECTED" ]]; then
    echo "✓ ${intent} supportedModes=${modes}"
  else
    echo "✗ ${intent} supportedModes=${modes} (expected ${EXPECTED}; write supportedModes as a literal in the intent's own file)" >&2
    FAILED=1
  fi
done
exit $FAILED
