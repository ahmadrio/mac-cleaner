# Engine: docker-status, docker-start, docker-list, docker-rm and docker-prune.
#
# SAFETY: this Mac may run real Docker/OrbStack. Every test here goes through stub_docker_*, which writes stubs for
# docker, orb and open and then calls require_stub on all three. tests/lib.sh refuses to run any docker-* command or
# Docker function without them as well. Only the fixture in tests/docker_stub.sh is ever called.

. "$ROOT/tests/docker_stub.sh"

# _stub_docker_all <full|empty> → docker, orb, open (+ a no-op sleep, so report_freed does not wait 1 s) and the guard
_stub_docker_all() {
  stub docker "$(docker_stub_body "$1")"
  stub orb "$(orb_stub_body)"
  stub open "$(open_stub_body)"
  stub sleep 'exit 0'
  require_stub docker orb open sleep
}
stub_docker_running()       { _stub_docker_all full; }
stub_docker_running_empty() { _stub_docker_all empty; }
# stub_docker_stopped [N] → daemon down; after `orb start` (or `open -a Docker`) the first N `docker info` calls still fail
stub_docker_stopped() {
  _stub_docker_all full
  printf '%s\n' "${1:-0}" > "$T_HOME/.fake-docker-down"
}
# start tests need a real sleep (a short one, via MAC_CLEANER_DOCKER_POLL)
stub_docker_stopped_real_sleep() {
  stub_docker_stopped "$1"
  rm -f "$T_BIN/sleep"
  require_stub docker orb open
}

# eval code prefix: `has` honours $HIDE (space-separated tool names to pretend are not installed), so a test can get
# "no orb" or "no docker" even though this Mac has them (the real ones are never called; the stubs stand in)
HIDE_CODE=$'has() { case " $HIDE " in *" $1 "*) return 1 ;; esac; command -v "$1" >/dev/null 2>&1; }\n'

# ── the guard itself ──
test_guard_refuses_docker_without_stubs() {
  mk_home
  if ( engine --engine docker-status ) 2>/dev/null; then fail "engine ran a docker command with no stubs"; fi
  [ ! -e "$T_BIN/calls.log" ] || fail "something was called"
  if ( engine_eval 'docker_state' ) 2>/dev/null; then fail "engine_eval ran Docker code with no stubs"; fi
}
test_guard_needs_all_three_stubs() {
  mk_home; stub docker 'exit 0'; stub orb 'exit 0'   # no open
  if ( engine --engine docker-status ) 2>/dev/null; then fail "ran without an open stub"; fi
}

# ── docker_state ──
test_docker_state_values() {
  mk_home; stub_docker_running
  engine_eval "$HIDE_CODE"'
    HIDE=docker; echo "a=$(docker_state)"
    HIDE=""; echo "b=$(docker_state)"
    printf 1 > "$HOME/.fake-docker-down"; rm -f "$HOME/.fake-docker-started"
    echo "c=$(docker_state)"
    HIDE=orb; docker_app_present() { return 0; }; echo "d=$(docker_state)"
    docker_app_present() { return 1; }; echo "e=$(docker_state)"'
  assert_rc 0
  assert_line '^a=missing$'; assert_line '^b=running$'; assert_line '^c=stopped_orb$'
  assert_line '^d=stopped_desktop$'; assert_line '^e=stopped_other$'
}

