#!/bin/bash
# Builds the DocC site for GitHub Pages into ./_site (never ./docs: that folder holds the design
# notes and reviews, which must not be published).
#
# Built with `xcodebuild docbuild` for iOS rather than `swift package generate-documentation`
# on macOS, because a macOS build drops the iOS-only API (SystemAppReopener,
# UIKitPhoneDownEventSource, PhoneDownCapability.current). Fails on any DocC warning.

set -eo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DERIVED=.build/docbuild
PRODUCTS="$DERIVED/Build/Products/Debug-iphoneos"

LOG=$(mktemp)
xcodebuild docbuild -scheme AppIntervention-Package -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" >"$LOG" 2>&1 || { tail -30 "$LOG" >&2; exit 1; }
WARNINGS=$(grep -E "warning:" "$LOG" | grep -v "(in target" | grep -v "IDERunDestination" | sort -u || true)
if [[ -n "$WARNINGS" ]]; then
  echo "$WARNINGS" >&2
  echo "✗ DocC warnings" >&2
  exit 1
fi

rm -rf .build/docs-merged.doccarchive _site
xcrun docc merge \
  "$PRODUCTS/AppIntervention.doccarchive" "$PRODUCTS/AppInterventionIntents.doccarchive" \
  "$PRODUCTS/AppInterventionUI.doccarchive" "$PRODUCTS/AppInterventionFocus.doccarchive" \
  --output-path .build/docs-merged.doccarchive >/dev/null
xcrun docc process-archive transform-for-static-hosting .build/docs-merged.doccarchive \
  --output-path _site --hosting-base-path swift-app-intervention >/dev/null
echo "✓ docs built without warnings: _site"
