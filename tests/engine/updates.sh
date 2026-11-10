# Engine: updates-scan and updates-apply.
#
# SAFETY: this Mac may have real Homebrew, mas (App Store), curl and apps. Every test here goes through stub_brew, which
# writes stubs for brew, mas, curl, open and pgrep and calls require_stub on all five. tests/lib.sh refuses to run any
# updates command (or updates function) without them as well. Fixture apps live only under $T_HOME/Applications
# (the harness sets MAC_CLEANER_APP_DIRS) and real moves go to $T_HOME/.Trash (MAC_CLEANER_TRASH=home).
# catalog_lines / cask_info_lines run the real osascript -l JavaScript on local files only (read-only).
# The catalog is seeded fresh, so cask_catalog never calls curl; if it did, it would reach the curl stub.

# brew_stub_body → fake `brew`. Canned answers; the cask lines come from files under $HOME so a test can change them:
#   $HOME/brew-cask-out   output of `brew outdated --cask …`        $HOME/brew-formula-out  output for --formula (default: wget)
#   $HOME/brew-info.json  output of `brew info --cask --json=v2 …`  $HOME/brew-fail          exists → upgrade/install exit 1
brew_stub_body() {
  cat <<'STUB'
case "$*" in
  update*) exit 0 ;;
  "list --cask -1") [ -f "$HOME/brew-list" ] && cat "$HOME/brew-list"; exit 0 ;;
  "outdated --formula --verbose")
    if [ -f "$HOME/brew-formula-out" ]; then cat "$HOME/brew-formula-out"; else echo 'wget (1.21.3) < 1.24.5'; fi ;;
  "outdated --cask "*) [ -f "$HOME/brew-cask-out" ] && cat "$HOME/brew-cask-out"; exit 0 ;;
  "info --cask --json=v2 "*) [ -f "$HOME/brew-info.json" ] && cat "$HOME/brew-info.json"; exit 0 ;;
  upgrade*|install*) [ -e "$HOME/brew-fail" ] && exit 1; exit 0 ;;
esac
exit 0
STUB
}

# stub_brew → brew, mas, curl, open, pgrep stubs and the guard. pgrep says "not running"; curl always fails (no network).
stub_brew() {
  stub brew "$(brew_stub_body)"
  stub mas 'exit 0'
  stub curl 'exit 22'
  stub open 'exit 0'
  stub pgrep 'exit 1'
  require_stub brew mas curl open pgrep
}

# seed_catalog → a fresh Homebrew catalog with one cask, foo (so cask_catalog does not need the network)
seed_catalog() {
  mkdir -p "$T_HOME/Library/Caches/mac-cleaner"
  printf '%s' '[{"token":"foo","version":"2.0","homepage":"https://foo.example","artifacts":[{"app":["Foo.app"]}]}]' \
    > "$T_HOME/Library/Caches/mac-cleaner/cask.json"
}

# mk_versioned_app_in dir name ver → dir/name.app, bundle id com.example.<lowercase name>, CFBundleShortVersionString ver
mk_versioned_app_in() {
  local id; id=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  mk_app "$1" "$2" "com.example.$id"
  plutil -insert CFBundleShortVersionString -string "$3" "$1/$2.app/Contents/Info.plist" || fail "plutil failed for $2"
}
mk_versioned_app() { mk_versioned_app_in "$T_HOME/Applications" "$1" "$2"; }

# foo_dmg_row → the list row for Foo.app (a dmg update); WGET_ROW → one for the wget formula
foo_dmg_row() { printf 'dmg\tFoo\t1.0\t2.0\tfoo\t%s\thttps://foo.example\n' "$T_HOME/Applications/Foo.app"; }
WGET_ROW=$'formula\twget\t1.21.3\t1.24.5\twget\t\t'