# ── docker-status ──
test_docker_status_running() {
  mk_home; stub_docker_running
  engine --engine docker-status
  assert_rc 0; assert_protocol
  assert_line $'^@@meta\tstate\trunning$'; assert_line $'^@@meta\tengine\tOrbStack$'
  assert_line $'^@@meta\tcontainers\t3$'; assert_line $'^@@meta\trunning\t1$'
  assert_line $'^@@meta\timages\t4$'; assert_line $'^@@meta\tvolumes\t2$'
  assert_line $'^@@row\tdf\tImages\t4\t2\t634MB\t17MB \\(2%\\)$'
  assert_line $'^@@row\tdf\tBuild Cache\t7\t0\t1.2GB\t1.2GB$'
}
test_docker_status_engine_is_docker_without_orb() {
  mk_home; stub_docker_running
  engine_eval "$HIDE_CODE"'HIDE=orb; ENGINE_ARGS=(docker-status); engine_dispatch'
  assert_line $'^@@meta\tstate\trunning$'; assert_line $'^@@meta\tengine\tDocker$'
}
test_docker_status_stopped_orb() {
  mk_home; stub_docker_stopped
  engine --engine docker-status
  assert_rc 0; assert_line $'^@@meta\tstate\tstopped_orb$'; assert_line $'^@@meta\tengine\tOrbStack$'
  assert_no_line '^@@row'; assert_no_line $'^@@meta\tcontainers'
}
test_docker_status_stopped_desktop_and_other() {
  mk_home; stub_docker_stopped
  engine_eval "$HIDE_CODE"'HIDE=orb; docker_app_present() { return 0; }; ENGINE_ARGS=(docker-status); engine_dispatch'
  assert_line $'^@@meta\tstate\tstopped_desktop$'; assert_line $'^@@meta\tengine\tDocker$'
  engine_eval "$HIDE_CODE"'HIDE=orb; docker_app_present() { return 1; }; ENGINE_ARGS=(docker-status); engine_dispatch'
  assert_line $'^@@meta\tstate\tstopped_other$'
}
test_docker_status_missing() {
  mk_home; stub_docker_running
  engine_eval "$HIDE_CODE"'HIDE=docker; ENGINE_ARGS=(docker-status); engine_dispatch'
  assert_rc 0; assert_line $'^@@meta\tstate\tmissing$'; assert_no_line $'^@@meta\tengine'; assert_no_line '^@@row'
  assert_not_called '^docker '
}

# ── docker-start ──
test_docker_start_orb_becomes_ready() {
  mk_home; stub_docker_stopped_real_sleep 2   # the 3rd check after `orb start` succeeds
  export MAC_CLEANER_DOCKER_WAIT=20 MAC_CLEANER_DOCKER_POLL=0.1
  engine --engine docker-start
  assert_rc 0; assert_protocol
  assert_called '^orb start$'; assert_not_called '^open '
  assert_line $'^@@progress\t'; assert_line $'^@@progress\tWaiting for Docker to be ready…\t[0-9]+\t20$'
  assert_line $'^@@meta\tstate\trunning$'; assert_no_line '^@@error'
}
# the daemon launcher must not inherit the engine's stdout/stderr (the app's pipes): whatever orb/open print goes nowhere
test_docker_start_detaches_orb_stdio() {
  mk_home; stub_docker_stopped_real_sleep 0
  stub orb 'echo ORB-OUT; echo ORB-ERR >&2; touch "$HOME/.fake-docker-started"'
  require_stub docker orb open
  export MAC_CLEANER_DOCKER_WAIT=20 MAC_CLEANER_DOCKER_POLL=0.1
  engine --engine docker-start
  assert_rc 0; assert_protocol; assert_called '^orb start$'
  assert_no_line 'ORB-OUT'; printf '%s' "$ERR" | grep -q 'ORB-ERR' && fail "orb's stderr reached the engine's stderr"
  assert_line $'^@@meta\tstate\trunning$'
}
test_docker_start_detaches_desktop_stdio() {
  mk_home; stub_docker_stopped_real_sleep 0
  stub open 'echo OPEN-OUT; echo OPEN-ERR >&2; touch "$HOME/.fake-docker-started"'
  require_stub docker orb open
  export MAC_CLEANER_DOCKER_WAIT=20 MAC_CLEANER_DOCKER_POLL=0.1
  engine_eval "$HIDE_CODE"'HIDE=orb; docker_app_present() { return 0; }; ENGINE_ARGS=(docker-start); engine_dispatch'
  assert_rc 0; assert_called '^open -a Docker$'
  assert_no_line 'OPEN-OUT'; printf '%s' "$ERR" | grep -q 'OPEN-ERR' && fail "open's stderr reached the engine's stderr"
  assert_line $'^@@meta\tstate\trunning$'
}
test_docker_start_never_ready_times_out() {
  mk_home; stub_docker_stopped_real_sleep 1000000
  export MAC_CLEANER_DOCKER_WAIT=1 MAC_CLEANER_DOCKER_POLL=0.2
  engine --engine docker-start
  assert_rc 1; assert_called '^orb start$'; assert_line $'^@@error\tdocker_not_ready\t'
}
test_docker_start_desktop_when_no_orb() {
  mk_home; stub_docker_stopped_real_sleep 0
  export MAC_CLEANER_DOCKER_WAIT=20 MAC_CLEANER_DOCKER_POLL=0.1
  engine_eval "$HIDE_CODE"'HIDE=orb; docker_app_present() { return 0; }; ENGINE_ARGS=(docker-start); engine_dispatch'
  assert_rc 0; assert_called '^open -a Docker$'; assert_not_called '^orb '; assert_line $'^@@meta\tstate\trunning$'
}
test_docker_start_no_orb_no_desktop_is_not_ready() {
  mk_home; stub_docker_stopped_real_sleep 0
  engine_eval "$HIDE_CODE"'HIDE=orb; docker_app_present() { return 1; }; ENGINE_ARGS=(docker-start); engine_dispatch'
  assert_rc 1; assert_line $'^@@error\tdocker_not_ready\t'
  assert_not_called '^orb '; assert_not_called '^open '
}
test_docker_start_when_already_running() {
  mk_home; stub_docker_running
  engine --engine docker-start
  assert_rc 0; assert_not_called '^orb '; assert_not_called '^open '; assert_line $'^@@meta\tstate\trunning$'
}
test_docker_start_without_docker() {
  mk_home; stub_docker_running
  engine_eval "$HIDE_CODE"'HIDE=docker; ENGINE_ARGS=(docker-start); engine_dispatch'
  assert_rc 1; assert_line $'^@@error\tdocker_missing\t'; assert_not_called '^orb '
}
test_docker_start_takes_no_arguments() {
  mk_home; stub_docker_stopped
  engine --engine docker-start now
  assert_rc 2; assert_line $'^@@error\tbad_args\t'; assert_not_called '^orb '
}

