# Engine plumbing: parser, env/disk/set-lang, protocol helpers, Finder handling.

test_env_reports_meta() {
  mk_home; engine --engine env
  assert_rc 0; assert_protocol
  assert_line $'^@@meta\tversion\t[0-9]+\\.[0-9]+'
  assert_line $'^@@meta\tlang\ten$'
  assert_line $'^@@meta\tdry_run\t0$'
  assert_line $'^@@meta\thas_fda\t[01]$'
}
test_env_has_flags_follow_path() {
  mk_home; stub brew 'exit 0'; stub orb 'exit 0'
  engine --engine env
  assert_line $'^@@meta\thas_brew\t1$'
  assert_line $'^@@meta\thas_orb\t1$'
  assert_line $'^@@meta\thas_docker\t[01]$'
  assert_line $'^@@meta\thas_mas\t[01]$'
}
test_dry_run_flag_before_engine() { mk_home; engine --dry-run --engine env; assert_line $'^@@meta\tdry_run\t1$'; }
test_disk_record() { mk_home; engine --engine disk; assert_rc 0; assert_line $'^@@disk\t[0-9]+\t[0-9]+$'; }
test_unknown_command() { mk_home; engine --engine nope; assert_rc 2; assert_line $'^@@error\tunknown_command\t'; }
test_missing_command() { mk_home; engine --engine; assert_rc 2; assert_line $'^@@error\tbad_args\t'; }
test_confirm_never_prompts() {
  mk_home; engine --engine _probe-confirm
  assert_rc 1; assert_line $'^@@error\tinteractive\t'
}
test_set_lang_writes_shared_file() {
  mk_home; engine --engine set-lang id
  assert_rc 0; [ "$(cat "$T_HOME/.config/mac-cleaner/lang")" = id ] || fail "lang file"
}
test_set_lang_rejects_other_values() {
  mk_home; engine --engine set-lang fr
  assert_rc 2; assert_line $'^@@error\tbad_args\t'
  assert_missing "$T_HOME/.config/mac-cleaner/lang"
  engine --engine set-lang
  assert_rc 2; assert_line $'^@@error\tbad_args\t'
}
test_no_ansi() { mk_home; engine --engine env; assert_no_line $'\033'; }
test_fields_sanitized() {
  mk_home; engine --engine $'no\tpe'          # unknown command whose name contains a TAB
  assert_rc 2; assert_line $'^@@error\tunknown_command\t[^\t]*no pe[^\t]*$'
}
test_cli_help_unchanged() {
  mk_home; OUT=$(HOME="$T_HOME" /bin/bash "$SCRIPT" --help); assert_no_line 'engine'
}

test_log_helpers_emit_records() {
  mk_home; engine_eval 'say "a b"; info i; ok o; warn w; err e; progress p; progress_done'
  assert_rc 0; assert_protocol
  assert_line $'^@@log\tsay\ta b$'
  assert_line $'^@@log\tinfo\ti$'
  assert_line $'^@@log\tok\to$'
  assert_line $'^@@log\twarn\tw$'
  assert_line $'^@@log\terr\te$'
  assert_line $'^@@progress\tp$'
  assert_no_line $'\033'
}
test_progress_step_emits_step_and_total() {
  mk_home; engine_eval 'progress_step 2 5 "Scanning"'
  assert_line $'^@@progress\tScanning\t2\t5$'
}
test_emit_sanitizes_tabs_and_newlines() {
  mk_home; engine_eval $'emit meta k "a\tb\nc"'
  assert_line $'^@@meta\tk\ta b c$'
}
test_prompts_fail_without_reading() {
  mk_home; engine_eval 'ask "q?"; echo "ask=$?"; confirm_word X; echo "word=$?"; pause; echo "pause=$?"'
  assert_line '^ask=1$'; assert_line '^word=1$'; assert_line '^pause=1$'
  assert_line $'^@@error\tinteractive\t'
}
test_report_freed_dry_run_emits_zero() {
  mk_home; engine_eval 'report_freed 0' --dry-run
  assert_line $'^@@freed\t0$'
  assert_line $'^@@disk\t[0-9]+\t[0-9]+$'
}
test_report_freed_emits_positive_kb() {
  mk_home; engine_eval 'report_freed 0'    # "before" of 0 means any free space counts as freed
  assert_line $'^@@freed\t[1-9][0-9]*$'
  assert_line $'^@@disk\t[0-9]+\t[0-9]+$'
}
test_read_list_skips_blank_lines() {
  mk_home; printf 'a b\n\n  \n/c\n' > "$T_HOME/list"
  engine_eval 'read_list "$H/list"; echo "n=${#LIST[@]}"; echo "0=${LIST[0]}"; echo "1=${LIST[1]}"'
  assert_line '^n=2$'; assert_line '^0=a b$'; assert_line '^1=/c$'
}

