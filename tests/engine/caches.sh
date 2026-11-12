# Engine: caches-scan and caches-clean.

# A fresh HOME where brew/go/pnpm are inert stubs, so init_paths can't pick up the real machine's cache locations.
mk_caches_home() { mk_home; stub brew 'exit 0'; stub go 'exit 0'; stub pnpm 'exit 0'; require_stub brew go pnpm; }

test_caches_scan_lists_fake_caches() {
  mk_caches_home; mkfile "$T_HOME/.npm/_cacache/blob" 2048; mkfile "$T_HOME/Library/Logs/x.log" 1100
  engine --engine caches-scan
  assert_rc 0; assert_protocol
  assert_line $'^@@row\tcache\tnpm\t[0-9]+\tsafe\tnpm / npx cache$'
  assert_line $'^@@row\tcache\tlogs\t[0-9]+\tsafe\t'
  assert_line $'^@@meta\ttotal_safe\t[0-9]+$'
  assert_line $'^@@meta\ttotal_heavy\t[0-9]+$'
}
test_caches_scan_empty_home() { mk_caches_home; engine --engine caches-scan; assert_rc 0; assert_no_line $'^@@row\tcache\t(npm|logs|yarn|libcaches)\t'; }
test_caches_scan_hides_under_1mb() { mk_caches_home; mkfile "$T_HOME/.npm/_cacache/b" 10; engine --engine caches-scan; assert_no_line $'^@@row\tcache\tnpm\t'; }
test_caches_scan_totals_split_by_kind() {
  mk_caches_home; mkfile "$T_HOME/.npm/_cacache/b" 2048; mkfile "$T_HOME/.m2/repository/b" 3072
  engine --engine caches-scan
  assert_line $'^@@row\tcache\tmaven\t[0-9]+\theavy\t'
  assert_line $'^@@meta\ttotal_safe\t[0-9]+$'
  # the safe total counts npm (2 MB), not maven (3 MB): 2048..2100 KB, heavy 3072..3150 KB
  printf '%s\n' "$OUT" | awk -F'\t' '$2=="total_safe"{ exit !($3>=2048 && $3<3072) }' || fail "total_safe out of range"
  printf '%s\n' "$OUT" | awk -F'\t' '$2=="total_heavy"{ exit !($3>=3072 && $3<4096) }' || fail "total_heavy out of range"
}
test_caches_clean_dry_run_keeps_files() {
  mk_caches_home; mkfile "$T_HOME/.npm/_cacache/blob" 2048
  engine --dry-run --engine caches-clean npm
  assert_rc 0; assert_exists "$T_HOME/.npm/_cacache/blob"; assert_line $'^@@freed\t0$'
  assert_line $'^@@disk\t[0-9]+\t[0-9]+$'
}
test_caches_clean_removes_contents_keeps_folder() {
  mk_caches_home; mkfile "$T_HOME/.npm/_cacache/blob" 2048; mkfile "$T_HOME/Library/Caches/com.foo/c" 2048
  engine --engine caches-clean npm libcaches
  assert_rc 0; assert_missing "$T_HOME/.npm/_cacache/blob"; assert_exists "$T_HOME/.npm/_cacache"
  assert_missing "$T_HOME/Library/Caches/com.foo/c"; assert_line $'^@@freed\t[0-9]+$'
}
test_caches_clean_rejects_unknown_id() {
  mk_caches_home; mkfile "$T_HOME/.npm/_cacache/blob" 2048
  engine --engine caches-clean npm 'rm -rf'
  assert_rc 2; assert_line $'^@@error\tbad_args\t'
  assert_exists "$T_HOME/.npm/_cacache/blob"      # nothing ran, not even the valid id
}
test_caches_clean_rejects_multiword_arg() {
  mk_caches_home; mkfile "$T_HOME/.npm/_cacache/blob" 2048
  engine --engine caches-clean 'npm yarn'          # two ids glued into one arg
  assert_rc 2; assert_line $'^@@error\tbad_args\t'
  assert_exists "$T_HOME/.npm/_cacache/blob"
}
test_caches_clean_requires_an_id() {
  mk_caches_home; engine --engine caches-clean
  assert_rc 2; assert_line $'^@@error\tbad_args\t'
}
test_caches_clean_trash_finder_denied() {
  mk_caches_home; stub osascript 'echo "execution error: Not authorized to send Apple events to Finder. (-1743)" >&2; exit 1'
  require_stub osascript
  engine --engine caches-clean trash
  assert_rc 1
  assert_line $'^@@error\tfinder_denied\t'
  assert_called '^osascript .*empty trash'
}
test_caches_clean_trash_uses_finder() {
  mk_caches_home; stub osascript 'exit 0'; require_stub osascript
  engine --engine caches-clean trash
  assert_rc 0; assert_no_line $'^@@error\t'
  assert_called '^osascript -e tell application "Finder" to empty trash'
  assert_line $'^@@freed\t[0-9]+$'
}
test_caches_clean_trash_dry_run_skips_finder() {
  mk_caches_home; stub osascript 'exit 0'; require_stub osascript
  engine --dry-run --engine caches-clean trash
  assert_rc 0; assert_not_called '^osascript'
}
test_caches_clean_trash_dry_run_prints_old_osascript_line() {
  mk_caches_home; stub osascript 'exit 0'; require_stub osascript
  engine --dry-run --engine caches-clean trash
  assert_line $'\\[dry-run\\].* osascript -e tell application "Finder" to empty trash'
  assert_no_line 'osa_finder'
  assert_not_called '^osascript'
}
test_caches_clean_trash_cli_failure_shows_native_error() {
  mk_caches_home; stub osascript 'echo "execution error: boom (-600)" >&2; exit 1'; require_stub osascript
  # CLI mode (ENGINE=0) inside the loaded script; the real Finder path, because MAC_CLEANER_TRASH is not consulted here
  engine_eval 'ENGINE=0; init_paths; cache_def trash; cache_clean trash'
  printf '%s\n' "$ERR" | grep -q 'execution error: boom (-600)' || fail "stub's stderr not shown in CLI mode"
  printf '%s\n%s\n' "$OUT" "$ERR" | grep -q "Couldn't empty the Trash" && fail "generic warning printed in CLI mode"
  assert_called '^osascript .*empty trash'
}
test_caches_clean_trash_engine_failure_warns_without_raw_error() {
  mk_caches_home; stub osascript 'echo "execution error: boom (-600)" >&2; exit 1'; require_stub osascript
  engine --engine caches-clean trash
  assert_rc 0
  assert_line $'^@@log\twarn\tCouldn\'t empty the Trash\\.'
  assert_no_line 'boom'
  [ -z "$ERR" ] || fail "raw osascript error leaked to stderr in engine mode"
}