# ── docker-list ──
test_docker_list_containers() {
  mk_home; stub_docker_running; engine --engine docker-list containers
  assert_rc 0; assert_protocol
  assert_line $'^@@row\tcontainer\tabc123def456\trunning\t2B\tweb\tnginx:latest$'
  assert_line $'^@@row\tcontainer\t999888777666\texited\t1kB\tmy old\tbusybox:1$'
}
test_docker_list_images_status() {
  mk_home; stub_docker_running; engine --engine docker-list images
  assert_rc 0; assert_protocol
  assert_line $'^@@row\timage\tnginx:latest\t187MB\t2 weeks ago\tin_use$'
  assert_line $'^@@row\timage\tpostgres:16\t430MB\t3 weeks ago\tin_use$'
  assert_line $'^@@row\timage\told:1\t5MB\t1 year ago\tunused$'
  assert_line $'^@@row\timage\tdddddddddddd\t12MB\t2 months ago\tdangling$'
}
test_docker_list_volumes() {
  mk_home; stub_docker_running; engine --engine docker-list volumes
  assert_rc 0; assert_protocol
  assert_line $'^@@row\tvolume\tpgdata\t1\t120MB\tdb$'
  assert_line $'^@@row\tvolume\told_cache\t0\t50MB\t$'     # the empty used_by field is kept
}
test_docker_list_empty() {
  mk_home; stub_docker_running_empty
  for t in containers images volumes; do
    engine --engine docker-list $t; assert_rc 0; assert_no_line '^@@row'
  done
}
test_docker_list_bad_type() {
  mk_home; stub_docker_running
  engine --engine docker-list networks; assert_rc 2; assert_line $'^@@error\tbad_args\t'
  engine --engine docker-list;          assert_rc 2; assert_line $'^@@error\tbad_args\t'
  engine --engine docker-list images x; assert_rc 2
}
test_docker_list_requires_running() {
  mk_home; stub_docker_stopped
  engine --engine docker-list images
  assert_rc 1; assert_line $'^@@error\tdocker_not_ready\t'; assert_no_line '^@@row'
}

test_docker_list_build_cache_largest_first() {
  mk_home; stub_docker_running
  engine --engine docker-list build-cache
  assert_rc 0; assert_protocol
  order=$(printf '%s\n' "$OUT" | awk -F '\t' '$2 == "buildcache" { printf "%s ", $3 }')
  [ "$order" = "bcbig01 bcnpm02 bcparent03 bcshared04 bcinuse05 " ] || fail "not largest first: $order"
  assert_line $'^@@row\tbuildcache\tbcbig01\t1.02GB\t2 months ago\texec.cachemount\tfalse\ttrue\t$'   # empty description kept
  assert_line $'^@@row\tbuildcache\tbcshared04\t4.096kB\t5 weeks ago\tregular\ttrue\ttrue\t\\[base 2/2\\] WORKDIR /app$'
  assert_line $'^@@row\tbuildcache\tbcinuse05\t93B\t3 hours ago\tregular\tfalse\tfalse\t\\[stage 1\\] COPY \\. \\.$'   # TAB → space
  assert_called '^docker buildx du --format '
}
test_docker_list_build_cache_empty() {
  mk_home; stub_docker_running_empty
  engine --engine docker-list build-cache; assert_rc 0; assert_no_line '^@@(row|error)'
}
test_docker_list_build_cache_needs_buildx() {
  mk_home; stub_docker_running; export DOCKER_NO_BUILDX=1
  engine --engine docker-list build-cache
  assert_rc 1; assert_line $'^@@error\tbuildx_missing\tPicking build cache entries needs docker buildx'; assert_no_line '^@@row'
}
test_docker_list_build_cache_du_failure() {
  mk_home; stub_docker_running; export DOCKER_BUILDX_DU_FAIL=1
  engine --engine docker-list build-cache
  assert_rc 1; assert_line $'^@@error\tdocker_failed\tCouldn\'t read the build cache\\.$'; assert_no_line '^@@row'
}
test_docker_list_build_cache_requires_running() {
  mk_home; stub_docker_stopped
  engine --engine docker-list build-cache
  assert_rc 1; assert_line $'^@@error\tdocker_not_ready\t'; assert_not_called '^docker buildx'
}

