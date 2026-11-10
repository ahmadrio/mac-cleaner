# Test harness for the --engine mode. Sourced by tests/engine_test.sh.
# Needs SCRIPT (path of mac-cleaner.command) and T_ROOT (scratch dir) to be set.

fail() {
  echo "    $*" >&2
  [ -z "${OUT:-}" ] || { echo "    --- stdout ---" >&2; printf '%s\n' "$OUT" | sed 's/^/    | /' >&2; }
  [ -z "${ERR:-}" ] || { echo "    --- stderr ---" >&2; printf '%s\n' "$ERR" | sed 's/^/    | /' >&2; }
  exit 1
}

# mk_home → T_HOME (fresh HOME) and T_BIN (empty stub dir, put first on PATH by engine)
mk_home() {
  T_HOME=$(mktemp -d "$T_ROOT/home.XXXXXX") || exit 1
  T_BIN=$(mktemp -d "$T_ROOT/bin.XXXXXX") || exit 1
  OUT=""; ERR=""; RC=""
}

# mkfile path kb → file of that many KB (parents created)
mkfile() {
  mkdir -p "$(dirname "$1")"
  dd if=/dev/zero of="$1" bs=1024 count="$2" 2>/dev/null
}

# stub name body → $T_BIN/name logs "name args" to $T_BIN/calls.log, then runs body
stub() {
  {
    printf '#!/bin/bash\n'
    printf 'echo "%s $*" >> "%s/calls.log"\n' "$1" "$T_BIN"
    printf '%s\n' "$2"
  } > "$T_BIN/$1"
  chmod +x "$T_BIN/$1"
}

# require_stub name… → fail the test unless that name resolves to a stub in $T_BIN.
# Call it before running anything that could reach docker/orb/brew/mas/osascript.
require_stub() {
  local n p
  for n in "$@"; do
    p=$(PATH="$T_BIN:$PATH" command -v "$n" 2>/dev/null)
    case "$p" in "$T_BIN"/*) ;; *) fail "no stub for '$n' in \$T_BIN; refusing to run (it could touch the real $n)" ;; esac
  done
}

# Safety net: this Mac may have real Docker/OrbStack/Docker Desktop. Any run that could call docker, orb or open
# (a docker-* engine command, or eval code naming docker/dk*_/orb_) must have all three stubbed, or the test fails
# before the script starts. The Docker stub helpers in tests/engine/docker.sh create them.
_guard_docker() {
  local a
  for a in "$@"; do
    case "$a" in
      *docker-*|*docker_*|*dk_*|*dkr_*|*dkp_*|*orb_*) require_stub docker orb open; return ;;
    esac
  done
}

# Same for updates: this Mac may have real Homebrew, mas, curl and open. Any run that could call them (an updates-*
# engine command, or eval code naming updates_*, update_menu or replace_with_cask) must have all of them stubbed,
# or the test fails before the script starts. stub_brew in tests/engine/updates.sh creates them.
_guard_updates() {
  local a
  for a in "$@"; do
    case "$a" in
      *updates-*|*updates_*|*update_menu*|*replace_with_cask*) require_stub brew mas curl open pgrep; return ;;
    esac
  done
}

# _run_engine <home|finder> <code-or-empty> args… → sets OUT, ERR, RC.
# mode home: MAC_CLEANER_TRASH=home. mode finder: it is unset, so osa_finder is used.
# With code, the script's functions are loaded (all but the final dispatch line) in engine
# mode and the code runs after them, for unit-testing helpers.
_run_engine() {
  local mode="$1" code="$2" ef="$T_HOME.err" trash=home; shift 2
  [ "$mode" = finder ] && trash=""
  _guard_docker "$code" "$@"
  _guard_updates "$code" "$@"
  if [ -n "$code" ]; then
    code="$(sed '$d' "$SCRIPT")"$'\n'"$code"
    OUT=$(env -u MAC_CLEANER_TRASH ${trash:+MAC_CLEANER_TRASH=$trash} HOME="$T_HOME" PATH="$T_BIN:$PATH" \
          MAC_CLEANER_APP_DIRS="$T_HOME/Applications" \
          /bin/bash -c "$code" "$SCRIPT" --lang en "$@" --engine _eval </dev/null 2>"$ef")
  else
    OUT=$(env -u MAC_CLEANER_TRASH ${trash:+MAC_CLEANER_TRASH=$trash} HOME="$T_HOME" PATH="$T_BIN:$PATH" \
          MAC_CLEANER_APP_DIRS="$T_HOME/Applications" \
          /bin/bash "$SCRIPT" --lang en "$@" </dev/null 2>"$ef")
  fi
  RC=$?
  ERR=$(cat "$ef" 2>/dev/null)
}

engine()        { _run_engine home "" "$@"; }
# Same, but without MAC_CLEANER_TRASH so move_to_trash goes through osa_finder.
# It calls require_stub osascript itself, so the test fails if there is no stub.
engine_finder() { require_stub osascript; _run_engine finder "" "$@"; }
# engine_eval '<bash code>' [global opts…]: run code with the script's functions loaded.
engine_eval()        { local c="$1"; shift; _run_engine home "$c" "$@"; }
engine_finder_eval() { local c="$1"; shift; require_stub osascript; _run_engine finder "$c" "$@"; }

assert_rc()        { [ "$RC" = "$1" ] || fail "expected exit code $1, got $RC"; }
assert_line()      { printf '%s\n' "$OUT" | grep -Eq -- "$1" || fail "no stdout line matches: $1"; }
assert_no_line()   { ! printf '%s\n' "$OUT" | grep -Eq -- "$1" || fail "unexpected stdout line matches: $1"; }
assert_exists()    { [ -e "$1" ] || fail "missing: $1"; }
assert_missing()   { [ ! -e "$1" ] || fail "should not exist: $1"; }
assert_called()    { grep -Eq -- "$1" "$T_BIN/calls.log" 2>/dev/null || fail "stub call not found: $1"; }
assert_not_called(){ ! grep -Eq -- "$1" "$T_BIN/calls.log" 2>/dev/null || fail "unexpected stub call: $1"; }
# every @@ line must be a known record type
assert_protocol() {
  local bad
  bad=$(printf '%s\n' "$OUT" | grep '^@@' | grep -Ev $'^@@(progress|log|meta|row|freed|disk|error)\t' | head -1)
  [ -z "$bad" ] || fail "bad protocol line: $bad"
}
