#!/bin/bash
#
# Mac Cleaner — free up disk space on macOS (made with developers in mind).
#   • Clean caches: npm, Yarn, pnpm, Bun, Composer, pip, Go, Homebrew, Gradle,
#     Maven, Flutter, Xcode, ~/Library/Caches, logs, Trash
#   • Docker / OrbStack: prune build cache, images, volumes, or full reset
#   • Find rarely used & large apps, and the largest folders / app data
#   • Uninstall apps together with their leftover files (moved to the Trash)
#
# Interface: English or Bahasa Indonesia (follows your macOS language,
# switchable from the menu or with --lang en|id).
#
# Usage:
#   bash mac-cleaner.command              # interactive menu
#   bash mac-cleaner.command --dry-run    # show what would be deleted, delete nothing
#   bash mac-cleaner.command --lang id    # force Bahasa Indonesia (or: en)
#
# No sudo needed. Everything is shown first and needs confirmation.
# Never touched: Desktop, Documents, Downloads, your code, Docker volumes
# (unless you pick them and type DELETE). Uninstalled apps and their leftovers go to the
# Trash, so they can be put back.
#
# https://github.com/ahmadrio/mac-cleaner — MIT License

VERSION="1.2"
DRY_RUN=0
UNUSED_DAYS=90
SHOW_HELP=0
UI_LANG=""
IFS=$' \t\n'
H="${HOME:?HOME is not set}"
H="${H%/}"
CONF_DIR="$H/.config/mac-cleaner"
LANG_FILE="$CONF_DIR/lang"

usage() {
  cat <<EOF
Mac Cleaner v$VERSION
Usage:  bash mac-cleaner.command [--dry-run] [--lang en|id]
  -n, --dry-run     Show what would be deleted without deleting anything
                    (Tampilkan yang akan dihapus tanpa menghapus apa pun)
      --lang en|id  Interface language / Bahasa tampilan (default: macOS language)
  -h, --help        This help / Bantuan ini
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    --lang)       shift; UI_LANG="${1:-}" ;;
    --lang=*)     UI_LANG="${1#--lang=}" ;;
    -h|--help)    SHOW_HELP=1 ;;
    *) echo "Unknown option / Opsi tidak dikenal: $1"; usage; exit 1 ;;
  esac
  shift
done
if [ "$SHOW_HELP" = 1 ]; then usage; exit 0; fi

# ───────────────────────── language ─────────────────────────
detect_lang() {
  local l=""
  if command -v defaults >/dev/null 2>&1; then
    l=$(defaults read -g AppleLanguages 2>/dev/null | awk 'NR==2{ gsub(/[ \t",]/, ""); print; exit }')
  fi
  [ -n "$l" ] || l="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
  printf '%s' "$l"
}
[ -n "$UI_LANG" ] || UI_LANG="${MAC_CLEANER_LANG:-}"
[ -n "$UI_LANG" ] || UI_LANG="$(cat "$LANG_FILE" 2>/dev/null)"
[ -n "$UI_LANG" ] || UI_LANG="$(detect_lang)"
case "$UI_LANG" in id*|ID*|in|in_*|in-*|indo*|Indo*) UI_LANG=id ;; *) UI_LANG=en ;; esac

L() { if [ "$UI_LANG" = id ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }   # L "Indonesia" "English"

save_lang() { mkdir -p "$CONF_DIR" 2>/dev/null && printf '%s\n' "$UI_LANG" > "$LANG_FILE" 2>/dev/null; }

# Add common tool locations that may be missing from PATH
for p in /opt/homebrew/bin /usr/local/bin "$H/.homebrew/bin" "$H/.orbstack/bin" \
         "$H/.bun/bin" "$H/go/bin" /usr/local/go/bin "$H/.local/bin"; do
  [ -d "$p" ] || continue
  case ":$PATH:" in *":$p:"*) ;; *) PATH="$PATH:$p" ;; esac
done
export PATH

# ───────────────────────── output helpers ─────────────────────────
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YEL=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; CYN=""; RST=""
fi
IS_TTY=0; [ -t 2 ] && IS_TTY=1

say()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "${CYN}›${RST} $*"; }
ok()   { printf '%s\n' "${GRN}✓${RST} $*"; }
warn() { printf '%s\n' "${YEL}!${RST} $*"; }
err()  { printf '%s\n' "${RED}✗${RST} $*"; }
progress()      { if [ "$IS_TTY" = 1 ]; then printf '\r\033[K  %s' "$*" >&2; fi; }
progress_done() { if [ "$IS_TTY" = 1 ]; then printf '\r\033[K' >&2; fi; }

ask() {
  printf '%s' "$1"
  ANSWER=""
  IFS= read -r ANSWER || { echo; return 1; }
}
confirm() {
  ask "$1 [y/N] " || return 1
  case "$ANSWER" in y|Y|ya|Ya|YA|yes|Yes|YES) return 0 ;; *) return 1 ;; esac
}
confirm_word() {
  ask "  $(L "Ketik ${BOLD}$1${RST} untuk lanjut (lainnya = batal): " "Type ${BOLD}$1${RST} to continue (anything else cancels): ")" || return 1
  [ "$ANSWER" = "$1" ]
}
pause() { ask "${DIM}  $(L "Enter untuk kembali ke menu…" "Press Enter to return to the menu…")${RST}" || true; }
cancelled() { info "$(L "Batal." "Cancelled.")"; }

has() { command -v "$1" >/dev/null 2>&1; }

hsize() {
  awk -v k="${1:-0}" 'BEGIN{
    if (k < 0) { printf "?"; exit }
    if (k >= 1048576) printf "%.1f GB", k/1048576;
    else if (k >= 1024) printf "%.0f MB", k/1024;
    else printf "%d KB", k }'
}