# ── docker-rm ──
test_docker_rm_containers() {
  mk_home; stub_docker_running; printf 'abc123def456\n\n111222333444\n' > "$T_HOME/list"
  engine --engine docker-rm containers --list "$T_HOME/list"
  assert_rc 0; assert_protocol
  assert_called '^docker rm -f abc123def456$'; assert_called '^docker rm -f 111222333444$'
  assert_line $'^@@progress\tRemoving container abc123def456\t1\t2$'
  assert_line $'^@@freed\t[0-9]+$'
}
test_docker_rm_images_skips_in_use() {
  mk_home; stub_docker_running; printf 'nginx:latest\nold:1\ndddddddddddd\n' > "$T_HOME/list"
  engine --engine docker-rm images --list "$T_HOME/list"
  assert_rc 0
  assert_called '^docker rmi old:1$'; assert_called '^docker rmi dddddddddddd$'; assert_not_called '^docker rmi nginx:latest$'
  assert_line $'^@@log\twarn\t1 image\\(s\\) skipped because a container uses them — remove the container first \\(Container tab\\)\\.$'
}
test_docker_rm_images_unknown_ref_is_skipped() {
  mk_home; stub_docker_running; printf 'ghost:1\n' > "$T_HOME/list"
  engine --engine docker-rm images --list "$T_HOME/list"
  assert_not_called '^docker rmi'; assert_line $'^@@log\twarn\tSkipped \\(image not found\\): ghost:1$'
}
test_docker_rm_volumes_skips_attached() {
  mk_home; stub_docker_running; printf 'pgdata\nold_cache\n' > "$T_HOME/list"
  engine --engine docker-rm volumes --list "$T_HOME/list"
  assert_rc 0
  assert_called '^docker volume rm old_cache$'; assert_not_called '^docker volume rm pgdata$'
  assert_line $'^@@log\twarn\t1 volume\\(s\\) skipped because a container uses them — remove the container first \\(Container tab\\)\\.$'
}
test_docker_rm_rechecks_live_not_from_list() {
  # the list names an in-use image and an attached volume with nothing saying so: both are still protected
  mk_home; stub_docker_running; printf 'postgres:16\n' > "$T_HOME/i"; printf 'pgdata\n' > "$T_HOME/v"
  printf 'old:1\n' >> "$T_HOME/i"; printf 'old_cache\n' >> "$T_HOME/v"   # controls: these two go through
  engine --engine docker-rm images --list "$T_HOME/i";  assert_called '^docker rmi old:1$'; assert_not_called '^docker rmi postgres'
  engine --engine docker-rm volumes --list "$T_HOME/v"; assert_called '^docker volume rm old_cache$'; assert_not_called '^docker volume rm pgdata'
}
test_docker_rm_passes_names_as_single_arguments() {
  # "my old" is a container name with a space; it reaches docker as one argument (as the id it resolves to)
  mk_home; stub_docker_running; export DOCKER_ARGC_LOG="$T_BIN/argc.log"
  printf 'my old\n' > "$T_HOME/list"
  engine --engine docker-rm containers --list "$T_HOME/list"
  assert_rc 0
  grep -qx '3:rm -f 999888777666' "$DOCKER_ARGC_LOG" || fail "'my old' did not reach docker as one id: $(cat "$DOCKER_ARGC_LOG")"
}
test_docker_rm_containers_skips_what_is_not_a_listed_id_or_name() {
  # '*', shell characters, a name that is not listed: none of them reaches docker
  mk_home; stub_docker_running; export DOCKER_ARGC_LOG="$T_BIN/argc.log"
  printf '*\nx;y $(id)\nghost\n' > "$T_HOME/list"
  engine --engine docker-rm containers --list "$T_HOME/list"
  assert_rc 0; assert_not_called '^docker rm'
  assert_line $'^@@log\twarn\tSkipped \\(container not found\\): \\*$'
  assert_line $'^@@log\twarn\tSkipped \\(container not found\\): ghost$'
}
test_docker_rm_containers_prefix_does_not_match() {
  # docker rm -f takes id prefixes; a prefix line must not remove (or even force-stop) abc123def456, which is running
  mk_home; stub_docker_running
  printf 'a\nabc\nabc123def45\n1\n' > "$T_HOME/list"
  engine --engine docker-rm containers --list "$T_HOME/list"
  assert_rc 0; assert_protocol; assert_not_called '^docker rm'
  assert_line $'^@@log\twarn\tSkipped \\(container not found\\): a$'
  assert_line $'^@@log\twarn\tSkipped \\(container not found\\): abc123def45$'
}
test_docker_rm_containers_by_name_and_id_removes_once() {
  mk_home; stub_docker_running
  printf 'web\nabc123def456\ndb\n' > "$T_HOME/list"   # web and abc123def456 are the same container
  engine --engine docker-rm containers --list "$T_HOME/list"
  assert_rc 0
  assert_called '^docker rm -f abc123def456$'; assert_called '^docker rm -f 111222333444$'
  [ "$(grep -c '^docker rm ' "$T_BIN/calls.log")" = 2 ] || fail "expected two docker rm calls: $(grep '^docker rm ' "$T_BIN/calls.log")"
}
test_docker_rm_containers_mixed_listed_and_unlisted() {
  mk_home; stub_docker_running; printf 'ab\n111222333444\n' > "$T_HOME/list"
  engine --engine docker-rm containers --list "$T_HOME/list"
  assert_rc 0; assert_called '^docker rm -f 111222333444$'; assert_not_called '^docker rm -f ab'
  assert_line $'^@@progress\tRemoving container 111222333444\t1\t1$'
}
test_docker_rm_duplicate_lines_run_once() {
  mk_home; stub_docker_running
  printf 'abc123def456\nabc123def456\n111222333444\nabc123def456\n' > "$T_HOME/c"
  printf 'old:1\nold:1\ndddddddddddd\ndddddddddddd\nold:1\n' > "$T_HOME/i"
  printf 'old_cache\nold_cache\n' > "$T_HOME/v"
  engine --engine docker-rm containers --list "$T_HOME/c"; assert_rc 0
  engine --engine docker-rm images --list "$T_HOME/i";     assert_rc 0
  engine --engine docker-rm volumes --list "$T_HOME/v";    assert_rc 0
  [ "$(grep -c '^docker rm -f abc123def456$' "$T_BIN/calls.log")" = 1 ] || fail "container removed more than once"
  [ "$(grep -c '^docker rmi old:1$' "$T_BIN/calls.log")" = 1 ] || fail "image old:1 removed more than once"
  [ "$(grep -c '^docker rmi dddddddddddd$' "$T_BIN/calls.log")" = 1 ] || fail "dangling image removed more than once"
  [ "$(grep -c '^docker volume rm old_cache$' "$T_BIN/calls.log")" = 1 ] || fail "volume removed more than once"
}
test_docker_rm_containers_accepts_full_id() {
  mk_home; stub_docker_running
  printf 'abc123def456%s\n' "$(printf '%052d' 0)" > "$T_HOME/list"
  engine --engine docker-rm containers --list "$T_HOME/list"
  assert_rc 0; assert_called '^docker rm -f abc123def456$'
}
test_docker_rm_containers_name_clash_uses_full_id() {
  # a container named exactly like web's short id: `docker rm -f abc123def456` would pick that one (names win over
  # id prefixes), so docker gets web's full id
  mk_home; stub_docker_running; export DOCKER_NAME_CLASH=1
  printf 'abc123def456\n' > "$T_HOME/list"
  engine --engine docker-rm containers --list "$T_HOME/list"
  assert_rc 0; assert_called "^docker rm -f abc123def456$(printf '%052d' 0)\$"; assert_not_called '^docker rm -f abc123def456$'
  assert_not_called '^docker rm -f 555666777888'
}
test_docker_rm_images_fails_closed_when_in_use_check_fails() {
  # docker can't say which images containers use: nothing is removed (rather than treating every image as unused)
  mk_home; stub_docker_running; export DOCKER_PS_FAIL=1
  printf 'old:1\nnginx:latest\n' > "$T_HOME/list"
  engine --engine docker-rm images --list "$T_HOME/list"
  assert_rc 1; assert_not_called '^docker rmi'
  assert_line $'^@@log\terr\tCouldn\'t check which images containers use — nothing was removed\\.$'
}
test_docker_rm_images_fails_closed_when_inspect_fails() {
  # docker inspect answers for one container, then fails: an image used by another container must not look unused
  mk_home; stub_docker_running; export DOCKER_INSPECT_FAIL=1
  printf 'old:1\nnginx:latest\n' > "$T_HOME/list"
  engine --engine docker-rm images --list "$T_HOME/list"
  assert_rc 1; assert_not_called '^docker rmi'
}
test_docker_rm_containers_fails_when_docker_cant_list_them() {
  mk_home; stub_docker_running; export DOCKER_PS_FAIL=1
  printf 'abc123def456\n' > "$T_HOME/list"
  engine --engine docker-rm containers --list "$T_HOME/list"
  assert_rc 1; assert_not_called '^docker rm'
  assert_line $'^@@log\terr\tCouldn\'t read the container list — nothing was removed\\.$'
}
test_docker_no_arg_commands_refuse_extra_args() {
  mk_home; stub_docker_running
  engine --engine docker-status extra; assert_rc 2; assert_line $'^@@error\tbad_args\tdocker-status takes no arguments$'
  assert_no_line '^@@meta'
}
test_docker_rm_refuses_option_like_lines() {
  mk_home; stub_docker_running
  for t in containers images volumes; do
    printf 'good\n-f\n' > "$T_HOME/list"
    engine --engine docker-rm $t --list "$T_HOME/list"
    assert_rc 2; assert_line $'^@@error\tnot_allowed\t-f$'
    printf -- '--all\n' > "$T_HOME/list"
    engine --engine docker-rm $t --list "$T_HOME/list"
    assert_rc 2; assert_line $'^@@error\tnot_allowed\t--all$'
  done
  assert_not_called '^docker (rm|rmi|volume rm)'
}
test_docker_rm_requires_list() {
  mk_home; stub_docker_running
  engine --engine docker-rm images;                          assert_rc 2; assert_line $'^@@error\tbad_args\t'
  engine --engine docker-rm images --list;                   assert_rc 2
  engine --engine docker-rm images --list "$T_HOME/nope";    assert_rc 2
  engine --engine docker-rm images "$T_HOME/list";           assert_rc 2
  printf 'a\n' > "$T_HOME/list"
  engine --engine docker-rm networks --list "$T_HOME/list";  assert_rc 2; assert_line $'^@@error\tbad_args\t'
  engine --engine docker-rm --list "$T_HOME/list";           assert_rc 2
  assert_not_called '^docker '
}
test_docker_rm_requires_running() {
  mk_home; stub_docker_stopped; printf 'x\n' > "$T_HOME/list"
  engine --engine docker-rm containers --list "$T_HOME/list"
  assert_rc 1; assert_line $'^@@error\tdocker_not_ready\t'; assert_not_called '^docker rm'
}
test_docker_rm_empty_list_does_nothing() {
  mk_home; stub_docker_running; : > "$T_HOME/list"
  engine --engine docker-rm volumes --list "$T_HOME/list"
  assert_rc 0; assert_not_called '^docker volume'
}
test_docker_rm_dry_run_removes_nothing() {
  mk_home; stub_docker_running; printf 'abc123def456\n' > "$T_HOME/c"; printf 'old:1\n' > "$T_HOME/i"; printf 'old_cache\n' > "$T_HOME/v"
  engine --dry-run --engine docker-rm containers --list "$T_HOME/c"
  engine --dry-run --engine docker-rm images --list "$T_HOME/i"
  engine --dry-run --engine docker-rm volumes --list "$T_HOME/v"
  assert_line $'^@@log\tsay\t  \\[dry-run\\] docker volume rm old_cache$'
  assert_not_called '^docker (rm|rmi|volume rm)'
}

