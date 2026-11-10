# Canned docker / orb / open for the tests (sourced by tests/engine/docker.sh and tests/cli_regression.sh).
# Nothing here ever reaches a real Docker, OrbStack or Docker Desktop.
#
#   docker_stub_body full|empty   → body of a fake `docker` script (print it into a file; see tests/lib.sh `stub`)
#   orb_stub_body / open_stub_body → bodies of fake `orb` / `open`
#
# State is kept in files under $HOME, which the tests point at a scratch directory:
#   .fake-docker-down      exists → the daemon is stopped; its content is N, the number of `docker info` calls
#                          that still fail after `orb start` / `open -a Docker` (so N=0 is ready at once)
#   .fake-docker-started   created by the fake `orb start` / `open`
#   .fake-docker-n         count of `docker info` calls since start
# The fixture: 3 containers (web running, db and old exited), 4 images (nginx and postgres in use, old:1 unused,
# one dangling), 2 volumes (pgdata used by db, old_cache unused).

docker_stub_body() {
  printf 'MODE=%s\n' "$1"
  cat <<'STUB'
[ -n "${DOCKER_ARGC_LOG:-}" ] && printf '%s:%s\n' "$#" "$*" >> "$DOCKER_ARGC_LOG"
E=0; [ "$MODE" = empty ] && E=1
a=$(printf '%064d' 0 | tr 0 a); b=$(printf '%064d' 0 | tr 0 b); c=$(printf '%064d' 0 | tr 0 c); d=$(printf '%064d' 0 | tr 0 d)
T=$(printf '\t')
case "$1" in
  info)
    if [ -e "$HOME/.fake-docker-down" ]; then
      [ -e "$HOME/.fake-docker-started" ] || exit 1
      n=$(cat "$HOME/.fake-docker-n" 2>/dev/null); n=$(( ${n:-0} + 1 )); echo "$n" > "$HOME/.fake-docker-n"
      [ "$n" -gt "$(cat "$HOME/.fake-docker-down")" ] || exit 1
    fi
    exit 0 ;;
  inspect)
    [ "$E" = 1 ] || printf 'sha256:%s\nsha256:%s\n' "$a" "$b" ;;
  ps)
    case "$*" in
      "ps -a -s "*)
        [ "$E" = 1 ] || {
          printf 'abc123def456\trunning\t2B (virtual 187MB)\tweb\tnginx:latest\n'
          printf '111222333444\texited\t0B (virtual 430MB)\tdb\tpostgres:16\n'
          printf '999888777666\texited\t1kB (virtual 5MB)\tmy old\tbusybox:1\n'; } ;;
      "ps -a --format "*)
        [ "$E" = 1 ] || {
          printf 'abc123def456\tweb\n'
          printf '111222333444\tdb\n'
          printf '999888777666\tmy old\n'; } ;;
      "ps -a --no-trunc --format "*)   # full ids; DOCKER_NAME_CLASH adds a container named like web's short id
        [ "$E" = 1 ] || {
          z=$(printf '%052d' 0)
          printf 'abc123def456%s\tweb\n' "$z"
          printf '111222333444%s\tdb\n' "$z"
          printf '999888777666%s\tmy old\n' "$z"
          [ -z "${DOCKER_NAME_CLASH:-}" ] || printf '555666777888%s\tabc123def456\n' "$z"; } ;;
      "ps -aq")
        [ -z "${DOCKER_PS_FAIL:-}" ] || exit 1   # docker can't list the containers
        [ "$E" = 1 ] || printf 'abc123def456\n111222333444\n999888777666\n' ;;
      "ps -q")  [ "$E" = 1 ] || printf 'abc123def456\n' ;;
      "ps -a --filter volume=pgdata "*) echo db ;;
      "ps -a --filter status="*) [ "$E" = 1 ] || printf 'old  (busybox:1, Exited (0) 2 days ago)\n' ;;
    esac ;;
  images)
    case "$*" in
      "images --no-trunc "*)
        [ "$E" = 1 ] || {
          printf 'sha256:%s\tnginx:latest\t187MB\t2 weeks ago\n' "$a"
          printf 'sha256:%s\tpostgres:16\t430MB\t3 weeks ago\n' "$b"
          printf 'sha256:%s\told:1\t5MB\t1 year ago\n' "$c"
          printf 'sha256:%s\t<none>:<none>\t12MB\t2 months ago\n' "$d"; } ;;
      "images -q")
        [ "$E" = 1 ] || printf '%s\n%s\n%s\n%s\n%s\n' "${a:0:12}" "${b:0:12}" "${c:0:12}" "${d:0:12}" "${a:0:12}" ;;
    esac ;;
  volume)
    case "$*" in
      "volume ls -q") [ "$E" = 1 ] || printf 'pgdata\nold_cache\n' ;;
      "volume ls -q -f dangling=true") [ "$E" = 1 ] || printf 'old_cache\n' ;;
    esac ;;
  system)
    case "$*" in
      "system df --format "*)
        if [ "$E" = 1 ]; then
          printf 'Images\t0\t0\t0B\t0B\nContainers\t0\t0\t0B\t0B\nLocal Volumes\t0\t0\t0B\t0B\nBuild Cache\t0\t0\t0B\t0B\n'
        else
          printf 'Images\t4\t2\t634MB\t17MB (2%%)\nContainers\t3\t1\t2B\t0B\nLocal Volumes\t2\t1\t170MB\t50MB (29%%)\nBuild Cache\t7\t0\t1.2GB\t1.2GB\n'
        fi ;;
      "system df -v")
        [ "$E" = 1 ] || printf 'Images space usage:\n\nREPOSITORY   TAG   IMAGE ID   SIZE\nnginx   latest   aaaaaaaaaaaa   187MB\n\nLocal Volumes space usage:\n\nVOLUME NAME   LINKS     SIZE\npgdata        1         120MB\nold_cache     0         50MB\n\nBuild cache usage: 1.2GB\n' ;;
      "system df")
        printf 'TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE\nImages          4         2         634MB     17MB (2%%)\nBuild Cache     7         0         1.2GB     1.2GB\n' ;;
    esac ;;
esac
exit 0
STUB
}

orb_stub_body() {
  cat <<'STUB'
case "$1" in start) touch "$HOME/.fake-docker-started" ;; esac
exit 0
STUB
}

open_stub_body() {
  cat <<'STUB'
case "$*" in "-a Docker") touch "$HOME/.fake-docker-started" ;; esac
exit 0
STUB
}