tilde() { case "$1" in "$H"/*) printf '~/%s' "${1#"$H"/}" ;; *) printf '%s' "$1" ;; esac; }

# ───────────────────────── temp files ─────────────────────────
TMPFILES=""
mktmp() { MKTMP=$(mktemp "${TMPDIR:-/tmp}/maccleaner.XXXXXX") || exit 1; TMPFILES="$TMPFILES $MKTMP"; }
cleanup() { local f; for f in $TMPFILES; do rm -f "$f"; done; }
trap cleanup EXIT
trap 'echo; exit 130' INT

# ───────────────────────── disk ─────────────────────────
disk_info() { df -Pk "$H" 2>/dev/null | awk 'NR==2{ print $2, $4 }'; }
free_kb()   { df -Pk "$H" 2>/dev/null | awk 'NR==2{ print $4 }'; }

size_kb() {  # size_kb path... → total KB of the paths that exist
  local total=0 p s
  for p in "$@"; do
    [ -n "$p" ] && [ -e "$p" ] || continue
    s=$(du -sk "$p" 2>/dev/null | awk '{s=$1} END{print s}')
    total=$((total + ${s:-0}))
  done
  echo "$total"
}
size_kb_stdin() { tr '\n' '\000' | xargs -0 -r du -sk 2>/dev/null | awk '{s+=$1} END{print s+0}'; }

report_freed() {
  local before="$1" after diff
  if [ "$DRY_RUN" = 1 ]; then info "$(L "Dry-run: tidak ada yang dihapus." "Dry run: nothing was deleted.")"; return; fi
  sleep 1
  after=$(free_kb); diff=$(( ${after:-0} - ${before:-0} ))
  if [ "$diff" -gt 0 ]; then
    ok "$(L "Ruang kosong bertambah ${BOLD}$(hsize "$diff")${RST} (sekarang $(hsize "$after") kosong)." \
            "Freed ${BOLD}$(hsize "$diff")${RST} (now $(hsize "$after") free).")"
  else
    ok "$(L "Selesai. Ruang kosong sekarang $(hsize "$after")." "Done. Free space is now $(hsize "$after").")"
    say "  ${DIM}$(L "macOS kadang butuh beberapa menit untuk memperbarui angka ini (snapshot APFS)." \
                     "macOS can take a few minutes to update this number (APFS snapshots).")${RST}"
  fi
}

# ───────────────────────── guarded deletion ─────────────────────────
safe_path() {  # only paths inside HOME, and never these important folders themselves
  local p="${1%/}"
  case "$p" in "$H"/?*) ;; *) return 1 ;; esac
  case "$p" in *"/.."|*"/../"*) return 1 ;; esac
  case "$p" in
    "$H/Library"|"$H/Library/Application Support"|"$H/Library/Containers"|\
    "$H/Library/Group Containers"|"$H/Library/Developer"|"$H/Library/Preferences"|\
    "$H/Library/Keychains"|"$H/Documents"|"$H/Desktop"|"$H/Downloads"|\
    "$H/Pictures"|"$H/Movies"|"$H/Music"|"$H/Applications"|"$H/.ssh"|\
    "$H/.config"|"$H/.local"|"$H/go"|"$H/OrbStack"|"$H/.orbstack") return 1 ;;
  esac
  return 0
}

rm_contents() {  # delete the CONTENTS of a folder (the folder itself stays)
  local d="${1%/}"
  [ -d "$d" ] || return 0
  if ! safe_path "$d"; then warn "$(L "Dilewati (lokasi tidak diizinkan):" "Skipped (location not allowed):") $d"; return 1; fi
  if [ "$DRY_RUN" = 1 ]; then say "  ${DIM}[dry-run]${RST} $(L "hapus isi:" "delete contents of:") $(tilde "$d")"; return 0; fi
  find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
  return 0
}

rm_file() {
  [ -e "$1" ] || return 0
  safe_path "$1" || return 1
  if [ "$DRY_RUN" = 1 ]; then say "  ${DIM}[dry-run]${RST} $(L "hapus:" "delete:") $(tilde "$1")"; return 0; fi
  rm -f "$1" 2>/dev/null
}

run() {
  if [ "$DRY_RUN" = 1 ]; then say "  ${DIM}[dry-run]${RST} $*"; return 0; fi
  "$@"
}

parse_selection() {  # parse_selection "1 3,5" max → SEL=(0-based indexes)
  local input max tok seen=" "
  input=$(printf '%s' "$1" | tr ',' ' '); max=$2; SEL=()
  set -f
  for tok in $input; do
    case "$tok" in *[!0-9]*) warn "$(L "Diabaikan:" "Ignored:") '$tok'"; continue ;; esac
    tok=$((10#$tok))
    if [ "$tok" -lt 1 ] || [ "$tok" -gt "$max" ]; then warn "$(L "Nomor di luar daftar:" "Not in the list:") $tok"; continue; fi
    case "$seen" in *" $tok "*) continue ;; esac
    seen="$seen$tok "; SEL+=($((tok - 1)))
  done
  set +f
}

# ═════════════════════════ 1. CACHES ═════════════════════════
CACHE_IDS="npm yarn pnpm bun composer pip gobuild brew cocoapods xcode_dd xcode_ds simulator libcaches logs gradle maven gomod pub nuget dotcache trash"

init_paths() {
  local v
  BREW_CACHE=""; GO_CACHE="$H/Library/Caches/go-build"; GO_MODCACHE="$H/go/pkg/mod"
  PNPM_STORE="$H/Library/pnpm/store"
  if has brew; then BREW_CACHE="$(brew --cache 2>/dev/null)"; fi
  [ -n "$BREW_CACHE" ] || BREW_CACHE="$H/Library/Caches/Homebrew"
  if has go; then
    v="$(go env GOCACHE 2>/dev/null)";    [ -n "$v" ] && GO_CACHE="$v"
    v="$(go env GOMODCACHE 2>/dev/null)"; [ -n "$v" ] && GO_MODCACHE="$v"
  fi
  if has pnpm; then
    v="$(cd "$H" && pnpm store path 2>/dev/null | tail -1)"; [ -d "$v" ] && PNPM_STORE="$v"
  fi
}

# kind: safe = rebuilt automatically, heavy = re-downloaded on next build, permanent = no undo
cache_def() {
  C_PATHS=(); C_KIND="safe"; C_LABEL=""
  case "$1" in
    npm)       C_LABEL="npm / npx cache";        C_PATHS=("$H/.npm/_cacache" "$H/.npm/_npx" "$H/.npm/_logs") ;;
    yarn)      C_LABEL="Yarn cache";             C_PATHS=("$H/Library/Caches/Yarn" "$H/.yarn/berry/cache") ;;
    pnpm)      C_LABEL="pnpm store ($(L "paket tak terpakai" "unused packages"))"; C_PATHS=("$PNPM_STORE") ;;
    bun)       C_LABEL="Bun cache";              C_PATHS=("$H/.bun/install/cache") ;;
    composer)  C_LABEL="Composer cache";         C_PATHS=("$H/Library/Caches/composer" "$H/.composer/cache") ;;
    pip)       C_LABEL="pip cache";              C_PATHS=("$H/Library/Caches/pip") ;;
    gobuild)   C_LABEL="Go build cache";         C_PATHS=("$GO_CACHE") ;;
    brew)      C_LABEL="Homebrew ($(L "download & versi lama" "downloads & old versions"))"; C_PATHS=("$BREW_CACHE") ;;
    cocoapods) C_LABEL="CocoaPods cache";        C_PATHS=("$H/Library/Caches/CocoaPods") ;;
    xcode_dd)  C_LABEL="Xcode DerivedData";      C_PATHS=("$H/Library/Developer/Xcode/DerivedData") ;;
    xcode_ds)  C_LABEL="Xcode Device Support";   C_PATHS=("$H/Library/Developer/Xcode/iOS DeviceSupport" "$H/Library/Developer/Xcode/watchOS DeviceSupport") ;;
    simulator) C_LABEL="$(L "Simulator iOS (cache & device usang)" "iOS Simulator (caches & old devices)")"
               C_PATHS=("$H/Library/Developer/CoreSimulator/Caches") ;;
    libcaches) C_LABEL="$(L "Cache aplikasi" "App caches") (~/Library/Caches)" ;;
    logs)      C_LABEL="$(L "Log aplikasi" "App logs") (~/Library/Logs)"; C_PATHS=("$H/Library/Logs") ;;
    gradle)    C_KIND="heavy"; C_LABEL="Gradle caches & wrapper";   C_PATHS=("$H/.gradle/caches" "$H/.gradle/wrapper/dists") ;;
    maven)     C_KIND="heavy"; C_LABEL="Maven repository (~/.m2)";  C_PATHS=("$H/.m2/repository") ;;
    gomod)     C_KIND="heavy"; C_LABEL="Go module cache";           C_PATHS=("$GO_MODCACHE") ;;
    pub)       C_KIND="heavy"; C_LABEL="Dart/Flutter pub cache";    C_PATHS=("$H/.pub-cache/hosted" "$H/.pub-cache/git") ;;
    nuget)     C_KIND="heavy"; C_LABEL="NuGet packages";            C_PATHS=("$H/.nuget/packages") ;;
    dotcache)  C_KIND="heavy"; C_LABEL="~/.cache (Playwright, Puppeteer, $(L "dll" "etc."))"; C_PATHS=("$H/.cache") ;;
    trash)     C_KIND="permanent"; C_LABEL="Trash";                 C_PATHS=("$H/.Trash") ;;
  esac
}

libcache_children() {  # entries of ~/Library/Caches, minus system ones and those listed separately
  local d="$H/Library/Caches" p n
  [ -d "$d" ] || return 0
  find "$d" -mindepth 1 -maxdepth 1 2>/dev/null | while IFS= read -r p; do
    n="${p##*/}"
    case "$n" in
      com.apple.*|CloudKit|GeoServices|FamilyCircle|Yarn|composer|pip|go-build|Homebrew|CocoaPods) continue ;;
    esac
    [ "$p" = "$BREW_CACHE" ] && continue
    [ "$p" = "$GO_CACHE" ] && continue
    printf '%s\n' "$p"
  done
}

