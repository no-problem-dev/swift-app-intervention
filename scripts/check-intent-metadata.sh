#!/bin/bash
# App Intents のメタデータに、背景→前面の宣言が本当に載っているかを確かめる。
#
#   使い方: scripts/check-intent-metadata.sh [--app <Foo.app>] [--intent <Identifier>]...
#           引数なしなら Examples/InterventionSample をビルドして確かめる。
#
# なぜ要るか（設計レビュー B-M1 の実測）:
#   `static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]` と
#   リテラルで書くと extract.actionsdata は `supportedModes: 9` になる。
#   ところがパッケージ等の定数を参照して `= SomeConstant` と書くと **警告なしで 1（背景のみ）**になり、
#   continueInForeground が前面に出られなくなる。コンパイルもテストも通るので、ここで見るしかない。
#
#   9 = background(1) | foreground(.dynamic)(8)。ホストアプリの gate / CI に同じ確認を入れること。

set -eo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP=""
INTENTS=()
EXPECTED=9

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --intent) INTENTS+=("$2"); shift 2 ;;
    --expected) EXPECTED="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$APP" ]]; then
  SAMPLE="$REPO/Examples/InterventionSample"
  DERIVED="$REPO/.build/sample"
  (cd "$SAMPLE" && xcodegen generate --quiet)
  xcodebuild -project "$SAMPLE/InterventionSample.xcodeproj" -scheme InterventionSample \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO build -quiet
  APP="$DERIVED/Build/Products/Debug-iphonesimulator/InterventionSample.app"
  [[ ${#INTENTS[@]} -eq 0 ]] && INTENTS=(PauseBeforeOpeningIntent)
fi

DATA="$APP/Metadata.appintents/extract.actionsdata"
[[ -f "$DATA" ]] || { echo "✗ メタデータが無い: $DATA" >&2; exit 1; }

if [[ ${#INTENTS[@]} -eq 0 ]]; then
  echo "--intent で確かめる intent を指定すること" >&2
  exit 2
fi

FAILED=0
for intent in "${INTENTS[@]}"; do
  modes=$(jq -r --arg id "$intent" '.actions[$id].supportedModes // "missing"' "$DATA")
  if [[ "$modes" == "$EXPECTED" ]]; then
    echo "✓ ${intent} supportedModes=${modes}"
  else
    echo "✗ ${intent} supportedModes=${modes}（期待値 ${EXPECTED}。supportedModes をリテラルで書いているか確認）" >&2
    FAILED=1
  fi
done
exit $FAILED
