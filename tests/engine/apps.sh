# Engine: apps-scan, apps-list, uninstall-plan and uninstall.
# Every fixture app lives under $T_HOME/Applications (the harness points MAC_CLEANER_APP_DIRS there),
# and every real move goes through `engine` (MAC_CLEANER_TRASH=home → $T_HOME/.Trash).

# mk_app dir name bundle-id → dir/name.app with an Info.plist and a 1 MB executable
mk_app() {
  local a="$1/$2.app"
  mkdir -p "$a/Contents/MacOS"
  plutil -create xml1 "$a/Contents/Info.plist" && plutil -insert CFBundleIdentifier -string "$3" "$a/Contents/Info.plist" \
    || fail "plutil failed for $a"
  mkfile "$a/Contents/MacOS/bin" 1024
}

# ulist path… → $T_HOME/list, one path per line
ulist() { printf '%s\n' "$@" > "$T_HOME/list"; }

# mk_foo → Foo.app with two leftovers: a preferences plist and an Application Support folder
mk_foo() {
  mk_app "$T_HOME/Applications" Foo com.example.foo
  mkfile "$T_HOME/Library/Preferences/com.example.foo.plist" 4
  mkfile "$T_HOME/Library/Application Support/Foo/db" 4
}

# assert_nothing_moved: Foo.app and both leftovers are still in place and the Trash is empty
assert_nothing_moved() {
  assert_exists "$T_HOME/Applications/Foo.app"
  assert_exists "$T_HOME/Library/Preferences/com.example.foo.plist"
  assert_exists "$T_HOME/Library/Application Support/Foo/db"
  [ -z "$(ls -A "$T_HOME/.Trash" 2>/dev/null)" ] || fail "something reached the Trash: $(ls -A "$T_HOME/.Trash")"
}

# ───────────── app_dirs / list_apps ─────────────
test_app_dirs_override_and_default() {
  mk_home
  engine_eval 'MAC_CLEANER_APP_DIRS="/a b:/c::/d"; app_dirs'
  [ "$OUT" = $'/a b\n/c\n/d' ] || fail "override not split on colons: $OUT"
  engine_eval 'unset MAC_CLEANER_APP_DIRS; app_dirs'
  [ "$OUT" = $'/Applications\n'"$T_HOME/Applications" ] || fail "default dirs wrong: $OUT"
}

test_apps_list_excludes_self() {
  mk_home; mk_app "$T_HOME/Applications" Foo com.example.foo; mk_app "$T_HOME/Applications" "Mac Cleaner" io.github.ahmadrio.mac-cleaner
  MAC_CLEANER_APP="$T_HOME/Applications/Mac Cleaner.app" engine --engine apps-list
  assert_rc 0; assert_protocol
  assert_line $'^@@row\tappname\tFoo\t'; assert_no_line 'Mac Cleaner\.app'
}

test_apps_list_excludes_mdfind_paths() {
  mk_home; mk_app "$T_HOME/Applications" Foo com.example.foo; mk_app "$T_HOME/Applications" Bar com.example.bar
  stub mdfind 'echo "'"$T_HOME"'/Applications/Bar.app"'; require_stub mdfind
  engine --engine apps-list
  assert_rc 0; assert_called "^mdfind .*io\\.github\\.ahmadrio\\.mac-cleaner"
  assert_line $'^@@row\tappname\tFoo\t'; assert_no_line 'Bar'
}

test_apps_list_survives_failing_mdfind() {
  mk_home; mk_app "$T_HOME/Applications" Foo com.example.foo
  stub mdfind 'exit 1'; require_stub mdfind
  engine --engine apps-list
  assert_rc 0; assert_line $'^@@row\tappname\tFoo\t'
}

test_apps_list_shape_and_safari() {
  mk_home; mk_app "$T_HOME/Applications" Zed com.example.zed; mk_app "$T_HOME/Applications" alpha com.example.alpha
  mk_app "$T_HOME/Applications" Safari com.apple.Safari; mk_app "$T_HOME/Applications/Sub" Deep com.example.deep
  engine --engine apps-list
  assert_rc 0; assert_no_line 'Safari'
  assert_line $'^@@row\tappname\tDeep\t'"$T_HOME"'/Applications/Sub/Deep\.app$'
  # sorted by name, ignoring case
  [ "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="appname"{printf "%s,", $3}')" = "alpha,Deep,Zed," ] || fail "appname rows not sorted by name"
}