cache_size() {
  case "$1" in
    libcaches) libcache_children | size_kb_stdin ;;
    trash) if ls "$H/.Trash" >/dev/null 2>&1; then size_kb "$H/.Trash"; else echo -1; fi ;;
    *) size_kb "${C_PATHS[@]}" ;;
  esac
}

cache_clean() {  # call cache_def first
  local p
  case "$1" in
    pnpm)
      if has pnpm; then (cd "$H" && run pnpm store prune); else warn "$(L "pnpm tidak ditemukan, dilewati." "pnpm not found, skipped.")"; fi ;;
    brew)
      if has brew; then run brew cleanup --prune=all -s; else rm_contents "$BREW_CACHE"; fi ;;
    gomod)
      if has go; then run go clean -modcache
      elif safe_path "$GO_MODCACHE"; then
        [ "$DRY_RUN" = 1 ] || chmod -R u+w "$GO_MODCACHE" 2>/dev/null
        rm_contents "$GO_MODCACHE"
      fi ;;
    simulator)
      has xcrun && run xcrun simctl delete unavailable
      rm_contents "$H/Library/Developer/CoreSimulator/Caches" ;;
    libcaches)
      libcache_children | while IFS= read -r p; do
        if [ -d "$p" ] && [ ! -L "$p" ]; then rm_contents "$p"; else rm_file "$p"; fi
      done ;;
    trash)
      if has osascript; then run osascript -e 'tell application "Finder" to empty trash'
      else rm_contents "$H/.Trash"; fi ;;
    *)
      for p in "${C_PATHS[@]}"; do rm_contents "$p"; done ;;
  esac
}

kind_tag() {
  case "$1" in
    safe)  printf '%s' "${GRN}$(L "aman" "safe")${RST}" ;;
    heavy) printf '%s' "${YEL}$(L "berat" "heavy")${RST}" ;;
    *)     printf '%s' "${RED}$(L "permanen" "permanent")${RST}" ;;
  esac
}

