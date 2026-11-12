# Engine: self-update-check and self-update-apply.
#
# SAFETY: nothing here reaches the network or the real app. stub_self_update writes stubs for curl (it only copies
# file:// URLs, anything else fails) and codesign, and tests/lib.sh refuses to run a self-update command without them.
# The release JSON and zip are built under $T_HOME, MAC_CLEANER_RELEASE_API points at them, the app being replaced is a
# fake one under $T_HOME/Applications, and the old version goes to $T_HOME/.Trash.

SU_CUR=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$SCRIPT" | head -1)
SU_NEW=99.0.0
SU_ID=io.github.ahmadrio.mac-cleaner

# stub_self_update → curl (file:// only; $HOME/curl-fail exists → every call fails) and codesign ($HOME/codesign-fail → fails)
stub_self_update() {
  stub curl '[ -e "$HOME/curl-fail" ] && exit 7
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o|-H|--max-time) [ "$1" = -o ] && out="$2"; shift ;; -*) ;; *) url="$1" ;; esac
  shift
done
case "$url" in file://*) ;; *) exit 6 ;; esac
src="${url#file://}"; [ -f "$src" ] || exit 37
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi'
  stub codesign '[ -e "$HOME/codesign-fail" ] && exit 1; exit 0'
  require_stub curl codesign
}

# mk_self_app dir version [bundle-id] → dir/Mac Cleaner.app with that version and the engine script inside
mk_self_app() {
  local a="$1/Mac Cleaner.app"
  mkdir -p "$a/Contents/MacOS" "$a/Contents/Resources"
  plutil -create xml1 "$a/Contents/Info.plist" \
    && plutil -insert CFBundleIdentifier -string "${3:-$SU_ID}" "$a/Contents/Info.plist" \
    && plutil -insert CFBundleShortVersionString -string "$2" "$a/Contents/Info.plist" || fail "plutil failed for $a"
  printf 'binary %s\n' "$2" > "$a/Contents/MacOS/MacCleaner"
  printf '# engine %s\n' "$2" > "$a/Contents/Resources/mac-cleaner.command"
}

APP_PATH() { printf '%s' "$T_HOME/Applications/Mac Cleaner.app"; }
app_ver() { plutil -extract CFBundleShortVersionString raw "$(APP_PATH)/Contents/Info.plist" 2>/dev/null; }