# ───────────── apps-scan ─────────────
test_apps_scan_rows() {
  mk_home; mk_app "$T_HOME/Applications" Foo com.example.foo
  engine --engine apps-scan 90
  assert_rc 0; assert_protocol
  assert_line $'^@@row\tapp\t[0-9]+\t-?[0-9]+\t[01]\tFoo\t'"$T_HOME"'/Applications/Foo\.app$'
  assert_line $'^@@meta\trare_n\t'; assert_line $'^@@meta\trare_kb\t'; assert_line $'^@@meta\ttotal\t1$'
  assert_line $'^@@progress\tFoo\t1\t1$'
}

test_apps_scan_bad_days() {
  mk_home
  engine --engine apps-scan abc; assert_rc 2; assert_line $'^@@error\tbad_args\t'
  engine --engine apps-scan; assert_rc 2; assert_line $'^@@error\tbad_args\t'
  engine --engine apps-scan -5; assert_rc 2; assert_line $'^@@error\tbad_args\t'
  engine --engine apps-scan 1 2; assert_rc 2; assert_line $'^@@error\tbad_args\t'
}

test_apps_scan_rare_threshold() {
  mk_home; mk_app "$T_HOME/Applications" Old com.example.old; mk_app "$T_HOME/Applications" New com.example.new
  stub mdls 'case "$*" in
  *kMDItemLastUsedDate*Old.app) date -v-200d +"%Y-%m-%d %H:%M:%S %z" ;;
  *kMDItemLastUsedDate*) date +"%Y-%m-%d %H:%M:%S %z" ;;
  *) echo "(null)" ;;
esac'
  require_stub mdls
  engine --engine apps-scan 90
  assert_rc 0
  assert_line $'^@@row\tapp\t[0-9]+\t(19[89]|20[01])\t1\tOld\t'; assert_line $'^@@row\tapp\t[0-9]+\t0\t0\tNew\t'
  assert_line $'^@@meta\trare_n\t1$'
  engine --engine apps-scan 365
  assert_line $'^@@row\tapp\t[0-9]+\t(19[89]|20[01])\t0\tOld\t'; assert_line $'^@@meta\trare_n\t0$'
}

test_apps_scan_no_apps() {
  mk_home
  engine --engine apps-scan 90
  assert_rc 0; assert_line $'^@@meta\ttotal\t0$'; assert_line $'^@@meta\trare_n\t0$'; assert_no_line '^@@row'
}

# ───────────── uninstall-plan ─────────────
test_uninstall_plan_finds_leftovers() {
  mk_home; mk_app "$T_HOME/Applications" Foo com.example.foo
  mkfile "$T_HOME/Library/Preferences/com.example.foo.plist" 4; mkfile "$T_HOME/Library/Application Support/Foo/db" 4
  engine --engine uninstall-plan "$T_HOME/Applications/Foo.app"
  assert_rc 0; assert_protocol; assert_line $'^@@meta\tbundle_id\tcom.example.foo$'
  assert_line $'^@@meta\tname\tFoo$'; assert_line $'^@@meta\tapp_kb\t[0-9]+$'
  assert_line $'^@@meta\tdup\t$'; assert_line $'^@@meta\tvendor_hint\t0$'
  assert_line "leftover"$'\t'"[0-9]+"$'\t'"$T_HOME/Library/Preferences/com.example.foo.plist\$"
  assert_line "leftover"$'\t'"[0-9]+"$'\t'"$T_HOME/Library/Application Support/Foo\$"
}

test_uninstall_plan_dup_keeps_leftovers() {
  mk_home; mk_foo; mk_app "$T_HOME/Applications/Old" Foo com.example.foo
  engine --engine uninstall-plan "$T_HOME/Applications/Foo.app"
  assert_rc 0; assert_line $'^@@meta\tdup\t'"$T_HOME"'/Applications/Old/Foo\.app$'; assert_no_line 'leftover'
}