cache_menu() {
  local id kb i n t_safe=0 t_heavy=0 sum=0 before
  init_paths
  info "$(L "Menghitung ukuran cache… (bisa 10–60 detik)" "Measuring caches… (may take 10–60 seconds)")"
  L_ID=(); L_KB=(); L_LABEL=(); L_KIND=()
  for id in $CACHE_IDS; do
    cache_def "$id"
    if [ "$id" = simulator ]; then
      has xcrun && [ -d "$H/Library/Developer/CoreSimulator/Devices" ] || continue
    fi
    progress "$C_LABEL"
    kb=$(cache_size "$id"); kb=${kb:-0}
    case "$id" in
      trash)     [ "$kb" -ne 0 ] || continue ;;
      simulator) ;;
      *)         [ "$kb" -ge 1024 ] || continue ;;   # hide anything under 1 MB
    esac
    L_ID+=("$id"); L_KB+=("$kb"); L_LABEL+=("$C_LABEL"); L_KIND+=("$C_KIND")
    if [ "$kb" -gt 0 ]; then
      case "$C_KIND" in safe) t_safe=$((t_safe + kb)) ;; heavy) t_heavy=$((t_heavy + kb)) ;; esac
    fi
  done
  progress_done

  n=${#L_ID[@]}
  if [ "$n" -eq 0 ]; then ok "$(L "Tidak ada cache berarti yang perlu dibersihkan." "No significant caches to clean.")"; return; fi

  echo
  printf '  %s%3s  %9s  %-40s %s%s\n' "$BOLD" "No" "$(L "Ukuran" "Size")" "Item" "$(L "Jenis" "Type")" "$RST"
  i=0
  while [ "$i" -lt "$n" ]; do
    printf '  %3d  %9s  %-40s %s\n' $((i + 1)) "$(hsize "${L_KB[$i]}")" "${L_LABEL[$i]}" "$(kind_tag "${L_KIND[$i]}")"
    i=$((i + 1))
  done
  echo
  say "  $(L "Total aman" "Total safe"): ${BOLD}$(hsize "$t_safe")${RST}   ·   $(L "berat" "heavy"): ${BOLD}$(hsize "$t_heavy")${RST}"
  say "  ${DIM}$(L "aman = dibuat ulang otomatis · berat = di-download ulang saat build berikutnya" \
                   "safe = rebuilt automatically · heavy = re-downloaded on the next build")${RST}"
  say "  ${DIM}$(L "permanen = tidak bisa dikembalikan" "permanent = cannot be undone")${RST}"
  warn "$(L "Tutup IDE, browser & aplikasi lain dulu supaya cache-nya terhapus bersih." \
            "Quit your IDE, browser and other apps first so their caches clear completely.")"
  echo
  ask "  $(L "Pilih nomor (mis. 1 3 5), a = semua 'aman', s = 'aman' + 'berat', Enter = batal: " \
             "Pick numbers (e.g. 1 3 5), a = all 'safe', s = 'safe' + 'heavy', Enter = cancel: ")" || return
  case "$ANSWER" in
    "") cancelled; return ;;
    a|A) SEL=(); i=0; while [ "$i" -lt "$n" ]; do [ "${L_KIND[$i]}" = safe ] && SEL+=("$i"); i=$((i + 1)); done ;;
    s|S) SEL=(); i=0; while [ "$i" -lt "$n" ]; do [ "${L_KIND[$i]}" != permanent ] && SEL+=("$i"); i=$((i + 1)); done ;;
    *)   parse_selection "$ANSWER" "$n" ;;
  esac
  if [ "${#SEL[@]}" -eq 0 ]; then info "$(L "Tidak ada yang dipilih." "Nothing selected.")"; return; fi

  echo; say "  $(L "Akan dibersihkan:" "Will clean:")"
  for i in "${SEL[@]}"; do
    say "    • ${L_LABEL[$i]}  ($(hsize "${L_KB[$i]}"))"
    [ "${L_KB[$i]}" -gt 0 ] && sum=$((sum + L_KB[i]))
  done
  confirm "  $(L "Lanjut? (perkiraan ±$(hsize "$sum"))" "Continue? (about $(hsize "$sum"))")" || { cancelled; return; }

  before=$(free_kb)
  for i in "${SEL[@]}"; do
    id="${L_ID[$i]}"; cache_def "$id"
    info "$(L "Membersihkan" "Cleaning") ${L_LABEL[$i]}…"
    cache_clean "$id"
  done
  report_freed "$before"
}

# ═════════════════════════ 2. DOCKER ═════════════════════════
docker_safe() {
  local stopped before
  stopped=$(docker ps -a --filter status=exited --filter status=created --filter status=dead \
            --format '{{.Names}}  ({{.Image}}, {{.Status}})' 2>/dev/null)
  if [ -n "$stopped" ]; then
    say "  $(L "Container berhenti yang akan dihapus:" "Stopped containers that will be removed:")"
    printf '%s\n' "$stopped" | sed 's/^/    • /'
    warn "$(L "File yang ditulis di dalam container (bukan di volume) ikut hilang. Volume TIDAK disentuh." \
              "Files written inside these containers (not in volumes) will be lost. Volumes are NOT touched.")"
  fi
  confirm "  $(L "Lanjut bersihkan?" "Go ahead?")" || { cancelled; return; }
  before=$(free_kb)
  run docker container prune -f
  run docker network prune -f
  run docker image prune -f
  run docker builder prune -af
  report_freed "$before"
}

docker_images() {
  local before
  warn "$(L "Semua image yang tidak dipakai container mana pun akan dihapus (nanti di-pull/build ulang)." \
            "All images not used by any container will be removed (pulled/built again when needed).")"
  confirm "  $(L "Lanjut?" "Continue?")" || { cancelled; return; }
  before=$(free_kb)
  run docker image prune -af
  report_freed "$before"
}

docker_volumes() {
  local vols before v
  vols=$(docker volume ls -qf dangling=true 2>/dev/null)
  if [ -z "$vols" ]; then ok "$(L "Tidak ada volume yang tidak terpakai." "No unused volumes.")"; return; fi
  say "  $(L "Volume yang tidak dipakai container mana pun:" "Volumes not used by any container:")"
  printf '%s\n' "$vols" | sed 's/^/    • /'
  warn "$(L "Termasuk data database proyek yang container-nya sudah 'docker compose down'." \
            "This includes database data of projects stopped with 'docker compose down'.") ${RED}$(L "Tidak bisa dikembalikan." "This cannot be undone.")${RST}"
  confirm_word "$(L "HAPUS" "DELETE")" || { cancelled; return; }
  before=$(free_kb)
  printf '%s\n' "$vols" | while IFS= read -r v; do
    [ -n "$v" ] && run docker volume rm "$v"
  done
  report_freed "$before"
}

orb_reset() {
  local before
  warn "$(L "Ini menghapus SEMUA data OrbStack: container, image, volume, Kubernetes & Linux machine." \
            "This deletes ALL OrbStack data: containers, images, volumes, Kubernetes and Linux machines.")"
  warn "$(L "Pastikan database/volume penting sudah di-backup." "Make sure important databases/volumes are backed up.")"
  confirm_word RESET || { cancelled; return 1; }
  before=$(free_kb)
  run orb reset
  report_freed "$before"
  return 0
}