test_move_to_trash_home_mode_never_calls_osascript() {
  mk_home; stub osascript 'exit 0'; require_stub osascript
  mkfile "$T_HOME/x/f" 1
  engine_eval 'move_to_trash "$H/x"; echo "rc=$?"'
  assert_line '^rc=0$'; assert_missing "$T_HOME/x"; assert_exists "$T_HOME/.Trash/x"
  assert_not_called 'osascript'
}
test_finder_denied_stops_without_retry_or_mv() {
  mk_home
  stub osascript 'echo "execution error: Not authorized to send Apple events to Finder. (-1743)" >&2; exit 1'
  require_stub osascript
  mkfile "$T_HOME/a/f" 1; mkfile "$T_HOME/b/f" 1
  engine_finder_eval 'move_to_trash "$H/a" "$H/b"; echo "rc=$?"'
  assert_line '^rc=1$'
  assert_line $'^@@error\tfinder_denied\t'
  assert_exists "$T_HOME/a/f"; assert_exists "$T_HOME/b/f"; assert_missing "$T_HOME/.Trash"
  [ "$(wc -l < "$T_BIN/calls.log" | tr -d ' ')" = 1 ] || fail "expected exactly one osascript call"
}
test_osa_finder_return_codes() {
  mk_home
  stub osascript 'case "$*" in *denied*) echo "(-1743)" >&2; exit 1 ;; *bad*) echo oops >&2; exit 1 ;; esac; exit 0'
  require_stub osascript
  engine_finder_eval 'osa_finder ok; echo "ok=$?"; osa_finder bad; echo "bad=$?"; osa_finder denied; echo "denied=$?"'
  assert_line '^ok=0$'; assert_line '^bad=1$'; assert_line '^denied=2$'
}
test_other_finder_failure_retries_each_item() {
  mk_home
  stub osascript 'echo oops >&2; exit 1'
  require_stub osascript
  mkfile "$T_HOME/a/f" 1; mkfile "$T_HOME/b/f" 1
  engine_finder_eval 'move_to_trash "$H/a" "$H/b"; echo "rc=$?"'
  assert_line '^rc=1$'; assert_no_line 'finder_denied'
  [ "$(wc -l < "$T_BIN/calls.log" | tr -d ' ')" = 3 ] || fail "expected 1 batch + 2 single osascript calls"
  assert_exists "$T_HOME/a/f"
}

test_askpass_helper_is_executable() {
  [ -x "$ROOT/app/Resources/askpass.sh" ] || fail "app/Resources/askpass.sh is not executable"
  /bin/bash -n "$ROOT/app/Resources/askpass.sh" || fail "askpass.sh syntax"
}

test_require_stub_fails_when_stub_missing() {
  mk_home
  ( require_stub zz-no-such-tool ) 2>/dev/null; [ $? -ne 0 ] || fail "require_stub passed for a missing tool"
  ( require_stub ls ) 2>/dev/null;              [ $? -ne 0 ] || fail "require_stub accepted a real tool that is not a stub"
  stub zz-fake 'exit 0'
  ( require_stub zz-fake ) 2>/dev/null;         [ $? -eq 0 ] || fail "require_stub rejected a stub that exists"
}
test_engine_finder_requires_osascript_stub() {
  mk_home
  ( engine_finder --engine env ) 2>/dev/null;               [ $? -ne 0 ] || fail "engine_finder ran without an osascript stub"
  ( engine_finder_eval 'true' ) 2>/dev/null;                [ $? -ne 0 ] || fail "engine_finder_eval ran without an osascript stub"
  stub osascript 'exit 0'
  ( engine_finder --engine env; [ "$RC" = 0 ] ) 2>/dev/null || fail "engine_finder refused with a stub present"
}
test_disk_record_survives_failing_df() {
  mk_home; stub df 'exit 1'
  engine --engine disk
  assert_rc 0; assert_line $'^@@disk\t0\t0$'
}
test_report_freed_disk_record_survives_failing_df() {
  mk_home; stub df 'exit 1'
  engine_eval 'report_freed 0' --dry-run
  assert_line $'^@@disk\t0\t0$'
  engine_eval 'report_freed 0'
  assert_line $'^@@freed\t0$'; assert_line $'^@@disk\t0\t0$'
}

# Docker Desktop installed without admin rights puts its CLI in ~/.docker/bin; pnpm lives in ~/Library/pnpm.
# Only engine mode adds them, so the CLI's PATH (and output) stay as they were.
test_engine_path_adds_docker_desktop_and_pnpm_bins() {
  mk_home; mkdir -p "$T_HOME/.docker/bin" "$T_HOME/Library/pnpm"
  engine_eval 'printf "%s\n" "$PATH" | tr ":" "\n"'
  assert_line "^$T_HOME/\\.docker/bin\$"; assert_line "^$T_HOME/Library/pnpm\$"
}
test_cli_path_is_unchanged() {
  mk_home; mkdir -p "$T_HOME/.docker/bin" "$T_HOME/Library/pnpm"
  OUT=$(env HOME="$T_HOME" PATH="$T_BIN:$PATH" /bin/bash -c "$(sed '$d' "$SCRIPT")"$'\n''printf "%s\n" "$PATH" | tr ":" "\n"' \
        "$SCRIPT" --lang en </dev/null 2>/dev/null)
  assert_no_line "^$T_HOME/\\.docker/bin\$"; assert_no_line "^$T_HOME/Library/pnpm\$"
}
test_engine_path_skips_missing_dirs() {
  mk_home
  engine_eval 'printf "%s\n" "$PATH" | tr ":" "\n"'
  assert_no_line "^$T_HOME/\\.docker/bin\$"; assert_no_line "^$T_HOME/Library/pnpm\$"
}
