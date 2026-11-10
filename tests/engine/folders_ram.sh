# Engine: bigdata-scan, ram-scan and ram-purge.

test_bigdata_scan_rows() {
  mk_home; mkfile "$T_HOME/BigProject/blob" 3000
  engine --engine bigdata-scan
  assert_rc 0; assert_protocol; assert_line $'^@@meta\tfda\t[01]$'
  assert_line "^@@row"$'\t'"dir"$'\t'"[0-9]+"$'\t'"$T_HOME/BigProject\$"
}
test_bigdata_skips_protected_home_folders() {
  mk_home; mkfile "$T_HOME/Documents/x" 3000; mkfile "$T_HOME/Downloads/x" 3000; mkfile "$T_HOME/BigProject/blob" 3000
  engine --engine bigdata-scan
  assert_rc 0; assert_no_line "$T_HOME/Documents"; assert_no_line "$T_HOME/Downloads"
  assert_line "$T_HOME/BigProject"
}
test_bigdata_includes_library_locations() {
  mk_home; mkfile "$T_HOME/Library/Caches/com.foo/c" 2048; mkfile "$T_HOME/Library/Application Support/Foo/d" 2048
  engine --engine bigdata-scan
  assert_line "^@@row"$'\t'"dir"$'\t'"[0-9]+"$'\t'"$T_HOME/Library/Caches\$"
  assert_line "^@@row"$'\t'"dir"$'\t'"[0-9]+"$'\t'"$T_HOME/Library/Application Support/Foo\$"
}
test_bigdata_sorted_largest_first() {
  mk_home; mkfile "$T_HOME/Small/b" 100; mkfile "$T_HOME/Large/b" 5000
  engine --engine bigdata-scan
  printf '%s\n' "$OUT" | awk -F'\t' '$2=="dir"{ if (NR_ > 0 && $3 > prev) bad = 1; prev = $3; NR_++ } END{ exit bad }' || fail "dir rows not sorted largest first"
}

test_ram_scan_shape() {
  mk_home; engine --engine ram-scan
  assert_rc 0; assert_protocol
  for k in total app wired comp cached used swap level; do assert_line "^@@meta"$'\t'"$k"$'\t'; done
  assert_line $'^@@row\tmemapp\t[0-9]+\t/.+\\.app\t[^\t]+\t[^\t]*\t[01]$'
}

# ram_rows unit tests: ps is stubbed with a fixed process table
mk_ps_table() {
  mk_home
  local body i
  body=$'cat <<\'PSEOF\'\n'
  body+=$'900000 /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder\n'
  body+=$'800000 /Applications/Term.app/Contents/MacOS/Term\n'
  body+=$'750000 /Applications/Docker.app/Contents/MacOS/Docker\n'
  i=1
  while [ "$i" -le 14 ]; do body+="$((700000 - i * 1000)) /Applications/App$i.app/Contents/MacOS/App$i"$'\n'; i=$((i + 1)); done
  body+=$'500000 /usr/libexec/something\n'
  body+=$'400000 /System/Library/Frameworks/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine\n'
  body+=$'300000 /opt/homebrew/bin/node\n'
  body+=$'200000 /opt/homebrew/bin/postgres\n'
  body+=$'150000 /usr/local/bin/p1\n140000 /usr/local/bin/p2\n130000 /usr/local/bin/p3\n'
  body+=$'1000 /bin/small\n'
  body+=$'PSEOF'
  stub ps "$body"; require_stub ps
}
test_ram_rows_caps_apps_and_marks_host() {
  mk_ps_table
  engine_eval 'mktmp; o=$MKTMP; ram_rows /Applications/Term.app "$o"; cat "$o"'
  assert_rc 0
  assert_line $'^memapp\t800000\t/Applications/Term.app\tTerm\t\t1$'                       # host: listed, host=1
  assert_line $'^memapp\t750000\t/Applications/Docker.app\tDocker\tstops containers\t0$'  # note, host=0
  assert_line $'^memapp\t[0-9]+\t/Applications/App11.app\tApp11\t\t0$'
  assert_no_line '/Applications/App12.app'                                                 # host row does not count toward the 12
  assert_no_line 'Finder'                                                                  # /System/Library/* skipped
  [ "$(printf '%s\n' "$OUT" | grep -c '^memapp')" = 13 ] || fail "expected 12 numbered apps + the host row"
}
test_ram_rows_without_host_numbers_12() {
  mk_ps_table
  engine_eval 'mktmp; o=$MKTMP; ram_rows "" "$o"; cat "$o"'
  assert_no_line $'\t1$'
  assert_line '/Applications/Term.app'
  [ "$(printf '%s\n' "$OUT" | grep -c '^memapp')" = 12 ] || fail "expected exactly 12 apps"
}
test_ram_rows_procs_threshold_cap_and_vm_note() {
  mk_ps_table
  engine_eval 'mktmp; o=$MKTMP; ram_rows "" "$o"; cat "$o"'
  assert_line $'^memproc\t400000\tcom.apple.Virtualization.VirtualMachine\tVM: Docker/OrbStack/UTM — see menu 2$'
  assert_line $'^memproc\t300000\tnode\t$'
  assert_no_line $'\tp3\t'                      # 6th process is beyond the cap of 5
  assert_no_line $'\tsmall\t'                   # under 100 MB
  assert_no_line 'something'                    # /usr/libexec is part of macOS
  [ "$(printf '%s\n' "$OUT" | grep -c '^memproc')" = 5 ] || fail "expected 5 processes"
}

test_ram_purge_dry_run() {
  mk_home; stub osascript 'exit 0'; require_stub osascript
  engine --dry-run --engine ram-purge
  assert_rc 0; assert_protocol; assert_not_called '^osascript'
  assert_line $'^@@log\tsay\t.*\\[dry-run\\]'
  assert_line $'^@@meta\tcached_before\t[0-9]+$'; assert_line $'^@@meta\tcached_after\t[0-9]+$'
}
test_ram_purge_cancelled() {
  mk_home; stub osascript 'echo "User canceled. (-128)" >&2; exit 1'; stub sudo 'exit 0'; stub purge 'exit 0'
  require_stub osascript sudo purge
  engine --engine ram-purge
  assert_rc 1; assert_protocol; assert_line $'^@@error\tcancelled\t'; assert_no_line '^@@meta.cached_after'
  assert_called '^osascript .*purge'; assert_not_called '^(sudo|purge)'
}
test_ram_purge_success() {
  mk_home; stub osascript 'exit 0'; require_stub osascript
  engine --engine ram-purge
  assert_rc 0; assert_protocol
  assert_line $'^@@meta\tcached_before\t[0-9]+$'; assert_line $'^@@meta\tcached_after\t[0-9]+$'
  assert_called '^osascript -e do shell script "/usr/sbin/purge" with administrator privileges$'
}
test_ram_purge_other_failure() {
  mk_home; stub osascript 'echo "execution error: boom (1)" >&2; exit 1'; require_stub osascript
  engine --engine ram-purge
  assert_rc 1; assert_protocol; assert_line $'^@@log\terr\t'; assert_no_line '^@@meta.cached_after'
}