docker_menu() {
  local engine="Docker"
  has orb && engine="OrbStack"
  if ! has docker; then err "$(L "Perintah docker tidak ditemukan." "docker command not found.")"; pause; return; fi
  if ! docker info >/dev/null 2>&1; then
    warn "$engine $(L "belum berjalan." "is not running.")"
    if has orb; then
      confirm "  $(L "Jalankan OrbStack sekarang?" "Start OrbStack now?")" || return
      orb start
    elif [ -d /Applications/Docker.app ]; then
      confirm "  $(L "Buka Docker Desktop?" "Open Docker Desktop?")" && open -a Docker && \
        info "$(L "Tunggu sampai Docker siap, lalu buka menu ini lagi." "Wait until Docker is ready, then open this menu again.")"
      pause; return
    fi
    if ! docker info >/dev/null 2>&1; then err "$(L "Docker belum siap." "Docker is not ready.")"; pause; return; fi
  fi

  while true; do
    echo; say "${BOLD}  Docker ($engine)${RST}"
    docker system df 2>/dev/null | sed 's/^/  /'
    echo
    say "  1) $(L "Bersihkan aman — container berhenti, network & image dangling, build cache" \
                  "Safe cleanup — stopped containers, dangling networks & images, build cache")"
    say "  2) $(L "Hapus SEMUA image yang tidak dipakai container (nanti di-pull ulang)" \
                  "Remove ALL images not used by a container (pulled again later)")"
    say "  3) $(L "Hapus volume yang tidak dipakai container" "Remove volumes not used by a container") ${RED}$(L "(data database ikut hilang)" "(database data is lost)")${RST}"
    if has orb; then
      say "  4) $(L "Reset total OrbStack" "Full OrbStack reset") ${RED}$(L "(hapus SEMUA container, image, volume & Linux machine)" "(deletes ALL containers, images, volumes & Linux machines)")${RST}"
    else
      say "  ${DIM}$(L "Reset total Docker Desktop: buka Docker Desktop › Troubleshoot › Clean / Purge data" \
                       "Full Docker Desktop reset: Docker Desktop › Troubleshoot › Clean / Purge data")${RST}"
    fi
    say "  b) $(L "Kembali" "Back")"
    ask "  $(L "Pilih: " "Choose: ")" || return
    case "$ANSWER" in
      1) docker_safe ;;
      2) docker_images ;;
      3) docker_volumes ;;
      4) if has orb && orb_reset; then pause; return; fi ;;
      b|B|"") return ;;
    esac
  done
}

# ═════════════════════════ 3. APPS ═════════════════════════
to_epoch() {  # mdls date → epoch (macOS date, GNU date fallback)
  date -j -f '%Y-%m-%d %H:%M:%S %z' "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null
}

last_used_epoch() {
  local raw
  has mdls || return 0
  raw=$(mdls -raw -name kMDItemLastUsedDate "$1" 2>/dev/null)
  case "$raw" in ""|"(null)") return 0 ;; esac
  to_epoch "$raw"
}

list_apps() {  # every removable .app in /Applications and ~/Applications (one level of subfolders)
  find /Applications "$H/Applications" -maxdepth 2 -type d -name '*.app' -prune -print 2>/dev/null \
    | grep -v '/Safari\.app$' | sort -u
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

app_bundle_id() {
  local id=""
  if has mdls; then id=$(mdls -raw -name kMDItemCFBundleIdentifier "$1" 2>/dev/null); fi
  case "$id" in "(null)") id="" ;; esac
  if [ -z "$id" ] && [ -f "$1/Contents/Info.plist" ]; then
    if [ -x /usr/libexec/PlistBuddy ]; then
      id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null)
    elif has defaults; then
      id=$(defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null)
    fi
  fi
  printf '%s' "$id"
}

APP_IDS=""
load_app_ids() {  # load_app_ids listfile → APP_IDS = temp file "lowercase-bundle-id<TAB>app path"
  local app i=0 total
  mktmp; APP_IDS=$MKTMP
  total=$(wc -l < "$1" | tr -d ' ')
  while IFS= read -r app <&3; do
    i=$((i + 1)); progress "$(L "Membaca info aplikasi" "Reading app info") [$i/$total]"
    printf '%s\t%s\n' "$(lower "$(app_bundle_id "$app")")" "$app" >> "$APP_IDS"
  done 3< "$1"
  progress_done
}

# Where apps leave files behind. Only the user-level ones are ever removed.
USER_LEFTOVER_DIRS=("$H/Library/Application Support" "$H/Library/Caches" "$H/Library/Logs"
  "$H/Library/Preferences" "$H/Library/Preferences/ByHost" "$H/Library/Saved Application State"
  "$H/Library/Containers" "$H/Library/Group Containers" "$H/Library/HTTPStorages" "$H/Library/WebKit"
  "$H/Library/Cookies" "$H/Library/LaunchAgents" "$H/Library/Application Scripts")
ADMIN_LEFTOVER_DIRS=("/Library/Application Support" "/Library/Caches" "/Library/Preferences" "/Library/Logs"
  "/Library/LaunchAgents" "/Library/LaunchDaemons" "/Library/PrivilegedHelperTools")