# ── docker-rm build-cache ──
test_docker_rm_build_cache_one_anchored_prune() {
  mk_home; stub_docker_running; printf 'bcnpm02\nbcbig01\nbcnpm02\n' > "$T_HOME/list"
  engine --engine docker-rm build-cache --list "$T_HOME/list"
  assert_rc 0; assert_protocol
  # one prune, the ids anchored as a whole (buildx matches id= as a regular expression), repeats once
  assert_called '^docker buildx prune -af --filter id=\^\(bcnpm02\|bcbig01\)\$$'
  [ "$(grep -c '^docker buildx prune' "$T_BIN/calls.log")" = 1 ] || fail "expected one prune"
  assert_line $'^@@progress\tRemoving 2 build cache entries…$'
  assert_line $'^@@freed\t[0-9]+$'; assert_no_line $'^@@log\twarn\t'
}
test_docker_rm_build_cache_skips_unknown_and_in_use() {
  mk_home; stub_docker_running; printf 'bcinuse05\nbcnope99\nbcshared04\n' > "$T_HOME/list"
  engine --engine docker-rm build-cache --list "$T_HOME/list"
  assert_rc 0
  assert_line $'^@@log\twarn\tSkipped \\(build cache entry not found\\): bcnope99$'
  assert_line $'^@@log\twarn\t1 build cache entry skipped \\(in use\\)\\.$'
  assert_called '^docker buildx prune -af --filter id=\^\(bcshared04\)\$$'
}
test_docker_rm_build_cache_nothing_left_runs_no_prune() {
  mk_home; stub_docker_running; printf 'bcinuse05\nbcnope99\n' > "$T_HOME/list"
  engine --engine docker-rm build-cache --list "$T_HOME/list"
  assert_rc 0; assert_not_called '^docker buildx prune'; assert_no_line '^@@freed'
}
test_docker_rm_build_cache_entry_left_fails() {
  mk_home; stub_docker_running; printf 'bcparent03\nbcnpm02\n' > "$T_HOME/list"
  engine --engine docker-rm build-cache --list "$T_HOME/list"
  assert_rc 1
  assert_line $'^@@log\twarn\t1 build cache entry not removed \\(still used by another cache entry or a running build\\)\\.$'
  assert_line $'^@@freed\t'   # what was freed is still reported
}
test_docker_rm_build_cache_refuses_regex_and_options() {
  mk_home; stub_docker_running
  for bad in '.*' 'bcnpm02|bcbig01' 'bc.pm02' 'BCNPM02' 'bcnpm02$' 'a b' '-af'; do
    printf 'bcbig01\n%s\n' "$bad" > "$T_HOME/list"
    engine --engine docker-rm build-cache --list "$T_HOME/list"
    assert_rc 2; assert_line "^@@error"$'\t'"not_allowed"$'\t'
  done
  assert_not_called '^docker buildx'
}
test_docker_rm_build_cache_needs_buildx() {
  mk_home; stub_docker_running; export DOCKER_NO_BUILDX=1; printf 'bcbig01\n' > "$T_HOME/list"
  engine --engine docker-rm build-cache --list "$T_HOME/list"
  assert_rc 1; assert_line $'^@@error\tbuildx_missing\t'; assert_not_called '^docker buildx (du|prune)'
}
test_docker_rm_build_cache_du_failure_removes_nothing() {
  mk_home; stub_docker_running; export DOCKER_BUILDX_DU_FAIL=1; printf 'bcbig01\n' > "$T_HOME/list"
  engine --engine docker-rm build-cache --list "$T_HOME/list"
  assert_rc 1; assert_line $'^@@log\terr\tCouldn\'t read the build cache — nothing was removed\\.$'
  assert_not_called '^docker buildx prune'
}
test_docker_rm_build_cache_requires_running() {
  mk_home; stub_docker_stopped; printf 'bcbig01\n' > "$T_HOME/list"
  engine --engine docker-rm build-cache --list "$T_HOME/list"
  assert_rc 1; assert_line $'^@@error\tdocker_not_ready\t'; assert_not_called '^docker buildx'
}
test_docker_rm_build_cache_dry_run_removes_nothing() {
  mk_home; stub_docker_running; printf 'bcbig01\nbcnpm02\n' > "$T_HOME/list"
  engine --dry-run --engine docker-rm build-cache --list "$T_HOME/list"
  assert_rc 0
  assert_line $'^@@log\tsay\t  \\[dry-run\\] docker buildx prune -af --filter id=\\^\\(bcbig01\\|bcnpm02\\)\\$$'
  assert_line $'^@@freed\t0$'; assert_not_called '^docker buildx prune'
}
test_docker_build_cache_messages_in_indonesian() {
  mk_home; stub_docker_running; printf 'bcinuse05\nbcparent03\n' > "$T_HOME/list"
  engine --lang id --engine docker-rm build-cache --list "$T_HOME/list"
  assert_line $'^@@log\twarn\t1 entri build cache dilewati \\(sedang dipakai\\)\\.$'
  assert_line $'^@@progress\tMenghapus 1 entri build cache…$'
  assert_line $'^@@log\twarn\t1 entri build cache tidak terhapus \\(masih dipakai entri cache lain atau build yang sedang berjalan\\)\\.$'
}