# ───────────── updates-scan ─────────────
test_updates_scan_rows() {
  mk_home; stub_brew; mk_versioned_app Foo 1.0; seed_catalog
  engine --engine updates-scan
  assert_rc 0; assert_protocol
  assert_line $'^@@row\tupdate\tformula\twget\t1\\.21\\.3\t1\\.24\\.5\tHomebrew\twget\t\t$'
  assert_line "^@@row"$'\t'"update"$'\t'"dmg"$'\t'"Foo"$'\t'"1.0"$'\t'"2.0"$'\t'"[^"$'\t'"]+"$'\t'"foo"$'\t'"$T_HOME/Applications/Foo.app"$'\t'"https://foo.example\$"
  assert_line $'^@@meta\toffline\t0$'
  assert_line $'^@@meta\thas_brew\t1$'; assert_line $'^@@meta\tpinned\t0$'; assert_line $'^@@meta\tauto_skip\t$'
  assert_line $'^@@meta\tmas_n\t0$'; assert_line $'^@@meta\thas_mas\t1$'
  assert_not_called '^curl'; assert_called '^brew update'
}
test_updates_scan_offline_catalog() {
  mk_home; stub_brew; mk_versioned_app Foo 1.0   # no catalog: cask_catalog asks curl, which fails
  engine --engine updates-scan
  assert_rc 0; assert_called '^curl '
  assert_line $'^@@meta\toffline\t1$'; assert_line $'^@@row\tupdate\tformula\twget\t'; assert_no_line $'^@@row\tupdate\tdmg\t'
  assert_line $'^@@log\twarn\tCouldn.t read Homebrew.s catalog'
}
test_updates_scan_up_to_date_app_is_not_listed() {
  mk_home; stub_brew; mk_versioned_app Foo 2.0; seed_catalog
  engine --engine updates-scan
  assert_no_line $'^@@row\tupdate\tdmg\t'; assert_line $'^@@meta\toffline\t0$'
}
test_updates_scan_pinned_formula_is_counted_not_listed() {
  mk_home; stub_brew; seed_catalog
  printf 'wget (1.21.3) < 1.24.5 [pinned at 1.21.3]\n' > "$T_HOME/brew-formula-out"
  engine --engine updates-scan
  assert_no_line $'^@@row\tupdate\tformula\t'; assert_line $'^@@meta\tpinned\t1$'
}
test_updates_scan_cask_row() {
  mk_home; stub_brew; seed_catalog
  printf 'bar (1.0) != 2.0\n' > "$T_HOME/brew-cask-out"
  printf '%s' '{"casks":[{"token":"bar","auto_updates":false,"artifacts":[{"app":["Bar.app"]}]}]}' > "$T_HOME/brew-info.json"
  engine --engine updates-scan
  assert_line $'^@@row\tupdate\tcask\tbar\t1\\.0\t2\\.0\tHomebrew cask\tbar\t\t$'
}
test_updates_scan_self_updating_cask_without_app_is_skipped() {
  mk_home; stub_brew; seed_catalog
  printf 'bar (1.0) != 2.0\n' > "$T_HOME/brew-cask-out"
  printf '%s' '{"casks":[{"token":"bar","auto_updates":true,"artifacts":[{"app":["Bar.app"]}]}]}' > "$T_HOME/brew-info.json"
  engine --engine updates-scan
  assert_no_line $'^@@row\tupdate\tcask\t'; assert_line $'^@@meta\tauto_skip\tbar$'
}
test_updates_scan_sparkle_row() {
  mk_home; stub_brew; seed_catalog; mk_versioned_app Spk 1.0
  plutil -insert SUFeedURL -string "https://spk.example/feed.xml" "$T_HOME/Applications/Spk.app/Contents/Info.plist" || fail plutil
  stub curl 'case "$*" in *formulae.brew.sh*) exit 22 ;; *) echo "<sparkle:shortVersionString>3.0</sparkle:shortVersionString>" ;; esac'
  require_stub curl
  engine --engine updates-scan
  assert_line "^@@row"$'\t'"update"$'\t'"sparkle"$'\t'"Spk"$'\t'"1.0"$'\t'"3.0"$'\t'"[^"$'\t'"]+"$'\t\t'"$T_HOME/Applications/Spk.app"$'\t$'
}
test_updates_scan_mas_apps() {
  mk_home; stub_brew; seed_catalog; mk_versioned_app Store 1.0; mkdir -p "$T_HOME/Applications/Store.app/Contents/_MASReceipt"
  stub mas 'case "$1" in outdated) echo "497799835  Store  (1.0 -> 1.5)" ;; esac; exit 0'; require_stub mas
  engine --engine updates-scan
  assert_line $'^@@row\tupdate\tmas\tStore\t1\\.0\t1\\.5\tApp Store\t497799835\t\t$'
  assert_line $'^@@meta\tmas_n\t0$'
}
test_updates_scan_mas_apps_without_mas_are_counted() {
  mk_home; stub_brew; seed_catalog; mk_versioned_app Store 1.0; mkdir -p "$T_HOME/Applications/Store.app/Contents/_MASReceipt"
  engine_eval 'has() { [ "$1" != mas ] && command -v "$1" >/dev/null 2>&1; }; ENGINE_ARGS=(updates-scan); engine_dispatch'
  assert_line $'^@@meta\tmas_n\t1$'; assert_line $'^@@meta\thas_mas\t0$'; assert_no_line $'^@@row\tupdate\tmas\t'
}
test_updates_scan_without_brew() {
  mk_home; stub_brew; seed_catalog; mk_versioned_app Foo 1.0
  engine_eval 'has() { [ "$1" != brew ] && command -v "$1" >/dev/null 2>&1; }; ENGINE_ARGS=(updates-scan); engine_dispatch'
  assert_rc 0; assert_line $'^@@meta\thas_brew\t0$'; assert_no_line $'^@@row\tupdate\tformula\t'
  assert_line $'^@@row\tupdate\tdmg\tFoo\t1\\.0\t2\\.0\tdownload page\tfoo\t'
  assert_not_called '^brew'
}
test_updates_scan_takes_no_arguments() {
  mk_home; stub_brew
  engine --engine updates-scan extra
  assert_rc 2; assert_line $'^@@error\tbad_args\t'; assert_not_called '^brew'
}