test_uninstall_plan_vendor_hint() {
  mk_home; mk_app "$T_HOME/Applications/Vendor" Foo com.example.foo
  engine --engine uninstall-plan "$T_HOME/Applications/Vendor/Foo.app"
  assert_rc 0; assert_line $'^@@meta\tvendor_hint\t1$'
}

test_uninstall_plan_only_offers_what_uninstall_accepts() {
  mk_home; mk_foo
  mkdir -p "$T_HOME/Library/Caches"; ln -s /etc "$T_HOME/Library/Caches/com.example.foo"
  engine --engine uninstall-plan "$T_HOME/Applications/Foo.app"
  assert_rc 0; assert_no_line 'Caches/com\.example\.foo'; assert_line 'com\.example\.foo\.plist'
}

test_uninstall_plan_rejects_unlisted_app() {
  mk_home; mk_app "$T_HOME/Elsewhere" Foo com.example.foo
  engine --engine uninstall-plan "$T_HOME/Elsewhere/Foo.app"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t'; assert_no_line '^@@meta'
  engine --engine uninstall-plan; assert_rc 2; assert_line $'^@@error\tbad_args\t'
}

# ───────────── uninstall: the happy paths ─────────────
test_uninstall_moves_only_listed() {
  mk_home; mk_app "$T_HOME/Applications" Foo com.example.foo
  mkfile "$T_HOME/Library/Preferences/com.example.foo.plist" 4; mkfile "$T_HOME/Library/Application Support/Foo/db" 4
  printf '%s\n' "$T_HOME/Library/Preferences/com.example.foo.plist" > "$T_HOME/list"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 0; assert_protocol; assert_missing "$T_HOME/Applications/Foo.app"; assert_exists "$T_HOME/.Trash/Foo.app"
  assert_exists "$T_HOME/.Trash/com.example.foo.plist"; assert_exists "$T_HOME/Library/Application Support/Foo/db"
  assert_line $'^@@log\tok\t'
}

test_uninstall_empty_list_moves_app_only() {
  mk_home; mk_foo; : > "$T_HOME/list"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 0; assert_exists "$T_HOME/.Trash/Foo.app"; assert_missing "$T_HOME/Applications/Foo.app"
  assert_exists "$T_HOME/Library/Preferences/com.example.foo.plist"; assert_exists "$T_HOME/Library/Application Support/Foo/db"
}

test_uninstall_blank_lines_and_duplicates() {
  mk_home; mk_foo
  p="$T_HOME/Library/Preferences/com.example.foo.plist"
  printf '\n%s\n   \n%s\n\n' "$p" "$p" > "$T_HOME/list"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 0; assert_exists "$T_HOME/.Trash/com.example.foo.plist"
  [ "$(ls -A "$T_HOME/.Trash" | wc -l | tr -d ' ')" = 2 ] || fail "duplicate path should be moved once: $(ls -A "$T_HOME/.Trash")"
}

test_uninstall_dry_run_moves_nothing() {
  mk_home; mk_foo; ulist "$T_HOME/Library/Preferences/com.example.foo.plist"
  engine --dry-run --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 0; assert_nothing_moved
  assert_line $'^@@log\tsay\t.*\\[dry-run\\].*Foo\\.app'; assert_line $'^@@log\tsay\t.*\\[dry-run\\].*com\\.example\\.foo\\.plist'
}

test_uninstall_dry_run_still_validates() {
  mk_home; mk_foo; ulist /etc/hosts
  engine --dry-run --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t'
}

test_uninstall_unicode_names() {
  mk_home; mk_app "$T_HOME/Applications" "Café Notes" com.example.cafe; mkfile "$T_HOME/Library/Application Support/Café Notes/x" 4
  engine --engine uninstall-plan "$T_HOME/Applications/Café Notes.app"
  assert_line "$T_HOME/Library/Application Support/Café Notes\$"
  printf '%s\n' "$T_HOME/Library/Application Support/Café Notes" > "$T_HOME/list"
  engine --engine uninstall "$T_HOME/Applications/Café Notes.app" --list "$T_HOME/list"
  assert_rc 0; assert_exists "$T_HOME/.Trash/Café Notes.app"; assert_exists "$T_HOME/.Trash/Café Notes"
}