# The KB of one cache row in $OUT, or nothing when the row is missing.
row_kb() { printf '%s\n' "$OUT" | awk -F'\t' -v id="$1" '$1=="@@row" && $2=="cache" && $3==id { print $4 }'; }
assert_row_kb() {  # assert_row_kb id min max → the row exists with min <= KB < max
  local kb; kb=$(row_kb "$1")
  [ -n "$kb" ] && [ "$kb" -ge "$2" ] && [ "$kb" -lt "$3" ] || fail "$1 row: ${kb:-missing}, want $2..$(($3 - 1)) KB"
}

# Homebrew keeps api/ (its formula/cask catalog) and rebuilds bootsnap/ on every run, so `brew cleanup` never frees them.
test_caches_scan_brew_skips_api_and_bootsnap() {
  mk_caches_home
  mkfile "$T_HOME/Library/Caches/Homebrew/api/formula.jws.json" 2048
  mkfile "$T_HOME/Library/Caches/Homebrew/bootsnap/cache" 2048
  engine --engine caches-scan
  assert_rc 0; assert_no_line $'^@@row\tcache\tbrew\t'
}
test_caches_scan_brew_counts_downloads_only() {
  mk_caches_home
  mkfile "$T_HOME/Library/Caches/Homebrew/api/formula.jws.json" 2048
  mkfile "$T_HOME/Library/Caches/Homebrew/bootsnap/cache" 2048
  mkfile "$T_HOME/Library/Caches/Homebrew/downloads/abc--wget.tar.gz" 2048
  engine --engine caches-scan
  assert_row_kb brew 2048 3072
}

