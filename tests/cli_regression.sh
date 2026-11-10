#!/bin/bash
# CLI regression: the interactive output must not change while the engine is added.
# Runs the original script (git 6ecf5ce) and the current one with --lang en --dry-run (always dry-run),
# the same stdin and the same fixture HOME, and diffs stdout+stderr. Exit 1 on any difference.
# Later tasks append to CASES (each case is the text fed to stdin).
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NEW="$ROOT/mac-cleaner.command"
BASE_REV=6ecf5ce

CASES=(
  $'1\n\nq\n'              # caches: cancel
  $'1\na\ny\n\nq\n'        # caches: all "safe", confirm (dry run)
  $'1\n4\ny\n\nq\n'        # caches: Trash only (row 4), confirm (dry run)
  $'5\n\nq\n'              # largest folders: list, back
  $'3\n\n\n\nq\n'          # apps: default days, skip uninstall, Enter at the pause
  $'4\nzz-no-match\n\nq\n' # uninstall: search without a match
  $'4\nFakeFoo\n1\n\n\nq\n'   # uninstall FakeFoo: Enter = cancel
  $'4\nFakeFoo\n1\ny\n\nq\n'  # uninstall FakeFoo: app + leftovers (dry run)
  $'4\nFakeFoo\n1\na\n\nq\n'  # uninstall FakeFoo: app only (dry run)
)

# Docker menu: run against the canned docker/orb/open in tests/docker_stub.sh (never the real ones), always dry-run.
DOCKER_CASES=(
  $'2\nb\nq\n'                       # menu, back
  $'2\n1\n\nb\nq\n'                  # containers: list, Enter = back
  $'2\n1\n1 2\ny\nb\nq\n'            # containers: pick a running and an exited one, confirm
  $'2\n1\ns\ny\nb\nq\n'              # containers: all stopped
  $'2\n1\n1\nn\nb\nq\n'              # containers: decline
  $'2\n1\n9\nb\nq\n'                # containers: number not in the list
  $'2\n2\n\nb\nq\n'                  # images: list, back
  $'2\n2\n1 3 4\ny\nb\nq\n'          # images: one in use (skipped), unused, dangling
  $'2\n2\n1 2\nb\nq\n'              # images: all picks in use
  $'2\n2\nu\ny\nb\nq\n'              # images: all unused
  $'2\n2\nu\nn\nb\nq\n'              # images: all unused, declined
  $'2\n2\nd\nb\nq\n'                # images: dangling only
  $'2\n3\n\nb\nq\n'                  # volumes: list, back
  $'2\n3\n1 2\nDELETE\nb\nq\n'       # volumes: attached (skipped) and unused, typed word
  $'2\n3\nu\nDELETE\nb\nq\n'         # volumes: all unused
  $'2\n3\n2\nnope\nb\nq\n'           # volumes: wrong word
  $'2\n3\n1\nb\nq\n'                # volumes: only an attached one
  $'2\n4\na\nb\nq\n'                # build cache: all
  $'2\n4\no\nb\nq\n'                # build cache: older than 7 days
  $'2\n4\nx\nb\nq\n'                # build cache: cancel
  $'2\n5\ny\nb\nq\n'                # networks
  $'2\n5\nn\nb\nq\n'                # networks: declined
  $'2\n6\ny\nb\nq\n'                # quick clean
  $'2\n6\nn\nb\nq\n'                # quick clean: declined
  $'2\n7\nDELETE\nb\nq\n'           # everything unused
  $'2\n7\nx\nb\nq\n'                # everything unused: wrong word
  $'2\n8\nRESET\nb\nq\n'            # wipe
  $'2\n8\nreset\nb\nq\n'            # wipe: wrong word
  $'2\n9\nRESET\n\nq\n'             # OrbStack reset
  $'2\n9\nx\nb\nq\n'                # OrbStack reset: declined
)
# Empty Docker (no containers, images or volumes)
DOCKER_EMPTY_CASES=(
  $'2\n1\nb\nq\n'
  $'2\n2\nb\nq\n'
  $'2\n3\nb\nq\n'
  $'2\n8\nRESET\nb\nq\n'
)
# Docker stopped: the daemon answers only after `orb start` (the fake orb), and for the last case never
DOCKER_DOWN_CASES=(
  $'2\ny\nb\nq\n'     # start OrbStack, then the menu
  $'2\nn\nq\n'         # decline
)
DOCKER_NEVER_CASES=(
  $'2\ny\n\nq\n'      # start OrbStack, but Docker never gets ready
)