find_leftovers() {  # find_leftovers bundle-id app-name app-path dir... → matching paths
  local bid name app others d
  bid=$(lower "$1"); name=$(lower "$2"); app="$3"; shift 3
  mktmp; others=$MKTMP
  if [ -n "$APP_IDS" ]; then awk -F'\t' -v p="$app" '$2 != p && $1 != "" { print $1 }' "$APP_IDS" > "$others"; fi
  for d in "$@"; do
    if [ -d "$d" ]; then find "$d" -mindepth 1 -maxdepth 1 2>/dev/null; fi
  done | awk -v lb="$bid" -v ln="$name" -v of="$others" '
    BEGIN { while ((getline o < of) > 0) if (o != "" && o != lb) others[o] = 1 }
    {
      n = $0; sub(/.*\//, "", n); b = tolower(n)
      sub(/\.(plist|savedstate|binarycookies)$/, "", b)
      m = 0
      if (lb != "") {
        # exact bundle id, its helpers (id.*), team/group containers (*.id, group.id)
        if (b == lb || index(b, lb ".") == 1 || b == "group." lb || index(b, "group." lb ".") == 1) m = 1
        else if (length(b) > length(lb) + 1 && substr(b, length(b) - length(lb)) == "." lb) m = 1
      }
      if (ln != "" && b == ln) m = 1            # folder named exactly like the app
      if (!m) next
      if (b != lb) for (o in others)            # never touch files of another installed app
        if (b == o || index(b, o ".") == 1 || index(b, "group." o) == 1) next
      print
    }'
}

app_running() {
  local pat
  pat=$(printf '%s' "$1/Contents/MacOS/" | sed 's/[][\.*^$+?(){}|]/\\&/g')
  pgrep -f "$pat" >/dev/null 2>&1
}

quit_app() {  # quit_app app-path bundle-id
  local i=0
  if [ -n "$2" ]; then
    osascript -e 'on run argv' -e 'tell application id (item 1 of argv) to quit' -e 'end run' "$2" >/dev/null 2>&1
  else
    osascript -e 'on run argv' -e 'tell application (item 1 of argv) to quit' -e 'end run' "$1" >/dev/null 2>&1
  fi
  while app_running "$1" && [ "$i" -lt 15 ]; do sleep 1; i=$((i + 1)); done
  ! app_running "$1"
}

mv_to_home_trash() {  # fallback when Finder is not available
  local t="$H/.Trash" b
  mkdir -p "$t" 2>/dev/null; b="${1##*/}"
  [ -e "$t/$b" ] && b="$b $(date +%H%M%S)"
  mv "$1" "$t/$b" 2>/dev/null
}

move_to_trash() {  # move_to_trash path... → Finder Trash (recoverable). Returns 1 if something failed.
  local p fail=0
  [ $# -gt 0 ] || return 0
  if [ "$DRY_RUN" = 1 ]; then
    for p in "$@"; do say "  ${DIM}[dry-run]${RST} $(L "pindah ke Trash:" "move to Trash:") $(tilde "$p")"; done
    return 0
  fi
  if has osascript; then
    osascript -e 'on run argv' -e 'set theItems to {}' -e 'repeat with p in argv' \
      -e 'set end of theItems to (POSIX file (p as text) as alias)' -e 'end repeat' \
      -e 'tell application "Finder" to delete theItems' -e 'end run' "$@" >/dev/null 2>&1 && return 0
    for p in "$@"; do  # batch failed: retry one by one to find the culprit
      [ -e "$p" ] || continue
      osascript -e 'on run argv' -e 'tell application "Finder" to delete (POSIX file (item 1 of argv) as alias)' \
        -e 'end run' "$p" >/dev/null 2>&1 || { err "$(L "Gagal memindahkan:" "Couldn't move:") $(tilde "$p")"; fail=1; }
    done
  else
    for p in "$@"; do mv_to_home_trash "$p" || { err "$(L "Gagal memindahkan:" "Couldn't move:") $(tilde "$p")"; fail=1; }; done
  fi
  [ "$fail" = 0 ] || say "  ${DIM}$(L "Item yang gagal mungkin butuh izin admin — hapus manual lewat Finder." \
                                     "Failed items may need admin rights — remove them in Finder.")${RST}"
  return "$fail"
}

empty_trash_hint() {
  [ "$DRY_RUN" = 1 ] && return 0
  say "  ${DIM}$(L "Ruang disk baru lega setelah Trash dikosongkan (menu 1 › Trash)." \
                   "Disk space is freed once the Trash is emptied (menu 1 › Trash).")${RST}"
}

uninstall_app() {  # show the app + its leftover files, then move them to the Trash
  local app="$1" name bid kb s total_kb n i leftovers admin dup="" dir p
  name="${app##*/}"; name="${name%.app}"
  bid=$(app_bundle_id "$app")
  echo; info "$(L "Mencari file sisa $name…" "Looking for $name's leftover files…")"
  kb=$(size_kb "$app")
  mktmp; leftovers=$MKTMP; mktmp; admin=$MKTMP
  if [ -n "$bid" ] && [ -n "$APP_IDS" ]; then
    dup=$(awk -F'\t' -v b="$(lower "$bid")" -v p="$app" '$1 == b && $2 != p { print $2; exit }' "$APP_IDS")
  fi
  if [ -z "$dup" ]; then
    find_leftovers "$bid" "$name" "$app" "${USER_LEFTOVER_DIRS[@]}" > "$leftovers"
    find_leftovers "$bid" "$name" "$app" "${ADMIN_LEFTOVER_DIRS[@]}" > "$admin"
  fi
  U_PATH=(); U_KB=(); total_kb=$kb
  while IFS= read -r p; do
    [ -n "$p" ] && safe_path "$p" || continue
    s=$(size_kb "$p"); U_PATH+=("$p"); U_KB+=("$s"); total_kb=$((total_kb + s))
  done < "$leftovers"
  n=${#U_PATH[@]}

  say "  ${BOLD}$name${RST}  ${DIM}${bid:-$(L "bundle ID tidak diketahui" "unknown bundle ID")}${RST}"
  printf '  %9s  %s\n' "$(hsize "$kb")" "$(tilde "$app")"
  i=0
  while [ "$i" -lt "$n" ]; do
    printf '  %9s  %s\n' "$(hsize "${U_KB[$i]}")" "$(tilde "${U_PATH[$i]}")"
    i=$((i + 1))
  done
  [ "$n" -gt 0 ] || say "  ${DIM}$(L "Tidak ada file sisa di ~/Library." "No leftover files in ~/Library.")${RST}"
  if [ -n "$dup" ]; then
    warn "$(L "Ada salinan lain aplikasi ini ($(tilde "$dup")), jadi file sisanya tidak disentuh." \
              "Another copy of this app is installed ($(tilde "$dup")), so its files are kept.")"
  fi
  if [ -s "$admin" ]; then
    say "  ${DIM}$(L "Juga ada di luar folder home (butuh izin admin, tidak dihapus):" \
                     "Also found outside your home folder (needs admin, not removed):")${RST}"
    while IFS= read -r p; do say "  ${DIM}           $p${RST}"; done < "$admin"
  fi
  dir="${app%/*}"
  case "$dir" in
    /Applications|"$H/Applications") ;;
    *) say "  ${DIM}$(L "Aplikasi ini ada di folder sendiri ($(tilde "$dir")) — cek apakah ada uninstaller dari vendornya." \
                        "This app lives in its own folder ($(tilde "$dir")) — check whether the vendor ships an uninstaller.")${RST}" ;;
  esac
  say "  $(L "Total" "Total"): ${BOLD}$(hsize "$total_kb")${RST}  ($(L "aplikasi + $n file sisa" "app + $n leftover file(s)"))"
  if [ "$n" -gt 0 ]; then
    ask "  $(L "y = hapus aplikasi + file sisa, a = aplikasinya saja, Enter = batal: " \
               "y = remove app + leftovers, a = app only, Enter = cancel: ")" || return 1
  else
    ask "  $(L "y = hapus aplikasi, Enter = batal: " "y = remove the app, Enter = cancel: ")" || return 1
  fi
  case "$ANSWER" in
    y|Y|ya|Ya|yes|Yes) ;;
    a|A) if [ "$n" -eq 0 ]; then cancelled; return 1; fi
         U_PATH=(); total_kb=$kb ;;
    *) cancelled; return 1 ;;
  esac

  if [ "$DRY_RUN" != 1 ] && app_running "$app"; then
    warn "$name $(L "sedang berjalan." "is running.")"
    confirm "  $(L "Tutup $name sekarang?" "Quit $name now?")" || { cancelled; return 1; }
    if ! quit_app "$app" "$bid"; then
      err "$(L "$name belum tertutup — tutup manual, lalu ulangi." "$name is still running — quit it yourself, then try again.")"
      return 1
    fi
  fi
  if move_to_trash "$app" "${U_PATH[@]}"; then
    ok "$(L "$name di-uninstall — $(hsize "$total_kb") dipindah ke Trash." "$name uninstalled — $(hsize "$total_kb") moved to Trash.")"
  else
    return 1
  fi
}