# ───────────── uninstall: everything that must be refused, with nothing moved ─────────────
test_uninstall_rejects_paths_outside_leftover_dirs() {
  mk_home; mk_app "$T_HOME/Applications" Foo com.example.foo; mkfile "$T_HOME/Documents/keep.txt" 1
  printf '%s\n' "$T_HOME/Documents/keep.txt" /etc/hosts > "$T_HOME/list"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t'; assert_exists "$T_HOME/Documents/keep.txt"; assert_exists "$T_HOME/Applications/Foo.app"
}

test_uninstall_rejects_leftover_of_another_app() {
  # inside a leftover folder, but named after neither Foo nor its bundle id (e.g. Apple's iPhone backups)
  mk_home; mk_foo
  mkfile "$T_HOME/Library/Application Support/MobileSync/Backup/x" 4; mkfile "$T_HOME/Library/Preferences/com.other.app.plist" 1
  local p
  for p in "$T_HOME/Library/Application Support/MobileSync" "$T_HOME/Library/Preferences/com.other.app.plist"; do
    ulist "$T_HOME/Library/Preferences/com.example.foo.plist" "$p"
    engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
    assert_rc 2; assert_line $'^@@error\tnot_allowed\t'"$p"'$'; assert_nothing_moved; assert_exists "$p"
  done
}

test_uninstall_rejects_files_of_a_sibling_app() {
  # FooPro's bundle id starts with Foo's: the plan for Foo leaves its files out, and so must uninstall
  mk_home; mk_foo; mk_app "$T_HOME/Applications" FooPro com.example.foo.pro
  mkfile "$T_HOME/Library/Preferences/com.example.foo.pro.plist" 1; mkfile "$T_HOME/Library/Caches/com.example.foo.pro/x" 1
  engine --engine uninstall-plan "$T_HOME/Applications/Foo.app"
  assert_rc 0; assert_no_line 'com\.example\.foo\.pro'
  local p
  for p in "$T_HOME/Library/Preferences/com.example.foo.pro.plist" "$T_HOME/Library/Caches/com.example.foo.pro"; do
    ulist "$p"
    engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
    assert_rc 2; assert_line $'^@@error\tnot_allowed\t'"$p"'$'; assert_nothing_moved; assert_exists "$p"
  done
}

test_uninstall_with_another_copy_moves_no_leftovers() {
  # another copy of the app shares its files: the plan offers none (dup), and uninstall takes none, only the app
  mk_home; mk_foo; mk_app "$T_HOME/Applications/Old" Foo com.example.foo
  ulist "$T_HOME/Library/Preferences/com.example.foo.plist"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t'; assert_nothing_moved
  : > "$T_HOME/list"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 0; assert_exists "$T_HOME/.Trash/Foo.app"; assert_exists "$T_HOME/Library/Preferences/com.example.foo.plist"
}

test_uninstall_accepts_what_the_plan_offers() {
  # every kind of name the plan matches (bundle id, its helpers, group container, team-prefixed, app name) still passes
  mk_home; mk_foo
  local d="$T_HOME/Library"
  mkfile "$d/Caches/com.example.foo.helper/x" 1; mkfile "$d/Group Containers/group.com.example.foo/x" 1
  mkfile "$d/Group Containers/ABCDE12345.com.example.foo/x" 1; mkfile "$d/Saved Application State/com.example.foo.savedState/x" 1
  engine --engine uninstall-plan "$T_HOME/Applications/Foo.app"
  assert_rc 0
  printf '%s\n' "$OUT" | awk -F'\t' '$1 == "@@row" && $2 == "leftover" { print $4 }' > "$T_HOME/list"
  [ "$(wc -l < "$T_HOME/list" | tr -d ' ')" = 6 ] || fail "plan should offer 6 leftovers: $(cat "$T_HOME/list")"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 0; assert_missing "$d/Group Containers/ABCDE12345.com.example.foo"; assert_missing "$d/Caches/com.example.foo.helper"
}

