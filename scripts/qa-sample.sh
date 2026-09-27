#!/bin/bash
# Scripted QA pass of Examples/InterventionSample on a simulator.
# The same commands also work one at a time by hand:
#   xcrun simctl openurl booted 'interventionsample://qa/run?app=instagram&fg=succeed'
# (the Simulator then asks "Open in …?" once per URL).
#
#   usage: scripts/qa-sample.sh            (QA_SIM="iPhone 17e" by default)
#
# Boots the simulator, builds the sample into the single DerivedData path (.build/sample, the
# same destination `make sample` uses, so nothing flip-flops), launches it with the DEBUG QA
# arguments, drives it through the QA commands (-qa-script), saves a
# screenshot after every step to .build/qa-shots/<timestamp>/ (gitignored), and checks the
# `[QA]` lines the app prints.
#
# What this cannot show: the real Shortcuts automation, the real foreground switch, lock
# signals. Those are device-gate items (docs/DESIGN.md §10).

set -eo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="${QA_SIM:-iPhone 17e}"
BUNDLE="dev.noproblem.appintervention.InterventionSample"
OUT="$REPO/.build/qa-shots/$(date +%Y%m%d-%H%M%S)"
APP="$REPO/.build/sample/Build/Products/Debug-iphonesimulator/InterventionSample.app"
mkdir -p "$OUT"

UDID=$(xcrun simctl list devices available -j | jq -r --arg n "$SIM" '[.devices[][] | select(.name == $n)][0].udid // empty')
[[ -n "$UDID" ]] || { echo "✗ no simulator named $SIM" >&2; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

(cd "$REPO/Examples/InterventionSample" && xcodegen generate --quiet)
xcodebuild -project "$REPO/Examples/InterventionSample/InterventionSample.xcodeproj" -scheme InterventionSample \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath "$REPO/.build/sample" \
  CODE_SIGNING_ALLOWED=NO build -quiet 2>&1 | { grep -v "IDERunDestination" || true; }
[[ -d "$APP" ]] || { echo "✗ build failed" >&2; exit 1; }

xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

# Steps: "<command>|<screenshot name>". Commands are the app's QA URL commands
# (interventionsample://qa/<command>). They are passed with -qa-script instead of
# `simctl openurl`, because the iOS 26 Simulator asks "Open in …?" for every opened URL.
STEPS=(
  "tab?name=state|state-empty"
  "run?app=instagram&fg=succeed|pause"
  "wait=3|-"
  "tab?name=setup|pause-ready"
  "resolve?choice=pay|after-pay"
  "run?app=instagram&fg=succeed&dt=+2|return-passes"
  "run?app=instagram&fg=succeed&dt=+60|pass-valid"
  "run?app=instagram&fg=fail&dt=+900|foreground-failed"
  "run?app=youtube&fg=succeed&dt=+1|pause-youtube"
  "resolve?choice=skip|after-skip"
  "pd?event=start&sec=60|pd-start"
  "pd?event=bg&dt=+1|-"
  "pd?event=lock&dt=+10|-"
  "pd?event=active&dt=+100|-"
  "tab?name=state|pd-succeeded"
  "pd?event=start&sec=60|-"
  "pd?event=guarded&app=instagram&dt=+5|pd-failed-guarded"
)
SCRIPT=""
NAMES=()
for step in "${STEPS[@]}"; do
  SCRIPT="$SCRIPT${step%%|*};"
  [[ "${step%%|*}" == wait=* ]] || NAMES+=("${step##*|}")
done

LOG="$OUT/console.log"
: > "$LOG"
xcrun simctl launch --terminate-running-process --stdout="$LOG" --stderr="$LOG" "$UDID" "$BUNDLE" \
  -qa-reset -qa-now 2026-09-27T03:00:00Z -qa-reopen accept -qa-step-seconds 2.5 -qa-script "$SCRIPT" >/dev/null
sleep 1.5
xcrun simctl io "$UDID" screenshot "$OUT/00-launch.png" >/dev/null 2>&1

# Screenshot right after each step's [QA] line appears (90 s overall budget).
DEADLINE=$(( $(date +%s) + 90 ))
for i in "${!NAMES[@]}"; do
  n=$((i + 1))
  until grep -q "\[QA\] action=.*" <(grep -A1 "\[QA\] step=$n cmd=" "$LOG" | tail -1) 2>/dev/null; do
    [[ $(date +%s) -lt $DEADLINE ]] || { echo "✗ timed out waiting for step $n" >&2; break 2; }
    sleep 0.2
  done
  sleep 0.6
  name="${NAMES[$i]}"
  [[ "$name" == "-" ]] || xcrun simctl io "$UDID" screenshot "$OUT/$(printf '%02d' $n)-$name.png" >/dev/null 2>&1
done
until grep -q "\[QA\] done" "$LOG" || [[ $(date +%s) -ge $DEADLINE ]]; do sleep 0.2; done

# Expected decisions, in order. 03:00Z = 12:00 JST; the sample's policy intervenes by default.
EXPECT=(
  "action=run decision=intervene(fallback,standard)"
  "action=resolve decision=proceeded:reopened"
  "action=run decision=passThrough(return)"
  "action=run decision=passThrough(pass)"
  "action=run decision=passThrough(foregroundUnavailable)"
  "action=run decision=intervene(fallback,standard)"
  "action=resolve decision=abandoned:"
  "pd=succeeded"
  "pd=failed(openedGuardedApp"
)
grep "\[QA\]" "$LOG" > "$OUT/qa-lines.txt" || true
FAILED=0
LINE=0
for expected in "${EXPECT[@]}"; do
  found=$(awk -v start="$LINE" -v pat="$expected" 'NR > start && index($0, pat) { print NR; exit }' "$OUT/qa-lines.txt")
  if [[ -n "$found" ]]; then
    echo "✓ ${expected}"
    LINE=$found
  else
    echo "✗ ${expected} (not found after line ${LINE})" >&2
    FAILED=1
  fi
done
echo "screenshots and console: $OUT ($(ls "$OUT"/*.png | wc -l | tr -d ' ') shots)"
exit $FAILED
