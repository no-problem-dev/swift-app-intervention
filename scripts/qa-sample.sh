#!/bin/bash
# Scripted QA pass of Examples/InterventionSample on a simulator.
#
#   usage: scripts/qa-sample.sh            (QA_SIM="iPhone 17e" by default)
#
# Builds the sample into the single DerivedData path (.build/sample, the same destination
# `make sample` uses), then runs three launches:
#   1. English, light: the whole flow (pause, pay, return, pass, failed foreground, strict tier,
#      skip, phone-down success and failure), a screenshot of the screen each step shows.
#   2. Japanese, light: setup guide and pause screen (package strings must be Japanese).
#   3. Japanese, dark: the same two screens.
# Screenshots go to .build/qa-shots/<timestamp>/ (gitignored); the `[QA]` lines the app prints
# are checked against the expected decisions.
#
# The steps are the app's QA URL commands (interventionsample://qa/<command>), passed with
# -qa-script: the iOS 26 Simulator asks "Open in …?" for every URL sent with `simctl openurl`,
# which blocks an unattended run. By hand, one at a time:
#   xcrun simctl openurl booted 'interventionsample://qa/run?app=instagram&fg=succeed'
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
xcrun simctl install "$UDID" "$APP"

DEADLINE_SECONDS=90

# run_pass <label> <appearance> <steps...> -- <launch args...>
# A step is "<command>|<screenshot name>"; "-" as the name takes no screenshot, "wait=N" pauses.
run_pass() {
  local label="$1" appearance="$2"; shift 2
  local steps=() args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do steps+=("$1"); shift; done
  shift
  args=("$@")

  xcrun simctl ui "$UDID" appearance "$appearance" >/dev/null
  local script="" names=()
  for step in "${steps[@]}"; do
    script="$script${step%%|*};"
    [[ "${step%%|*}" == wait=* ]] || names+=("${step##*|}")
  done

  local log="$OUT/console-$label.log"
  : > "$log"
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch --terminate-running-process --stdout="$log" --stderr="$log" "$UDID" "$BUNDLE" \
    -qa-reset -qa-reopen accept -qa-step-seconds 2.5 -qa-script "$script" "${args[@]}" >/dev/null

  local deadline=$(( $(date +%s) + DEADLINE_SECONDS ))
  until grep -q "\[QA\] ready" "$log"; do
    [[ $(date +%s) -lt $deadline ]] || { echo "✗ $label: app never became ready" >&2; return 1; }
    sleep 0.2
  done
  xcrun simctl io "$UDID" screenshot "$OUT/$label-00-launch.png" >/dev/null 2>&1

  local i n name
  for i in "${!names[@]}"; do
    n=$((i + 1))
    # Wait for this step's [QA] line (the action result), then let the UI settle.
    until grep -A1 "\[QA\] step=$n cmd=" "$log" | grep -q "\[QA\] action="; do
      [[ $(date +%s) -lt $deadline ]] || { echo "✗ $label: timed out at step $n" >&2; return 1; }
      sleep 0.2
    done
    sleep 0.8
    name="${names[$i]}"
    [[ "$name" == "-" ]] || xcrun simctl io "$UDID" screenshot "$OUT/$label-$(printf '%02d' $n)-$name.png" >/dev/null 2>&1
  done
  until grep -q "\[QA\] done" "$log" || [[ $(date +%s) -ge $deadline ]]; do sleep 0.2; done
  grep "\[QA\]" "$log" >> "$OUT/qa-lines-$label.txt" || true
}

# 03:00Z = 12:00 JST (standard tier); 13:30Z = 22:30 JST (the sample's strict night window).
run_pass en light \
  "tab?name=state|state-empty" \
  "run?app=instagram&fg=succeed|pause-standard" \
  "wait=3|-" \
  "tab?name=state|pause-standard-ready" \
  "resolve?choice=pay|state-after-pay" \
  "run?app=instagram&fg=succeed&dt=+2|state-return-passes" \
  "run?app=instagram&fg=succeed&dt=+60|state-pass-valid" \
  "run?app=instagram&fg=fail&dt=+900|state-foreground-failed" \
  "now?iso=2026-09-27T13:30:00Z|-" \
  "run?app=youtube&fg=succeed|pause-strict" \
  "wait=3|-" \
  "tab?name=state|pause-strict-ready" \
  "resolve?choice=skip|state-after-skip" \
  "tab?name=pd|-" \
  "pd?event=start&sec=60|pd-running" \
  "pd?event=bg&dt=+1|-" \
  "pd?event=lock&dt=+10|-" \
  "pd?event=active&dt=+100|pd-succeeded" \
  "pd?event=start&sec=60|-" \
  "pd?event=guarded&app=instagram&dt=+5|pd-failed" \
  -- -qa-now 2026-09-27T03:00:00Z -AppleLanguages "(en)" -AppleLocale en_US

for look in light dark; do
  run_pass "ja-$look" "$look" \
    "tab?name=setup|setup" \
    "run?app=instagram&fg=succeed|pause" \
    "wait=3|-" \
    "tab?name=setup|pause-ready" \
    -- -qa-now 2026-09-27T03:00:00Z -AppleLanguages "(ja)" -AppleLocale ja_JP
done
xcrun simctl ui "$UDID" appearance light >/dev/null

check() {
  local file="$1"; shift
  local line=0 found expected failed=0
  for expected in "$@"; do
    found=$(awk -v start="$line" -v pat="$expected" 'NR > start && index($0, pat) { print NR; exit }' "$file")
    if [[ -n "$found" ]]; then
      echo "✓ $(basename "$file" .txt): ${expected}"
      line=$found
    else
      echo "✗ $(basename "$file" .txt): ${expected} (not found after line ${line})" >&2
      failed=1
    fi
  done
  return $failed
}

FAILED=0
check "$OUT/qa-lines-en.txt" \
  "action=run decision=intervene(fallback,standard)" \
  "action=resolve decision=proceeded:reopened" \
  "action=run decision=passThrough(return)" \
  "action=run decision=passThrough(pass)" \
  "action=run decision=passThrough(foregroundUnavailable)" \
  "action=run decision=intervene(rule(id: \"night\"),strict)" \
  "action=resolve decision=abandoned:" \
  "pd=succeeded" \
  "pd=failed(openedGuardedApp" || FAILED=1
for look in light dark; do
  check "$OUT/qa-lines-ja-$look.txt" "action=run decision=intervene(fallback,standard)" || FAILED=1
done
echo "screenshots and console: $OUT ($(ls "$OUT"/*.png | wc -l | tr -d ' ') shots)"
exit $FAILED