# A pnpm store at ~/pnpm-store/v11 (what the pnpm stub reports) with 2 MB in its global virtual store (links/), and a
# registered project ~/proj with its own node_modules/.pnpm, so nothing links into links/. PS = the store.
mk_pnpm_store() {
  mk_caches_home
  stub pnpm 'case "$1 $2" in "store path") echo "$HOME/pnpm-store/v11" ;; esac; exit 0'
  PS="$T_HOME/pnpm-store/v11"
  mkfile "$PS/links/@/a/1.0.0/h/node_modules/a/blob" 2048
  mkfile "$PS/index.db" 2048                       # pnpm's index: prune keeps it, so it is not counted
  mkdir -p "$PS/projects" "$T_HOME/proj/node_modules/.pnpm/a@1.0.0/node_modules/a"
  ln -s .pnpm/a@1.0.0/node_modules/a "$T_HOME/proj/node_modules/a"
  ln -s ../../../proj "$PS/projects/abc"           # relative, like pnpm's registry
}
# links_into_store <dir> → a node_modules entry in <dir> that points into the store's links/ (a project using it)
link_into_store() { mkdir -p "$1"; ln -s "$PS/links/@/a/1.0.0/h/node_modules/a" "$1/a"; }

test_caches_scan_pnpm_counts_orphaned_links_only() {
  mk_pnpm_store
  engine --engine caches-scan
  assert_rc 0; assert_protocol
  assert_row_kb pnpm 2048 3072
}
test_caches_clean_pnpm_prunes_then_removes_orphaned_links() {
  mk_pnpm_store
  engine --engine caches-clean pnpm
  assert_rc 0; assert_called '^pnpm store prune'
  assert_missing "$PS/links/@"; assert_exists "$PS/links"; assert_exists "$PS/index.db"
  assert_line $'^@@log\tinfo\tpnpm: .*links'
}
test_caches_pnpm_links_used_by_a_project_are_kept() {
  mk_pnpm_store; link_into_store "$T_HOME/proj/node_modules/@scope"
  engine --engine caches-scan
  assert_no_line $'^@@row\tcache\tpnpm\t'
  engine --engine caches-clean pnpm
  assert_called '^pnpm store prune'; assert_exists "$PS/links/@/a/1.0.0/h/node_modules/a/blob"
}
test_caches_pnpm_unreadable_project_counts_as_using_links() {
  mk_pnpm_store
  trap 'chmod -R u+rwx "$T_HOME/proj" 2>/dev/null' EXIT
  chmod 000 "$T_HOME/proj/node_modules"
  engine --engine caches-scan
  assert_no_line $'^@@row\tcache\tpnpm\t'
  engine --engine caches-clean pnpm
  assert_exists "$PS/links/@/a/1.0.0/h/node_modules/a/blob"
}
test_caches_pnpm_deleted_project_does_not_hold_links() {
  mk_pnpm_store; rm -rf "$T_HOME/proj"
  engine --engine caches-scan
  assert_row_kb pnpm 2048 3072
  engine --engine caches-clean pnpm
  assert_missing "$PS/links/@"
}
test_caches_pnpm_without_registry_keeps_links() {
  mk_pnpm_store; rm -rf "$PS/projects"
  engine --engine caches-scan
  assert_no_line $'^@@row\tcache\tpnpm\t'
  engine --engine caches-clean pnpm
  assert_exists "$PS/links/@/a/1.0.0/h/node_modules/a/blob"
}
test_caches_pnpm_dlx_cache_using_links_keeps_them() {
  mk_pnpm_store; link_into_store "$T_HOME/Library/Caches/pnpm/dlx/h1/12345/node_modules"
  engine --engine caches-scan
  assert_no_line $'^@@row\tcache\tpnpm\t'
  engine --engine caches-clean pnpm
  assert_exists "$PS/links/@/a/1.0.0/h/node_modules/a/blob"
}
test_caches_pnpm_global_install_using_links_keeps_them() {
  mk_pnpm_store; link_into_store "$T_HOME/Library/pnpm/global/v11/g1/node_modules"
  engine --engine caches-scan
  assert_no_line $'^@@row\tcache\tpnpm\t'
}
test_caches_clean_pnpm_dry_run_keeps_links() {
  mk_pnpm_store
  engine --dry-run --engine caches-clean pnpm
  assert_rc 0; assert_not_called '^pnpm store prune'
  assert_exists "$PS/links/@/a/1.0.0/h/node_modules/a/blob"
  assert_line '\[dry-run\].*pnpm-store/v11/links'
}
