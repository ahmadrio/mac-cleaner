#!/bin/bash
# CLI regression: the interactive output must not change while the engine is added.
# Runs the original script (git 6ecf5ce) and the current one with --dry-run (always dry-run), the same stdin and the
# same fixture HOME, and diffs stdout+stderr (the header's version masked). Every case runs twice: --lang en, then
# --lang id (where the typed word DELETE becomes HAPUS). Exit 1 on any difference.
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

# Update menu (option 6): run against a stubbed brew, mas, curl, open and pgrep (never the real ones; this Mac may have
# Homebrew and an App Store login) and a seeded Homebrew catalog. Always dry-run. Real osascript only parses local JSON.
UPDATE_CASES=(
  $'6\n\nq\n'                # list, Enter = back
  $'6\na\ny\n\nq\n'          # everything, confirm (dry run)
  $'6\n1 3\ny\n\nq\n'        # two picks, confirm
  $'6\n2\nn\n\nq\n'          # decline
  $'6\n9\n\nq\n'            # number not in the list
  $'6\nx 1\ny\n\nq\n'        # a bad token and a valid one
  $'6\ns\n\nq\n'            # open the App Store
)
# Same, with the catalog unreadable (offline): only the Sparkle app and the formulae are checked
UPDATE_OFFLINE_CASES=(
  $'6\n\nq\n'
  $'6\na\ny\n\nq\n'
)

# RAM menu (option 7): against stubbed ps, vm_stat and sysctl, so the app list and its order are the same in both runs
# (real RAM changes between them). Numbers and pressure words are masked as well. Always dry-run: nothing is quit or purged.
RAM_CASES=(
  $'7\n\nq\n'          # list, Enter = back
  $'7\np\nn\n\nq\n'      # purge, declined
  $'7\np\ny\n\nq\n'      # purge (dry run)
  $'7\n1 3\ny\n\nq\n'    # quit two apps (dry run)
  $'7\n2\nn\n\nq\n'      # quit, declined
  $'7\n99\n\nq\n'        # number not in the list
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

# Update menu fixtures: stubs in their own bin dir (real osascript stays, only to read local JSON)
BIN_UPD="$W/bin-upd"; mkdir -p "$BIN_UPD"
cat > "$BIN_UPD/brew" <<'STUB'
#!/bin/bash
case "$*" in
  update*) exit 0 ;;
  "list --cask -1") exit 0 ;;
  "outdated --formula --verbose") printf 'wget (1.21.3) < 1.24.5\njq (1.6) < 1.7 [pinned at 1.6]\n' ;;
  "outdated --cask "*) printf 'bar (1.0) != 2.0\nbaz (1.0) != 9.0\n' ;;
  "info --cask --json=v2 "*) printf '%s' '{"casks":[{"token":"bar","auto_updates":false,"artifacts":[{"app":["Bar.app"]}]},{"token":"baz","auto_updates":true,"artifacts":[{"app":["Baz.app"]}]}]}' ;;
esac
exit 0
STUB
printf '#!/bin/bash\ncase "$1" in outdated) echo "497799835  Store  (1.0 -> 1.5)" ;; esac\nexit 0\n' > "$BIN_UPD/mas"
printf '#!/bin/bash\ncase "$*" in *formulae.brew.sh*) exit 22 ;; *) echo "<sparkle:shortVersionString>3.0</sparkle:shortVersionString>" ;; esac\n' > "$BIN_UPD/curl"
printf '#!/bin/bash\nexit 0\n' > "$BIN_UPD/open"
printf '#!/bin/bash\nexit 1\n' > "$BIN_UPD/pgrep"
chmod +x "$BIN_UPD"/*
for t in brew mas curl open pgrep; do   # refuse to go on unless every one of them resolves to the stub
  case "$(PATH="$BIN_UPD:$PATH" command -v "$t")" in "$BIN_UPD"/*) ;; *) echo "no stub for $t; refusing to run the update cases" >&2; exit 1 ;; esac
done
mk_upd_app() {  # mk_upd_app name version [extra plist key + string]
  local a="$FH/Applications/$1.app"
  mkdir -p "$a/Contents/MacOS"
  plutil -create xml1 "$a/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string "com.example.$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" "$a/Contents/Info.plist"
  plutil -insert CFBundleShortVersionString -string "$2" "$a/Contents/Info.plist"
  [ -z "${3:-}" ] || plutil -insert "$3" -string "$4" "$a/Contents/Info.plist"
  dd if=/dev/zero of="$a/Contents/MacOS/bin" bs=1024 count=64 2>/dev/null
}

# RAM stubs: a fixed process table (with a host terminal, Docker, a VM and small processes), memory figures and pressure
BIN_RAM="$W/bin-ram"; mkdir -p "$BIN_RAM"
cp "$BIN"/* "$BIN_RAM"/
cat > "$BIN_RAM/ps" <<'STUB'
#!/bin/bash
case "$*" in
  "-o comm= -p "*) echo "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal" ;;
  "-o ppid= -p "*) echo 1 ;;
  "-axo rss=,comm=")
    printf '%s\n' " 900000 /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder" \
      " 800000 /Applications/Utilities/Terminal.app/Contents/MacOS/Terminal" \
      " 750000 /Applications/Docker.app/Contents/MacOS/com.docker.backend" \
      " 700000 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
      " 650000 /Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper" \
      " 600000 /Applications/Slack.app/Contents/MacOS/Slack" \
      " 550000 /System/Library/Frameworks/Virtualization.framework/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine" \
      " 300000 /opt/homebrew/bin/node" \
      " 200000 /usr/libexec/something" \
      " 150000 /usr/local/bin/postgres" \
      "   1000 /bin/small"
    ;;
esac
exit 0
STUB
cat > "$BIN_RAM/vm_stat" <<'STUB'
#!/bin/bash
printf '%s\n' "Mach Virtual Memory Statistics: (page size of 16384 bytes)" "Pages free:          12345." \
  "Anonymous pages:            500000." "Pages purgeable:             10000." "Pages wired down:           150000." \
  "Pages occupied by compressor:   100000." "File-backed pages:          250000."
STUB
cat > "$BIN_RAM/sysctl" <<'STUB'
#!/bin/bash
case "$*" in
  "-n hw.memsize") echo 17179869184 ;;
  "-n vm.swapusage") echo "total = 2048.00M  used = 512.00M  free = 1536.00M  (encrypted)" ;;
  "-n kern.memorystatus_vm_pressure_level") echo 2 ;;
  *) exit 1 ;;
esac
STUB
printf '#!/bin/bash\nexit 0\n' > "$BIN_RAM/purge"
printf '#!/bin/bash\nexit 1\n' > "$BIN_RAM/sudo"   # never reached in a dry run; never the real one
chmod +x "$BIN_RAM"/*
for t in ps vm_stat sysctl purge sudo; do
  case "$(PATH="$BIN_RAM:$PATH" command -v "$t")" in "$BIN_RAM"/*) ;; *) echo "no stub for $t; refusing to run the RAM cases" >&2; exit 1 ;; esac
done

CLI_LANG=en   # the pass: en, then id
MASK_RAM=0    # 1 for the RAM cases: numbers and pressure words masked too

# The masking runs with LC_ALL=C: the Indonesian tables hold invalid UTF-8 (byte-truncating printf, in both scripts).
run_case() {  # run_case script input bindir → stdout+stderr, free-disk figure and version masked
  printf '%s' "$2" | env HOME="$FH" PATH="${3:-$BIN}:$PATH" /bin/bash "$1" --lang "$CLI_LANG" --dry-run 2>&1 \
    | LC_ALL=C sed -E -e 's/Disk: .* (free|kosong) (of|dari) .*/Disk: <masked>/' -e 's/^( *Mac Cleaner v)[0-9][0-9.]*$/\1X/' \
    | if [ "$MASK_RAM" = 1 ]; then LC_ALL=C sed -E -e 's/[0-9]+/#/g' -e 's/(normal|warning|critical|peringatan|kritis)/<p>/g'; else cat; fi
}