uninstall_menu() {
  local list shown q n i name app
  mktmp; list=$MKTMP; list_apps > "$list"
  if [ ! -s "$list" ]; then warn "$(L "Tidak ada aplikasi ditemukan di /Applications." "No apps found in /Applications.")"; pause; return; fi
  ask "  $(L "Cari aplikasi (sebagian nama), Enter = tampilkan semua: " "Search apps (part of the name), Enter = show all: ")" || return
  q=$(lower "$ANSWER")
  mktmp; shown=$MKTMP
  awk -v q="$q" '{ n = $0; sub(/.*\//, "", n); sub(/\.app$/, "", n); if (q == "" || index(tolower(n), q)) print n "\t" $0 }' "$list" | sort -f > "$shown"
  n=$(wc -l < "$shown" | tr -d ' ')
  if [ "$n" -eq 0 ]; then warn "$(L "Tidak ada aplikasi yang cocok dengan '$ANSWER'." "No app matches '$ANSWER'.")"; pause; return; fi
  A_PATH=(); i=0; echo
  while IFS="$(printf '\t')" read -r name app; do
    i=$((i + 1)); A_PATH+=("$app")
    printf '  %3d  %s\n' "$i" "$name"
  done < "$shown"
  echo
  ask "  $(L "Nomor aplikasi yang mau di-uninstall (mis. 3 atau 2 5), Enter = kembali: " \
             "App number(s) to uninstall (e.g. 3 or 2 5), Enter = back: ")" || return
  [ -n "$ANSWER" ] || return
  parse_selection "$ANSWER" "$n"
  if [ "${#SEL[@]}" -eq 0 ]; then pause; return; fi
  load_app_ids "$list"
  for i in "${SEL[@]}"; do uninstall_app "${A_PATH[$i]}"; done
  echo; empty_trash_hint
  pause
}

apps_menu() {
  local thr now list data sorted total i app name kb last d n rank rare rare_kb=0 rare_n=0 when mark
  local t_rare t_active t_never t_today t_ago
  ask "  $(L "Anggap 'jarang dipakai' kalau tidak dibuka lebih dari berapa hari?" \
             "Treat an app as 'rarely used' after how many days unopened?") [$UNUSED_DAYS] " || return
  thr="${ANSWER:-$UNUSED_DAYS}"
  case "$thr" in *[!0-9]*) warn "$(L "Bukan angka, pakai $UNUSED_DAYS hari." "Not a number, using $UNUSED_DAYS days.")"; thr=$UNUSED_DAYS ;; esac
  thr=$((10#$thr))

  mktmp; list=$MKTMP; mktmp; data=$MKTMP; mktmp; sorted=$MKTMP
  list_apps > "$list"
  total=$(wc -l < "$list" | tr -d ' ')
  if [ "$total" -eq 0 ]; then warn "$(L "Tidak ada aplikasi ditemukan di /Applications." "No apps found in /Applications.")"; return; fi
  info "$(L "Memindai $total aplikasi… (ukuran + kapan terakhir dibuka)" "Scanning $total apps… (size + last opened)")"

  now=$(date +%s); i=0
  while IFS= read -r app <&3; do
    i=$((i + 1)); name="${app##*/}"; name="${name%.app}"
    [ "$name" = "Safari" ] && continue   # part of macOS, cannot be removed
    progress "[$i/$total] $name"
    kb=$(du -sk "$app" 2>/dev/null | awk '{s=$1} END{print s}')
    last=$(last_used_epoch "$app")
    if [ -n "$last" ]; then d=$(( (now - last) / 86400 )); [ "$d" -lt 0 ] && d=0; else d=-1; fi
    printf '%s|%s|%s|%s\n' "${kb:-0}" "$d" "$name" "$app" >> "$data"
  done 3< "$list"
  progress_done
  sort -t'|' -k1,1nr "$data" > "$sorted"

  # labels once, outside the loop (status labels padded to 6 characters)
  t_rare="$(L "jarang" "rare  ")"; t_active="$(L "aktif " "active")"
  t_never="$(L "tidak tercatat" "never recorded")"; t_today="$(L "hari ini" "today")"; t_ago="$(L "hari lalu" "days ago")"

  A_PATH=(); n=0; rank=0
  echo
  say "  ${BOLD}$(L "Aplikasi jarang dipakai (> $thr hari) + 10 terbesar" "Rarely used apps (> $thr days) + 10 largest")${RST}, $(L "urut dari yang terbesar:" "largest first:")"
  printf '  %s%3s  %9s  %-7s  %-18s  %s%s\n' "$BOLD" "No" "$(L "Ukuran" "Size")" "Status" "$(L "Terakhir dibuka" "Last opened")" "$(L "Nama" "Name")" "$RST"
  while IFS='|' read -r kb d name app; do
    rank=$((rank + 1)); rare=0
    if [ "$d" -lt 0 ] || [ "$d" -gt "$thr" ]; then rare=1; rare_kb=$((rare_kb + kb)); rare_n=$((rare_n + 1)); fi
    [ "$rare" = 1 ] || [ "$rank" -le 10 ] || continue
    n=$((n + 1)); A_PATH+=("$app")
    if [ "$d" -lt 0 ]; then when="$t_never"
    elif [ "$d" -eq 0 ]; then when="$t_today"
    else when="$d $t_ago"; fi
    if [ "$rare" = 1 ]; then mark="${YEL}${t_rare}${RST} "; else mark="${DIM}${t_active}${RST} "; fi
    printf '  %3d  %9s  %s  %-18s  %s\n' "$n" "$(hsize "$kb")" "$mark" "$when" "$name"
  done < "$sorted"
  echo
  say "  ${BOLD}$(L "$rare_n aplikasi jarang dipakai, total $(hsize "$rare_kb")." "$rare_n rarely used apps, $(hsize "$rare_kb") in total.")${RST}"
  say "  ${DIM}$(L "'tidak tercatat' = macOS tidak punya catatan kapan aplikasi dibuka" \
                   "'never recorded' = macOS has no record of the app being opened")${RST}"
  say "  ${DIM}$(L "(belum pernah dibuka, atau hanya dibuka lewat CLI)." "(never opened, or only launched from the CLI).")${RST}"
  echo
  ask "  $(L "Uninstall? Masukkan nomor (mis. 2 5), Enter = lewati: " "Uninstall? Enter numbers (e.g. 2 5), Enter = skip: ")" || return
  [ -n "$ANSWER" ] || return
  parse_selection "$ANSWER" "$n"
  if [ "${#SEL[@]}" -eq 0 ]; then info "$(L "Tidak ada yang dipilih." "Nothing selected.")"; return; fi
  load_app_ids "$list"
  for i in "${SEL[@]}"; do uninstall_app "${A_PATH[$i]}"; done
  echo; empty_trash_hint
}

# ═════════════════════════ 5. LARGEST FOLDERS ═════════════════════════
has_fda() { head -c1 "/Library/Application Support/com.apple.TCC/TCC.db" >/dev/null 2>&1; }

bigdata_menu() {
  local out fda=0 n i kb path p
  has_fda && fda=1
  info "$(L "Mengukur folder & data aplikasi terbesar… (bisa 1–3 menit)" "Measuring the largest folders & app data… (may take 1–3 minutes)")"
  mktmp; out=$MKTMP
  {
    find "$H/Library/Application Support" -mindepth 1 -maxdepth 1 2>/dev/null
    if [ "$fda" = 1 ]; then
      find "$H/Library/Containers" "$H/Library/Group Containers" -mindepth 1 -maxdepth 1 2>/dev/null
    fi
    for p in "$H/Library/Caches" "$H/Library/Logs" "$H/Library/Developer/Xcode" \
             "$H/Library/Developer/CoreSimulator" "$H/Library/Android/sdk"; do
      [ -e "$p" ] && printf '%s\n' "$p"
    done
    # home folders, except those protected by macOS and the OrbStack mount
    find "$H" -mindepth 1 -maxdepth 1 2>/dev/null | while IFS= read -r p; do
      case "${p##*/}" in
        Library|Desktop|Documents|Downloads|Pictures|Music|Movies|OrbStack|.Trash|.DS_Store) continue ;;
      esac
      printf '%s\n' "$p"
    done
  } | tr '\n' '\000' | xargs -0 -r du -sk 2>/dev/null | sort -nr | head -25 > "$out"

  B_PATH=(); n=0
  echo
  printf '  %s%3s  %9s  %s%s\n' "$BOLD" "No" "$(L "Ukuran" "Size")" "$(L "Lokasi" "Location")" "$RST"
  while IFS="$(printf '\t')" read -r kb path; do
    [ -n "$path" ] || continue
    n=$((n + 1)); B_PATH+=("$path")
    printf '  %3d  %9s  %s\n' "$n" "$(hsize "$kb")" "$(tilde "$path")"
  done < "$out"
  echo
  say "  ${DIM}$(L "Desktop, Documents, Downloads, Pictures, Music & Movies tidak dihitung (butuh izin macOS)." \
                   "Desktop, Documents, Downloads, Pictures, Music & Movies are skipped (they need macOS permission).")${RST}"
  if [ "$fda" = 0 ]; then
    say "  ${DIM}$(L "~/Library/Containers & Group Containers (termasuk disk OrbStack) belum dihitung. Beri Terminal" \
                     "~/Library/Containers & Group Containers (incl. the OrbStack disk) are not counted. Give Terminal")${RST}"
    say "  ${DIM}$(L "'Full Disk Access' di System Settings › Privacy & Security supaya ikut terhitung." \
                     "'Full Disk Access' in System Settings › Privacy & Security to include them.")${RST}"
  fi
  [ "$n" -gt 0 ] || { pause; return; }
  echo
  while true; do
    ask "  $(L "Tampilkan di Finder? Masukkan nomor, Enter = kembali: " "Reveal in Finder? Enter a number, Enter = back: ")" || return
    [ -n "$ANSWER" ] || return
    parse_selection "$ANSWER" "$n"
    for i in "${SEL[@]}"; do
      if has open; then open -R "${B_PATH[$i]}"; else say "  ${B_PATH[$i]}"; fi
    done
  done
}

