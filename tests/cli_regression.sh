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

W=$(mktemp -d "${TMPDIR:-/tmp}/mc-cli-regress.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
OLD="$W/old.command"
git -C "$ROOT" show "$BASE_REV:mac-cleaner.command" > "$OLD" || { echo "cannot read $BASE_REV:mac-cleaner.command" >&2; exit 1; }

# Fixture HOME + inert tool stubs, so the real machine's brew/go/pnpm/osascript are never consulted.
FH="$W/home"; BIN="$W/bin"; mkdir -p "$FH" "$BIN"
for t in brew go pnpm osascript; do printf '#!/bin/bash\nexit 0\n' > "$BIN/$t"; chmod +x "$BIN/$t"; done
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

run_case() {  # run_case script input → stdout+stderr, free-disk figure masked
  printf '%s' "$2" | env HOME="$FH" PATH="$BIN:$PATH" /bin/bash "$1" --lang en --dry-run 2>&1 \
    | sed -E 's/Disk: .* free of .*/Disk: <masked>/'
}

fail=0; i=0
for input in "${CASES[@]}"; do
  i=$((i + 1))
  run_case "$OLD" "$input" > "$W/old.out"
  run_case "$NEW" "$input" > "$W/new.out"
  if diff -u "$W/old.out" "$W/new.out" > "$W/diff.out"; then
    echo "ok   case $i"
  else
    echo "FAIL case $i"; cat "$W/diff.out"; fail=1
  fi
done
exit "$fail"