test_uninstall_rejects_app_not_in_app_dirs() {
  mk_home; mk_app "$T_HOME/Elsewhere" Foo com.example.foo; : > "$T_HOME/list"
  engine --engine uninstall "$T_HOME/Elsewhere/Foo.app" --list "$T_HOME/list"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t'; assert_exists "$T_HOME/Elsewhere/Foo.app"
}

test_uninstall_rejects_app_path_variants() {
  mk_home; mk_foo; : > "$T_HOME/list"
  for a in "$T_HOME/Applications/Foo.app/" "$T_HOME/Applications/../Applications/Foo.app" "$T_HOME/Applications/Foo.app/Contents" \
           "$T_HOME/Applications" "$T_HOME/Applications/Safari.app" "Foo.app" "/"; do
    engine --engine uninstall "$a" --list "$T_HOME/list"
    [ "$RC" = 2 ] || fail "expected rc 2 for app path '$a', got $RC"
  done
  assert_nothing_moved
}

test_uninstall_rejects_self() {
  mk_home; mk_app "$T_HOME/Applications" "Mac Cleaner" io.github.ahmadrio.mac-cleaner; : > "$T_HOME/list"
  MAC_CLEANER_APP="$T_HOME/Applications/Mac Cleaner.app" engine --engine uninstall "$T_HOME/Applications/Mac Cleaner.app" --list "$T_HOME/list"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t'; assert_exists "$T_HOME/Applications/Mac Cleaner.app"
}

test_uninstall_rejects_app_path_in_list() {
  mk_home; mk_foo; ulist "$T_HOME/Library/Preferences/com.example.foo.plist" "$T_HOME/Applications/Foo.app"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t'"$T_HOME"'/Applications/Foo\.app$'; assert_nothing_moved
}

test_uninstall_rejects_dotdot_path() {
  mk_home; mk_foo; mkfile "$T_HOME/Documents/keep.txt" 1
  ulist "$T_HOME/Library/Preferences/../../Documents/keep.txt"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t'; assert_exists "$T_HOME/Documents/keep.txt"; assert_nothing_moved
  ulist "$T_HOME/Library/Caches/.."
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 2; assert_nothing_moved
}

test_uninstall_rejects_parent_not_a_leftover_dir() {
  mk_home; mk_foo
  # inside a leftover folder, but two levels down; and a plain file under HOME
  ulist "$T_HOME/Library/Application Support/Foo/db"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t'"$T_HOME"'/Library/Application Support/Foo/db$'; assert_nothing_moved
  mkfile "$T_HOME/Library/Other/x" 1; ulist "$T_HOME/Library/Other/x"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 2; assert_exists "$T_HOME/Library/Other/x"; assert_nothing_moved
}

test_uninstall_rejects_leftover_dirs_themselves() {
  mk_home; mk_foo; mkdir -p "$T_HOME/Library/Preferences/ByHost"
  for p in "$T_HOME/Library/Preferences/ByHost" "$T_HOME/Library/Application Support" "$T_HOME/Library/Preferences" \
           "$T_HOME/Library" "$T_HOME" "$T_HOME/Library/Caches/." "$T_HOME/Library/Caches/" "$T_HOME/Library//Caches/x"; do
    mkdir -p "$T_HOME/Library/Caches"
    ulist "$p"
    engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
    [ "$RC" = 2 ] || fail "expected rc 2 for '$p', got $RC"
  done
  assert_exists "$T_HOME/Library/Preferences/ByHost"; assert_exists "$T_HOME/Library/Caches"; assert_nothing_moved
}

test_uninstall_rejects_missing_empty_and_relative_paths() {
  mk_home; mk_foo
  for p in "$T_HOME/Library/Caches/not-there" "Library/Caches/x" "~/Library/Caches/x" "\$HOME/Library/Caches/x"; do
    ulist "$p"
    engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
    [ "$RC" = 2 ] || fail "expected rc 2 for '$p', got $RC"
  done
  assert_nothing_moved
}

