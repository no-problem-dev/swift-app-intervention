#!/bin/bash
# Fails when a test could wait forever.
#
# Rules (Reviewer E, E-M3: an unbounded `for await` hung the suite for >240 s under a mutant):
#   1. `for await` appears only in Tests/*/Bounded.swift, whose helpers race a timeout.
#   2. Every @Suite carries `.timeLimit(...)`, so any other await is bounded as well.

set -eo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

FAILED=0
while IFS= read -r file; do
  [[ "$(basename "$file")" == "Bounded.swift" ]] && continue
  if grep -n "for await" "$file" >/dev/null; then
    grep -n "for await" "$file" | sed "s|^|✗ $file:|; s|$| (use collect/firstValue from Bounded.swift)|" >&2
    FAILED=1
  fi
  if grep -n "@Suite" "$file" | grep -v "timeLimit" >/dev/null; then
    grep -n "@Suite" "$file" | grep -v "timeLimit" | sed "s|^|✗ $file:|; s|$| (add .timeLimit(.minutes(1)))|" >&2
    FAILED=1
  fi
done < <(find Tests -name '*.swift')

[[ $FAILED -eq 0 ]] && echo "✓ every awaiting test is bounded"
exit $FAILED