# ───────────── updates-apply ─────────────
test_updates_apply_runs_selected() {
  mk_home; stub_brew; mk_versioned_app Foo 1.0
  printf '%s\n%s\n' "$WGET_ROW" "$(foo_dmg_row)" > "$T_HOME/list"
  engine --engine updates-apply --list "$T_HOME/list"
  assert_rc 0; assert_protocol; assert_called '^brew upgrade --formula wget$'; assert_called '^brew install --cask foo$'
  assert_exists "$T_HOME/.Trash/Foo.app"; assert_missing "$T_HOME/Applications/Foo.app"
  assert_not_called '^brew update'   # the scan does that, apply does not
}
test_updates_apply_groups_formulae_casks_and_mas() {
  mk_home; stub_brew
  printf 'formula\twget\t1\t2\twget\t\t\nformula\tjq\t1\t2\tjq\t\t\ncask\tbar\t1\t2\tbar\t\t\nmas\tStore\t1\t2\t497799835\t\t\n' > "$T_HOME/list"
  engine --engine updates-apply --list "$T_HOME/list"
  assert_rc 0
  assert_called '^brew upgrade --formula wget jq$'; assert_called '^brew upgrade --cask bar$'; assert_called '^mas upgrade 497799835$'
}
test_updates_apply_sets_homebrew_env() {
  mk_home; stub_brew
  stub brew 'echo "env:$HOMEBREW_NO_AUTO_UPDATE:$HOMEBREW_NO_ENV_HINTS"; exit 0'; require_stub brew
  printf '%s\n' "$WGET_ROW" > "$T_HOME/list"
  engine --engine updates-apply --list "$T_HOME/list"
  assert_line '^env:1:1$'
}
test_updates_apply_sparkle_opens_the_app() {
  mk_home; stub_brew; mk_versioned_app Spk 1.0
  printf 'sparkle\tSpk\t1.0\t3.0\t\t%s\t\n' "$T_HOME/Applications/Spk.app" > "$T_HOME/list"
  engine --engine updates-apply --list "$T_HOME/list"
  assert_rc 0; assert_called "^open $T_HOME/Applications/Spk\\.app\$"; assert_exists "$T_HOME/Applications/Spk.app"
}
test_updates_apply_dmg_without_brew_opens_download_page() {
  mk_home; stub_brew; mk_versioned_app Foo 1.0
  foo_dmg_row > "$T_HOME/list"
  engine_eval 'has() { [ "$1" != brew ] && command -v "$1" >/dev/null 2>&1; }; ENGINE_ARGS=(updates-apply --list "$HOME/list"); engine_dispatch'
  assert_rc 0; assert_called '^open https://foo.example$'; assert_not_called '^brew '
  assert_exists "$T_HOME/Applications/Foo.app"
}
test_updates_apply_dry_run() {
  mk_home; stub_brew; mk_versioned_app Foo 1.0
  printf '%s\n%s\n' "$WGET_ROW" "$(foo_dmg_row)" > "$T_HOME/list"
  engine --dry-run --engine updates-apply --list "$T_HOME/list"
  assert_rc 0; assert_not_called '^brew (upgrade|install)'; assert_exists "$T_HOME/Applications/Foo.app"
  assert_line $'^@@log\tsay\t.*\\[dry-run\\].* brew upgrade --formula wget$'
  assert_line $'^@@log\tsay\t.*\\[dry-run\\].* brew install --cask foo$'
  assert_missing "$T_HOME/.Trash/Foo.app"
}
test_updates_apply_running_app_errors() {
  mk_home; stub_brew; stub pgrep 'exit 0'; stub osascript 'exit 0'; require_stub pgrep osascript; mk_versioned_app Foo 1.0
  foo_dmg_row > "$T_HOME/list"
  engine --engine updates-apply --list "$T_HOME/list"
  assert_rc 1; assert_line $'^@@error\trunning\t'; assert_not_called '^brew install'; assert_exists "$T_HOME/Applications/Foo.app"
  assert_not_called '^osascript'   # the engine never asks the app to quit; the user decides first
}
test_updates_apply_running_app_does_not_stop_other_rows() {
  mk_home; stub_brew; stub pgrep 'exit 0'; require_stub pgrep; mk_versioned_app Foo 1.0
  printf '%s\n%s\n' "$(foo_dmg_row)" "$WGET_ROW" > "$T_HOME/list"
  engine --engine updates-apply --list "$T_HOME/list"
  assert_rc 1; assert_line $'^@@error\trunning\t'; assert_called '^brew upgrade --formula wget$'; assert_not_called '^brew install'
}
test_updates_apply_failure_gives_exit_1() {
  mk_home; stub_brew; touch "$T_HOME/brew-fail"
  printf '%s\nmas\tStore\t1\t2\t497799835\t\t\n' "$WGET_ROW" > "$T_HOME/list"
  engine --engine updates-apply --list "$T_HOME/list"
  assert_rc 1; assert_called '^brew upgrade --formula wget$'; assert_called '^mas upgrade 497799835$'
}
test_updates_apply_failed_install_keeps_old_app_in_trash() {
  mk_home; stub_brew; touch "$T_HOME/brew-fail"; mk_versioned_app Foo 1.0
  foo_dmg_row > "$T_HOME/list"
  engine --engine updates-apply --list "$T_HOME/list"
  assert_rc 1; assert_exists "$T_HOME/.Trash/Foo.app"; assert_line $'^@@log\terr\tHomebrew couldn.t install foo'
}
test_updates_apply_duplicate_rows_run_once() {
  mk_home; stub_brew; mk_versioned_app Foo 1.0
  printf '%s\n%s\n%s\n%s\n' "$WGET_ROW" "$WGET_ROW" "$(foo_dmg_row)" "$(foo_dmg_row)" > "$T_HOME/list"
  engine --engine updates-apply --list "$T_HOME/list"
  assert_rc 0
  [ "$(grep -c '^brew upgrade --formula' "$T_BIN/calls.log")" = 1 ] || fail "formula upgraded more than once"
  assert_called '^brew upgrade --formula wget$'
  [ "$(grep -c '^brew install --cask' "$T_BIN/calls.log")" = 1 ] || fail "cask installed more than once"
}
test_updates_apply_empty_list_does_nothing() {
  mk_home; stub_brew; printf '\n  \n' > "$T_HOME/list"
  engine --engine updates-apply --list "$T_HOME/list"
  assert_rc 0; [ ! -s "$T_BIN/calls.log" ] || fail "something was called"
}