fail=0; i=0
# compare_case bindir down input → runs old and new on the same input; down = "" (running) or N (daemon down until N checks after `orb start`)
compare_case() {
  local bin=$1 down=$2 input=$3 which
  i=$((i + 1))
  [ "$CLI_LANG" = id ] && input=${input//DELETE/HAPUS}
  for which in old new; do
    rm -f "$FH"/.fake-docker-*
    [ -z "$down" ] || printf '%s\n' "$down" > "$FH/.fake-docker-down"
    case "$which" in old) run_case "$OLD" "$input" "$bin" > "$W/old.out" ;; new) run_case "$NEW" "$input" "$bin" > "$W/new.out" ;; esac
  done
  rm -f "$FH"/.fake-docker-*
  if diff -u "$W/old.out" "$W/new.out" > "$W/diff.out"; then
    echo "ok   case $i ($CLI_LANG)"
  else
    echo "FAIL case $i ($CLI_LANG)"; LC_ALL=C cat "$W/diff.out"; fail=1
  fi
}

mkdir -p "$FH/Library/Caches/mac-cleaner"
CATALOG="$FH/Library/Caches/mac-cleaner/cask.json"

# The update fixtures (apps, catalog) exist only for the update cases, as before; the other cases run without them.
for CLI_LANG in en id; do
  rm -rf "$FH/Applications/Foo.app" "$FH/Applications/Spk.app" "$FH/Applications/Store.app" \
         "$FH/Applications/Bar.app" "$FH/Applications/Baz.app"
  rm -f "$CATALOG"
  for input in "${CASES[@]}";               do compare_case "$BIN" "" "$input"; done
  for input in "${DOCKER_CASES[@]}";        do compare_case "$BIN" "" "$input"; done
  for input in "${DOCKER_EMPTY_CASES[@]}";  do compare_case "$BIN_EMPTY" "" "$input"; done
  for input in "${DOCKER_DOWN_CASES[@]}";   do compare_case "$BIN" 0 "$input"; done
  for input in "${DOCKER_NEVER_CASES[@]}";  do compare_case "$BIN" 1000000 "$input"; done
  MASK_RAM=1
  for input in "${RAM_CASES[@]}";           do compare_case "$BIN_RAM" "" "$input"; done
  MASK_RAM=0

  # Update menu: Foo (a DMG app, newer in the catalog), Spk (Sparkle feed), Store (App Store), Bar/Baz fixtures for casks
  mk_upd_app Foo 1.0
  mk_upd_app Spk 1.0 SUFeedURL "https://spk.example/feed.xml"
  mk_upd_app Store 1.0; mkdir -p "$FH/Applications/Store.app/Contents/_MASReceipt"
  mk_upd_app Bar 1.0; mk_upd_app Baz 1.0
  printf '%s' '[{"token":"foo","version":"2.0","homepage":"https://foo.example","artifacts":[{"app":["Foo.app"]}]}]' > "$CATALOG"
  for input in "${UPDATE_CASES[@]}";        do compare_case "$BIN_UPD" "" "$input"; done
  rm -f "$CATALOG"
  for input in "${UPDATE_OFFLINE_CASES[@]}"; do compare_case "$BIN_UPD" "" "$input"; done
done
exit "$fail"