# ═════════════════════════ MAIN MENU ═════════════════════════
header() {
  local total avail pct
  set -- $(disk_info)
  total=${1:-0}; avail=${2:-0}
  pct=$(awk -v t="$total" -v a="$avail" 'BEGIN{ if (t > 0) printf "%d", (t - a) * 100 / t; else print 0 }')
  echo
  printf '%s\n' "${BOLD}  Mac Cleaner${RST} ${DIM}v$VERSION${RST}"
  [ "$DRY_RUN" = 1 ] && say "  ${YEL}$(L "DRY-RUN: tidak ada yang benar-benar dihapus" "DRY RUN: nothing will actually be deleted")${RST}"
  say "  Disk: ${BOLD}$(hsize "$avail") $(L "kosong" "free")${RST} $(L "dari" "of") $(hsize "$total") (${pct}% $(L "terpakai" "used"))"
  echo
}

main() {
  [ "$(uname -s)" = Darwin ] || warn "$(L "Script ini dibuat untuk macOS — sebagian fitur tidak akan jalan di sistem ini." \
                                          "This script is made for macOS — some features won't work on this system.")"
  while true; do
    header
    say "  1) $(L "Bersihkan cache (dev tools, aplikasi, log, Trash)" "Clean caches (dev tools, apps, logs, Trash)")"
    say "  2) $(L "Docker: bersihkan / reset" "Docker: clean up / reset")"
    say "  3) $(L "Cek aplikasi jarang dipakai & paling besar" "Find rarely used & largest apps")"
    say "  4) $(L "Uninstall aplikasi (beserta file sisanya)" "Uninstall an app (with its leftover files)")"
    say "  5) $(L "Cek folder & data aplikasi terbesar" "Find the largest folders & app data")"
    say "  l) $(L "Bahasa: Indonesia ${DIM}(switch to English)${RST}" "Language: English ${DIM}(ganti ke Bahasa Indonesia)${RST}")"
    say "  q) $(L "Keluar" "Quit")"
    echo
    ask "  $(L "Pilih: " "Choose: ")" || break
    case "$ANSWER" in
      1) cache_menu; pause ;;
      2) docker_menu ;;
      3) apps_menu; pause ;;
      4) uninstall_menu ;;
      5) bigdata_menu ;;
      l|L) if [ "$UI_LANG" = id ]; then UI_LANG=en; else UI_LANG=id; fi
           save_lang
           ok "$(L "Bahasa diganti ke Indonesia." "Language switched to English.")" ;;
      q|Q) break ;;
    esac
  done
  echo; say "  $(L "Selesai." "Bye.")"
}

main