W=$(mktemp -d "${TMPDIR:-/tmp}/mc-cli-regress.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
OLD="$W/old.command"
git -C "$ROOT" show "$BASE_REV:mac-cleaner.command" > "$OLD" || { echo "cannot read $BASE_REV:mac-cleaner.command" >&2; exit 1; }

# Fixture HOME + inert tool stubs, so the real machine's brew/go/pnpm/osascript are never consulted.
FH="$W/home"; BIN="$W/bin"; mkdir -p "$FH" "$BIN"
for t in brew go pnpm osascript; do printf '#!/bin/bash\nexit 0\n' > "$BIN/$t"; chmod +x "$BIN/$t"; done
. "$ROOT/tests/docker_stub.sh"
BIN_EMPTY="$W/bin-empty"; mkdir -p "$BIN_EMPTY"
for d in "$BIN" "$BIN_EMPTY"; do   # never the real docker, orb or open (this Mac may have them)
  m=full; [ "$d" = "$BIN_EMPTY" ] && m=empty
  { printf '#!/bin/bash\n'; docker_stub_body "$m"; } > "$d/docker"
  { printf '#!/bin/bash\n'; orb_stub_body; } > "$d/orb"
  { printf '#!/bin/bash\n'; open_stub_body; } > "$d/open"
  chmod +x "$d/docker" "$d/orb" "$d/open"
done
mkdir -p "$FH/.npm/_cacache"
dd if=/dev/zero of="$FH/.npm/_cacache/blob" bs=1024 count=2048 2>/dev/null
mkdir -p "$FH/.Trash"
dd if=/dev/zero of="$FH/.Trash/old.bin" bs=1024 count=100 2>/dev/null
mkdir -p "$FH/Library/Logs" "$FH/Library/Caches/com.foo"
dd if=/dev/zero of="$FH/Library/Logs/x.log" bs=1024 count=1100 2>/dev/null
dd if=/dev/zero of="$FH/Library/Caches/com.foo/c" bs=1024 count=2048 2>/dev/null
# A fake app with one leftover file, for the uninstall cases (dry run only, nothing is ever moved).
mkdir -p "$FH/Applications/FakeFoo.app/Contents/MacOS" "$FH/Library/Preferences"
cat > "$FH/Applications/FakeFoo.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.fakefoo</string></dict></plist>
PLIST
dd if=/dev/zero of="$FH/Applications/FakeFoo.app/Contents/MacOS/bin" bs=1024 count=512 2>/dev/null
dd if=/dev/zero of="$FH/Library/Preferences/com.example.fakefoo.plist" bs=1024 count=4 2>/dev/null

run_case() {  # run_case script input bindir → stdout+stderr, free-disk figure masked
  printf '%s' "$2" | env HOME="$FH" PATH="${3:-$BIN}:$PATH" /bin/bash "$1" --lang en --dry-run 2>&1 \
    | sed -E 's/Disk: .* free of .*/Disk: <masked>/'
}

fail=0; i=0
# compare_case bindir down input → runs old and new on the same input; down = "" (running) or N (daemon down until N checks after `orb start`)
compare_case() {
  local bin=$1 down=$2 input=$3 which
  i=$((i + 1))
  for which in old new; do
    rm -f "$FH"/.fake-docker-*
    [ -z "$down" ] || printf '%s\n' "$down" > "$FH/.fake-docker-down"
    case "$which" in old) run_case "$OLD" "$input" "$bin" > "$W/old.out" ;; new) run_case "$NEW" "$input" "$bin" > "$W/new.out" ;; esac
  done
  rm -f "$FH"/.fake-docker-*
  if diff -u "$W/old.out" "$W/new.out" > "$W/diff.out"; then
    echo "ok   case $i"
  else
    echo "FAIL case $i"; cat "$W/diff.out"; fail=1
  fi
}
for input in "${CASES[@]}";               do compare_case "$BIN" "" "$input"; done
for input in "${DOCKER_CASES[@]}";        do compare_case "$BIN" "" "$input"; done
for input in "${DOCKER_EMPTY_CASES[@]}";  do compare_case "$BIN_EMPTY" "" "$input"; done
for input in "${DOCKER_DOWN_CASES[@]}";   do compare_case "$BIN" 0 "$input"; done
for input in "${DOCKER_NEVER_CASES[@]}";  do compare_case "$BIN" 1000000 "$input"; done
exit "$fail"