# su_setup [tag [zip-version [zip-bundle-id]]] → the installed app (SU_CUR), a release zip and its JSON; exports the env
su_setup() {
  local tag="${1:-v$SU_NEW}" zv="${2:-$SU_NEW}" zid="${3:-$SU_ID}" ver sha size
  mk_home; stub_self_update
  mk_self_app "$T_HOME/Applications" "$SU_CUR"
  mkdir -p "$T_HOME/build"
  mk_self_app "$T_HOME/build" "$zv" "$zid"
  ver=${tag#v}
  SU_ZIP="$T_HOME/rel/Mac-Cleaner-$ver.zip"
  mkdir -p "$T_HOME/rel"
  ditto -c -k --keepParent "$T_HOME/build/Mac Cleaner.app" "$SU_ZIP" || fail "ditto failed"
  sha=$(shasum -a 256 "$SU_ZIP" | awk '{print $1}'); size=$(stat -f %z "$SU_ZIP")
  su_json "$tag" "file://$SU_ZIP" "sha256:$sha" "$size"
  export MAC_CLEANER_RELEASE_API="file://$T_HOME/rel/latest.json" MAC_CLEANER_APP="$(APP_PATH)"
}

# su_json tag url digest size [asset-name] → $T_HOME/rel/latest.json
su_json() {
  local name="${5:-Mac-Cleaner-${1#v}.zip}"
  mkdir -p "$T_HOME/rel"
  printf '{"tag_name":"%s","html_url":"https://example.test/rel","body":"First line\\r\\n\\twith a tab\\n- second","assets":[{"name":"other.zip","browser_download_url":"file:///nope","digest":"sha256:x","size":1},{"name":"%s","browser_download_url":"%s","digest":"%s","size":%s}]}' \
    "$1" "$name" "$2" "$3" "$4" > "$T_HOME/rel/latest.json"
}

assert_app_untouched() {
  [ "$(app_ver)" = "$SU_CUR" ] || fail "the installed app changed: version $(app_ver)"
  [ "$(ls -A "$T_HOME/Applications")" = "Mac Cleaner.app" ] || fail "Applications holds: $(ls -A "$T_HOME/Applications")"
}

# ───────────── self-update-check ─────────────
test_self_update_check_newer() {
  su_setup
  engine --engine self-update-check
  assert_rc 0; assert_protocol
  assert_line $'^@@meta\tcurrent\t'"$SU_CUR"'$'
  assert_line $'^@@meta\tlatest\t'"$SU_NEW"'$'
  assert_line $'^@@meta\tnewer\t1$'
  assert_line $'^@@meta\tpage\thttps://example.test/rel$'
  assert_line $'^@@meta\tsize\t[1-9][0-9]*$'
  assert_line $'^@@row\tnote\tFirst line$'
  assert_line $'^@@row\tnote\t with a tab$'
  assert_line $'^@@row\tnote\t- second$'
  assert_called "^curl .*file://$T_HOME/rel/latest.json"
}

test_self_update_check_up_to_date() {
  su_setup "v$SU_CUR" "$SU_CUR"
  engine --engine self-update-check
  assert_rc 0
  assert_line $'^@@meta\tlatest\t'"$SU_CUR"'$'
  assert_line $'^@@meta\tnewer\t0$'
}

test_self_update_check_offline() {
  su_setup; touch "$T_HOME/curl-fail"
  engine --engine self-update-check
  assert_rc 1; assert_protocol
  assert_line $'^@@error\toffline\t'
  assert_no_line $'^@@meta\t'
}

test_self_update_check_bad_release() {
  su_setup "latest"            # a tag that isn't a version
  engine --engine self-update-check
  assert_rc 1; assert_line $'^@@error\tbad_release\t'
  su_setup; su_json "v$SU_NEW" "file://$SU_ZIP" "sha256:abc" 10    # no proper sha256 digest
  engine --engine self-update-check
  assert_rc 1; assert_line $'^@@error\tbad_release\t'
  su_setup; su_json "v$SU_NEW" "file://$SU_ZIP" "sha256:$(printf '%064d' 0)" 10 "Mac-Cleaner.zip"   # no zip by that name
  engine --engine self-update-check
  assert_rc 1; assert_line $'^@@error\tbad_release\t'
  su_setup; printf 'not json' > "$T_HOME/rel/latest.json"
  engine --engine self-update-check
  assert_rc 1; assert_line $'^@@error\tbad_release\t'
}

# Without MAC_CLEANER_RELEASE_API the zip must be this repo's release asset, and the page one of its pages.
test_self_update_release_urls_without_override() {
  local d; d="sha256:$(printf '%064d' 0)"
  su_setup; unset MAC_CLEANER_RELEASE_API
  su_json "v$SU_NEW" "file://$SU_ZIP" "$d" 10
  engine_eval 'SU_API="file://$HOME/rel/latest.json"; su_release; echo "rc=$? url=$SU_URL"'
  assert_line $'^@@error\tbad_release\t'; assert_line '^rc=1 '
  su_json "v$SU_NEW" "https://github.com/ahmadrio/mac-cleaner/releases/download/v$SU_NEW/Mac-Cleaner-$SU_NEW.zip" "$d" 10
  engine_eval 'SU_API="file://$HOME/rel/latest.json"; su_release; echo "rc=$? page=$SU_PAGE"'
  assert_no_line '^@@error'
  # the JSON's page (example.test) isn't this repo's, so the repo's own releases page is used
  assert_line '^rc=0 page=https://github.com/ahmadrio/mac-cleaner/releases/latest$'
}

test_self_update_bad_args() {
  su_setup
  engine --engine self-update-check now
  assert_rc 2; assert_line $'^@@error\tbad_args\t'
  for a in "" "1.x" "../1" ".1" "1..2"; do
    engine --engine self-update-apply "$a"
    assert_rc 2; assert_line $'^@@error\tbad_args\t'
  done
  engine --engine self-update-apply
  assert_rc 2
  assert_not_called '^curl '
}

# ───────────── self-update-apply ─────────────
test_self_update_apply_replaces_app() {
  su_setup
  export LC_ALL=en_US.UTF-8   # bash 3.2 in a UTF-8 locale would read "$SU_LATEST…" as a longer variable name
  engine --engine self-update-apply "$SU_NEW"
  assert_rc 0; assert_protocol
  assert_line $'^@@progress\tDownloading Mac Cleaner '"$SU_NEW"'…$'
  assert_line $'^@@meta\treplaced\t1$'
  assert_line $'^@@meta\tapp\t'"$(APP_PATH)"'$'
  [ "$(app_ver)" = "$SU_NEW" ] || fail "app not replaced: version $(app_ver)"
  grep -q "engine $SU_NEW" "$(APP_PATH)/Contents/Resources/mac-cleaner.command" || fail "new engine missing"
  assert_exists "$T_HOME/.Trash/Mac Cleaner $SU_CUR.app/Contents/Info.plist"
  [ "$(ls -A "$T_HOME/Applications")" = "Mac Cleaner.app" ] || fail "leftovers: $(ls -A "$T_HOME/Applications")"
  assert_called "^codesign --verify --deep --strict "
}

test_self_update_apply_dry_run_keeps_app() {
  su_setup
  engine --dry-run --engine self-update-apply "$SU_NEW"
  assert_rc 0; assert_protocol
  assert_line $'^@@meta\treplaced\t0$'
  assert_line 'dry-run'
  assert_app_untouched
  assert_missing "$T_HOME/.Trash"
}

test_self_update_apply_wrong_digest() {
  su_setup; su_json "v$SU_NEW" "file://$SU_ZIP" "sha256:$(printf '%064d' 0 | tr 0 a)" 10
  engine --engine self-update-apply "$SU_NEW"
  assert_rc 1; assert_line $'^@@error\tbad_download\t'
  assert_no_line $'^@@meta\treplaced'
  assert_app_untouched
}

test_self_update_apply_rejects_other_contents() {
  su_setup "v$SU_NEW" "$SU_NEW" com.example.other     # another app's bundle id
  engine --engine self-update-apply "$SU_NEW"
  assert_rc 1; assert_line $'^@@error\tbad_download\t'; assert_app_untouched
  su_setup "v$SU_NEW" 98.0.0                          # the zip holds another version than the release says
  engine --engine self-update-apply "$SU_NEW"
  assert_rc 1; assert_line $'^@@error\tbad_download\t'; assert_app_untouched
  su_setup; touch "$T_HOME/codesign-fail"             # the signature doesn't check out
  engine --engine self-update-apply "$SU_NEW"
  assert_rc 1; assert_line $'^@@error\tbad_download\t'; assert_app_untouched
  su_setup; printf 'not a zip' > "$SU_ZIP"            # not a zip at all (the JSON is rebuilt with its digest)
  su_json "v$SU_NEW" "file://$SU_ZIP" "sha256:$(shasum -a 256 "$SU_ZIP" | awk '{print $1}')" 9
  engine --engine self-update-apply "$SU_NEW"
  assert_rc 1; assert_line $'^@@error\tbad_download\t'; assert_app_untouched
}

test_self_update_apply_stale_or_not_newer() {
  su_setup
  engine --engine self-update-apply 98.0.0
  assert_rc 1; assert_line $'^@@error\tstale\t'; assert_app_untouched
  su_setup "v$SU_CUR" "$SU_CUR"
  engine --engine self-update-apply "$SU_CUR"
  assert_rc 1; assert_line $'^@@error\tup_to_date\t'; assert_app_untouched
}

test_self_update_apply_needs_the_app() {
  su_setup; export MAC_CLEANER_APP="/private/var/folders/xx/T/AppTranslocation/ABC/d/Mac Cleaner.app"
  engine --engine self-update-apply "$SU_NEW"
  assert_rc 1; assert_line $'^@@error\ttranslocated\t'
  su_setup; unset MAC_CLEANER_APP
  engine --engine self-update-apply "$SU_NEW"
  assert_rc 1; assert_line $'^@@error\tnot_app\t'
  su_setup; rm -rf "$(APP_PATH)"; mk_self_app "$T_HOME/Applications" "$SU_CUR" com.example.other
  engine --engine self-update-apply "$SU_NEW"
  assert_rc 1; assert_line $'^@@error\tnot_app\t'
  assert_not_called '^curl '
}

# macOS refusing the move (App Management) leaves the app as it was.
test_self_update_apply_app_management() {
  su_setup
  stub mv 'case "$1" in */Applications/"Mac Cleaner.app") echo "mv: rename $1: Operation not permitted" >&2; exit 1 ;; esac
exec /bin/mv "$@"'
  engine --engine self-update-apply "$SU_NEW"
  assert_rc 1; assert_line $'^@@error\tapp_management\t'
  assert_app_untouched
}

# The new app can't take the old one's place: the old one is put back.
test_self_update_apply_puts_old_app_back() {
  su_setup
  stub mv 'case "$1" in */.mac-cleaner-update.*/"Mac Cleaner.app") echo "mv: cannot move" >&2; exit 1 ;; esac
exec /bin/mv "$@"'
  engine --engine self-update-apply "$SU_NEW"
  assert_rc 1; assert_line $'^@@error\treplace_failed\t'
  assert_no_line $'^@@meta\treplaced'
  assert_app_untouched
}
