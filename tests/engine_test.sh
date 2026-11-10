#!/bin/bash
# Runs the engine tests: bash tests/engine_test.sh [name-filter]
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/mac-cleaner.command"
T_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mc-engine-test.XXXXXX") || exit 1
trap 'rm -rf "$T_ROOT"' EXIT

. "$ROOT/tests/lib.sh"
for f in "$ROOT"/tests/engine/*.sh; do [ -f "$f" ] && . "$f"; done

failed=0; n=0
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  case "$t" in *"${1:-}"*) ;; *) continue ;; esac
  n=$((n + 1))
  if ( "$t" ); then echo "ok   $t"; else echo "FAIL $t"; failed=$((failed + 1)); fi
done
echo "$((n - failed))/$n passed"
[ "$failed" = 0 ]