# every validation failure: exit 2, nothing runs, and a valid row before it does not run either
# _apply_rejects <row> <error-code>
_apply_rejects() {
  mk_home; stub_brew; mk_versioned_app Foo 1.0
  mkdir -p "$T_HOME/Elsewhere"; mk_versioned_app_in "$T_HOME/Elsewhere" Foo 1.0
  printf '%s\n%s\n' "$WGET_ROW" "$1" > "$T_HOME/list"
  engine --engine updates-apply --list "$T_HOME/list"
  assert_rc 2; assert_line "^@@error"$'\t'"$2"$'\t'; assert_protocol
  [ ! -s "$T_BIN/calls.log" ] || fail "something was called: $(cat "$T_BIN/calls.log")"
  assert_exists "$T_HOME/Applications/Foo.app"; assert_exists "$T_HOME/Elsewhere/Foo.app"
  [ -z "$(ls -A "$T_HOME/.Trash" 2>/dev/null)" ] || fail "something reached the Trash"
}
test_updates_apply_rejects_bad_token() {
  mk_home; stub_brew; printf 'formula\twget;rm\t1\t2\twget;rm\t\t\n' > "$T_HOME/list"
  engine --engine updates-apply --list "$T_HOME/list"; assert_rc 2; assert_line $'^@@error\tnot_allowed\t'; assert_not_called '^brew upgrade'
}
test_updates_apply_rejects_option_like_token()   { _apply_rejects $'formula\t-x\t1\t2\t--cask\t\t' not_allowed; }
test_updates_apply_rejects_token_with_slash()    { _apply_rejects $'cask\tbar\t1\t2\t../bar\t\t' not_allowed; }
test_updates_apply_rejects_empty_ref()           { _apply_rejects $'cask\tbar\t1\t2\t\t\t' not_allowed; }
test_updates_apply_rejects_unknown_kind()        { _apply_rejects $'pkg\tbar\t1\t2\tbar\t\t' not_allowed; }
test_updates_apply_rejects_non_digit_mas_id()    { _apply_rejects $'mas\tStore\t1\t2\t12a\t\t' not_allowed; }
test_updates_apply_rejects_mas_option_id()       { _apply_rejects $'mas\tStore\t1\t2\t-1\t\t' not_allowed; }
test_updates_apply_rejects_bad_homepage()        { _apply_rejects "dmg"$'\t'"Foo"$'\t'"1"$'\t'"2"$'\t'"foo"$'\t'"$T_HOME/Applications/Foo.app"$'\t'"javascript:alert(1)" not_allowed; }
test_updates_apply_rejects_dmg_without_app()     { _apply_rejects $'dmg\tFoo\t1\t2\tfoo\t\thttps://foo.example' not_allowed; }
test_updates_apply_rejects_sparkle_without_app() { _apply_rejects $'sparkle\tFoo\t1\t2\t\t\t' not_allowed; }
test_updates_apply_rejects_relative_app()        { _apply_rejects $'dmg\tFoo\t1\t2\tfoo\tApplications/Foo.app\t' not_allowed; }
test_updates_apply_rejects_app_outside_dirs() {
  mk_home; stub_brew; mkdir -p "$T_HOME/Elsewhere"; mk_versioned_app_in "$T_HOME/Elsewhere" Foo 1.0
  printf 'dmg\tFoo\t1.0\t2.0\tfoo\t%s\thttps://foo.example\n' "$T_HOME/Elsewhere/Foo.app" > "$T_HOME/list"
  engine --engine updates-apply --list "$T_HOME/list"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t'; assert_not_called '^brew install'; assert_exists "$T_HOME/Elsewhere/Foo.app"
}
test_updates_apply_rejects_app_that_is_a_symlink() {
  mk_home; stub_brew; mkdir -p "$T_HOME/Elsewhere"; mk_versioned_app_in "$T_HOME/Elsewhere" Foo 1.0
  mkdir -p "$T_HOME/Applications"; ln -s "$T_HOME/Elsewhere/Foo.app" "$T_HOME/Applications/Foo.app"
  foo_dmg_row > "$T_HOME/list"
  engine --engine updates-apply --list "$T_HOME/list"
  assert_rc 2; assert_line $'^@@error\tnot_allowed\t'; assert_not_called '^brew install'; assert_exists "$T_HOME/Elsewhere/Foo.app"
}
test_updates_apply_rejects_wrong_field_count()   { _apply_rejects $'formula\twget\t1\t2\twget' bad_args; }
test_updates_apply_rejects_too_many_fields()     { _apply_rejects $'formula\twget\t1\t2\twget\t\t\textra' bad_args; }
test_updates_apply_requires_list() {
  mk_home; stub_brew
  engine --engine updates-apply;                        assert_rc 2; assert_line $'^@@error\tbad_args\t'
  engine --engine updates-apply --list;                 assert_rc 2
  engine --engine updates-apply --list "$T_HOME/nope";  assert_rc 2
  printf '%s\n' "$WGET_ROW" > "$T_HOME/list"
  engine --engine updates-apply "$T_HOME/list";         assert_rc 2
  engine --engine updates-apply --list "$T_HOME/list" x; assert_rc 2
  [ ! -s "$T_BIN/calls.log" ] || fail "something was called"
}