test_uninstall_rejects_symlinks() {
  mk_home; mk_foo
  mkfile "$T_HOME/elsewhere/c1/x" 1
  mkdir -p "$T_HOME/Library/Caches"; ln -s "$T_HOME/elsewhere/c1" "$T_HOME/Library/Caches/link-leaf"
  ulist "$T_HOME/Library/Caches/link-leaf"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t'; assert_exists "$T_HOME/elsewhere/c1/x"; assert_nothing_moved
  # a leftover folder that is itself a symlink: whatever is inside is not under HOME for real
  rm -rf "$T_HOME/Library/Caches"; ln -s "$T_HOME/elsewhere" "$T_HOME/Library/Caches"
  ulist "$T_HOME/Library/Caches/c1"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t'; assert_exists "$T_HOME/elsewhere/c1/x"; assert_nothing_moved
}

test_uninstall_all_or_nothing() {
  mk_home; mk_foo
  ulist "$T_HOME/Library/Preferences/com.example.foo.plist" /etc/hosts
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t/etc/hosts$'; assert_nothing_moved
}

test_uninstall_bad_args() {
  mk_home; mk_foo; ulist "$T_HOME/Library/Preferences/com.example.foo.plist"
  engine --engine uninstall; assert_rc 2; assert_line $'^@@error\tbad_args\t'
  engine --engine uninstall "$T_HOME/Applications/Foo.app"; assert_rc 2; assert_line $'^@@error\tbad_args\t'
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list; assert_rc 2; assert_line $'^@@error\tbad_args\t'
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/nope"; assert_rc 2; assert_line $'^@@error\tbad_args\t'
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --files "$T_HOME/list"; assert_rc 2; assert_line $'^@@error\tbad_args\t'
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list" extra; assert_rc 2; assert_line $'^@@error\tbad_args\t'
  assert_nothing_moved
}

# ───────────── uninstall: running app, Finder denied ─────────────
test_uninstall_running_app() {
  mk_home; mk_foo; stub pgrep 'exit 0'; require_stub pgrep
  ulist "$T_HOME/Library/Preferences/com.example.foo.plist"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 1; assert_protocol; assert_line $'^@@error\trunning\t'; assert_nothing_moved
  assert_called '^pgrep -f .*Foo.*app/Contents/MacOS/'
}

test_uninstall_validation_comes_before_running_check() {
  mk_home; mk_foo; stub pgrep 'exit 0'; require_stub pgrep
  ulist /etc/hosts
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t'; assert_no_line $'^@@error\trunning'; assert_not_called '^pgrep'; assert_nothing_moved
}

test_uninstall_dry_run_ignores_running() {
  mk_home; mk_foo; stub pgrep 'exit 0'; require_stub pgrep; : > "$T_HOME/list"
  engine --dry-run --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 0; assert_no_line $'^@@error'; assert_nothing_moved
}

test_uninstall_never_asks() {
  mk_home; mk_foo; stub pgrep 'exit 0'; stub osascript 'exit 0'; require_stub pgrep osascript; : > "$T_HOME/list"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_no_line $'^@@error\tinteractive'; assert_not_called '^osascript'
}

test_uninstall_finder_denied() {
  mk_home; mk_app "$T_HOME/Applications" Foo com.example.foo; : > "$T_HOME/list"
  stub osascript 'echo "Not authorized to send Apple events to Finder. (-1743)" >&2; exit 1'
  engine_finder --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 1; assert_line $'^@@error\tfinder_denied\t'; assert_exists "$T_HOME/Applications/Foo.app"
  assert_called '^osascript '
}

test_uninstall_through_finder_passes_exact_paths() {
  mk_home; mk_foo; stub osascript 'exit 0'
  ulist "$T_HOME/Library/Preferences/com.example.foo.plist"
  engine_finder --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 0
  assert_called "^osascript .* $T_HOME/Applications/Foo\\.app $T_HOME/Library/Preferences/com\\.example\\.foo\\.plist\$"
}