# ── docker-prune ──
test_docker_prune_maps_commands() {
  mk_home; stub_docker_running
  engine --engine docker-prune images-unused;   assert_rc 0; assert_called '^docker image prune -af$'; assert_line $'^@@freed\t'
  engine --engine docker-prune images-dangling; assert_called '^docker image prune -f$'
  engine --engine docker-prune build-all;       assert_called '^docker builder prune -af$'
  engine --engine docker-prune build-old;      assert_called '^docker builder prune -af --filter until=168h$'
  engine --engine docker-prune networks;        assert_called '^docker network prune -f$'
  engine --engine docker-prune safe
  assert_called '^docker container prune -f$'
  engine --engine docker-prune all-unused
  assert_called '^docker system prune -af$'; assert_called '^docker volume prune -af$'
  assert_protocol
}
test_docker_prune_wipe_removes_all_listed() {
  mk_home; stub_docker_running
  engine --engine docker-prune wipe; assert_rc 0
  assert_called '^docker rm -f abc123def456 111222333444 999888777666$'
  assert_called '^docker system prune -af$'
  assert_called '^docker volume rm -f pgdata old_cache$'
  assert_called '^docker builder prune -af$'
}
test_docker_prune_wipe_on_empty_docker() {
  mk_home; stub_docker_running_empty
  engine --engine docker-prune wipe; assert_rc 0
  assert_not_called '^docker rm'; assert_not_called '^docker volume rm'; assert_called '^docker system prune -af$'
}
test_docker_prune_orb_reset() {
  mk_home; stub_docker_running
  engine --engine docker-prune orb-reset; assert_rc 0; assert_called '^orb reset$'
}
test_docker_prune_orb_reset_needs_orb() {
  mk_home; stub_docker_running
  engine_eval "$HIDE_CODE"'HIDE=orb; ENGINE_ARGS=(docker-prune orb-reset); engine_dispatch'
  assert_rc 1; assert_line $'^@@error\tdocker_missing\t'; assert_not_called '^orb '
}
test_docker_prune_dry_run_runs_nothing() {
  mk_home; stub_docker_running
  all=""
  for a in images-unused images-dangling build-all build-old networks safe all-unused wipe orb-reset; do
    engine --dry-run --engine docker-prune $a; assert_rc 0; all="$all$OUT"$'\n'
  done
  OUT=$all
  assert_line $'^@@log\tsay\t  \\[dry-run\\] docker system prune -af$'
  assert_line $'^@@log\tsay\t  \\[dry-run\\] orb reset$'
  assert_line $'^@@freed\t0$'
  assert_not_called '^docker (rm |rmi |system prune|volume (rm|prune)|builder prune|image prune|network prune|container prune)'; assert_not_called '^orb '
}
test_docker_prune_bad_arg_runs_nothing() {
  mk_home; stub_docker_running
  engine --engine docker-prune everything;   assert_rc 2; assert_line $'^@@error\tbad_args\t'
  engine --engine docker-prune;              assert_rc 2
  engine --engine docker-prune wipe extra;   assert_rc 2
  engine --engine docker-prune -af;          assert_rc 2
  assert_not_called '^docker '; assert_not_called '^orb '
}
test_docker_prune_requires_running() {
  mk_home; stub_docker_stopped
  engine --engine docker-prune wipe
  assert_rc 1; assert_line $'^@@error\tdocker_not_ready\t'
  assert_not_called '^docker (rm|system|volume|builder)'
}
test_docker_prune_failure_gives_exit_1() {
  mk_home; stub_docker_running
  stub docker 'case "$1" in builder) exit 1 ;; esac; exit 0'
  require_stub docker orb open
  engine --engine docker-prune build-all
  assert_rc 1
}

# The CLI keeps its menu wording; only engine mode names the app's tab.
test_docker_skip_messages_keep_the_cli_wording() {
  mk_home; stub_docker_running
  engine_eval 'ENGINE=0; dkr_images nginx:latest; dkr_volumes pgdata'
  assert_line '1 image\(s\) skipped because a container uses them — remove the container first \(option 1\)\.$'
  assert_line '1 volume\(s\) skipped because a container uses them — remove the container first \(option 1\)\.$'
}
test_docker_skip_messages_in_indonesian_name_the_tab() {
  mk_home; stub_docker_running
  engine_eval 'dkr_images nginx:latest' --lang id
  assert_line $'^@@log\twarn\t1 image dilewati karena masih dipakai container — hapus containernya dulu \\(tab Container\\)\\.$'
}