# ───────────── valid_token / the guard ─────────────
test_valid_token() {
  mk_home; stub_brew
  local code
  code=$(cat <<'CODE'
for t in wget python@3.12 node-18 gcc+ a_b.c 1password; do valid_token "$t" && echo "ok:$t" || echo "bad:$t"; done
for t in "" -x --cask "a b" "a;b" "a/b" 'a$b' "é" "a"$'\n'"b" "a*" "x|y"; do valid_token "$t" && echo "ok:[$t]" || echo "bad:[$t]"; done
CODE
)
  engine_eval "$code"
  assert_line '^ok:wget$'; assert_line '^ok:python@3.12$'; assert_line '^ok:node-18$'; assert_line '^ok:gcc\+$'
  assert_line '^ok:a_b.c$'; assert_line '^ok:1password$'
  assert_no_line '^ok:\['; assert_line '^bad:\[\]$'; assert_line '^bad:\[-x\]$'; assert_line '^bad:\[é\]$'
}
test_updates_guard_refuses_without_stubs() {
  mk_home
  if ( engine --engine updates-scan ) 2>/dev/null; then fail "engine ran updates-scan with no stubs"; fi
  if ( engine --engine updates-apply --list /dev/null ) 2>/dev/null; then fail "engine ran updates-apply with no stubs"; fi
  if ( engine_eval 'updates_scan' ) 2>/dev/null; then fail "engine_eval ran updates code with no stubs"; fi
  [ ! -e "$T_BIN/calls.log" ] || fail "something was called"
}