# ───────────── hardening: newlines in folder names, case-insensitive volumes ─────────────
test_apps_list_ignores_paths_with_newlines() {
  mk_home; mk_app "$T_HOME/Applications" Foo com.example.foo
  mkdir -p "$T_HOME/Applications/evil"$'\n'"victim"$'\n'"x.app" "$T_HOME/Applications/a"$'\n'"b/Deep.app"
  engine --engine apps-list
  assert_rc 0; assert_line $'^@@row\tappname\tFoo\t'
  [ "$(printf '%s\n' "$OUT" | grep -c '^@@row')" = 1 ] || fail "only Foo should be listed"
  engine --engine apps-scan 90; assert_rc 0; assert_line $'^@@meta\ttotal\t1$'
}

test_uninstall_rejects_injected_app_lines() {
  mk_home; mk_foo; : > "$T_HOME/list"
  mkdir -p "$T_HOME/cwd/victim" "$T_HOME/Applications/Utilities/Util.app" "$T_HOME/Applications/Utilities"$'\n'"z.app"
  mkfile "$T_HOME/cwd/victim/f" 1
  cd "$T_HOME/cwd" || fail "cd"          # a relative app path must never resolve against this
  engine --engine uninstall victim --list "$T_HOME/list"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t'; assert_exists "$T_HOME/cwd/victim/f"
  engine --engine uninstall-plan victim; assert_rc 2
  engine --engine uninstall "$T_HOME/Applications/Utilities" --list "$T_HOME/list"
  assert_rc 2; assert_exists "$T_HOME/Applications/Utilities/Util.app"
  [ -z "$(ls -A "$T_HOME/.Trash" 2>/dev/null)" ] || fail "something reached the Trash"
}

test_is_listed_app_needs_a_real_app_folder() {
  mk_home; mk_foo
  mkdir -p "$T_HOME/Applications/Real.app"; ln -s "$T_HOME/Applications/Real.app" "$T_HOME/Applications/Link.app"
  printf '%s\n' "$T_HOME/Applications/Real.app" "$T_HOME/Applications/Link.app" "$T_HOME/Applications/Gone.app" "rel.app" > "$T_HOME/al"
  engine_eval "is_listed_app $(printf %q "$T_HOME/Applications/Real.app") $(printf %q "$T_HOME/al") && echo LISTED"
  printf '%s\n' "$OUT" | grep -q LISTED || fail "control: a real listed app must count"
  for a in "$T_HOME/Applications/Link.app" "$T_HOME/Applications/Gone.app" rel.app ""; do
    engine_eval "is_listed_app $(printf %q "$a") $(printf %q "$T_HOME/al") && echo LISTED"
    ! printf '%s\n' "$OUT" | grep -q LISTED || fail "'$a' must not count as a listed app"
  done
}

# Is the volume case-insensitive (APFS default)? The case tests below only mean something there.
case_insensitive() { mkdir -p "$T_HOME/Library/Preferences" && [ -d "$T_HOME/LIBRARY/preferences" ]; }

test_uninstall_rejects_differently_cased_leftover_dir() {
  mk_home; mk_foo; mkfile "$T_HOME/Library/Preferences/ByHost/other-app.plist" 1
  ulist "$T_HOME/Library/Preferences/BYHOST"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t'; assert_exists "$T_HOME/Library/Preferences/ByHost/other-app.plist"; assert_nothing_moved
  ulist "$T_HOME/library/preferences/com.example.foo.plist"          # parent not spelled exactly: refused
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 2; assert_nothing_moved
}

test_uninstall_dedupes_differently_cased_spellings() {
  mk_home; mk_foo
  case_insensitive || return 0
  ulist "$T_HOME/Library/Preferences/com.example.foo.plist" "$T_HOME/Library/Preferences/COM.EXAMPLE.FOO.PLIST"
  engine --engine uninstall "$T_HOME/Applications/Foo.app" --list "$T_HOME/list"
  assert_rc 0; assert_exists "$T_HOME/.Trash/com.example.foo.plist"
  [ "$(ls -A "$T_HOME/.Trash" | wc -l | tr -d ' ')" = 2 ] || fail "same item twice should be moved once: $(ls -A "$T_HOME/.Trash")"
}

test_uninstall_rejects_app_spelled_with_other_case() {
  mk_home; mk_foo; : > "$T_HOME/list"
  engine --engine uninstall "$T_HOME/Applications/FOO.APP" --list "$T_HOME/list"
  assert_rc 2; assert_nothing_moved
}
