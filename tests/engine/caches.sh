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
