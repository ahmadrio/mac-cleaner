#!/bin/bash
#
# Mac Cleaner — free up disk space on macOS (made with developers in mind).
#   • Clean caches: npm, Yarn, pnpm, Bun, Composer, pip, Go, Homebrew, Gradle,
#     Maven, Flutter, Xcode, ~/Library/Caches, logs, Trash
#   • Docker / OrbStack: pick containers, images, volumes, build cache or networks
#     to remove, clean everything unused, or do a full reset
#   • Find rarely used & large apps, and the largest folders / app data
#   • Uninstall apps together with their leftover files (moved to the Trash)
#   • Update apps installed with Homebrew, from a DMG, or from the App Store
#   • RAM: see memory pressure and the apps using the most memory, quit them, or purge
#
# Interface: English or Bahasa Indonesia (follows your macOS language,
# switchable from the menu or with --lang en|id).
#
# Usage:
#   bash mac-cleaner.command              # interactive menu
#   bash mac-cleaner.command --dry-run    # show what would be deleted, delete nothing
#   bash mac-cleaner.command --lang id    # force Bahasa Indonesia (or: en)
#
# No sudo needed (Homebrew may ask for your password when it updates some apps, and the
# optional RAM purge asks for it too).
# Everything is shown first and needs confirmation.
# Never touched: Desktop, Documents, Downloads, your code, Docker volumes
# (unless you pick them and type DELETE). Uninstalled apps and their leftovers go to the
# Trash, so they can be put back.
#
# https://github.com/ahmadrio/mac-cleaner — MIT License

VERSION="2.0.0"
DRY_RUN=0
UNUSED_DAYS=90
SHOW_HELP=0
OSA_SHOW_ERR=0   # 1 = osa_finder prints osascript's own error text to stderr (CLI only)
FINDER_DENIED=0  # set by osa_finder when macOS Automation blocks Finder
ENGINE=0          # 1 = hidden non-interactive mode used by the Mac app (see ENGINE MODE below)
ENGINE_ARGS=()
UI_LANG=""
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
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
    --engine)     shift; ENGINE=1; ENGINE_ARGS=("$@"); break ;;
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
TAB=$(printf '\t')
[ "$ENGINE" = 1 ] && { BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; CYN=""; RST=""; IS_TTY=0; }

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

# emit type field… → one protocol line "@@type<TAB>field<TAB>…" (TAB/newline inside a field → space)
emit() {
  local out="@@$1" a; shift
  for a in "$@"; do a=${a//$'\t'/ }; a=${a//$'\n'/ }; out="$out"$'\t'"$a"; done
  printf '%s\n' "$out"
}

# progress_step i total text: "[i/total] text" on a terminal, a @@progress record in engine mode
progress_step() { if [ "$ENGINE" = 1 ]; then emit progress "$3" "$1" "$2"; else progress "[$1/$2] $3"; fi; }

if [ "$ENGINE" = 1 ]; then  # engine mode: records instead of text, and never wait for input
  say()  { emit log say "$*"; }
  info() { emit log info "$*"; }
  ok()   { emit log ok "$*"; }
  warn() { emit log warn "$*"; }
  err()  { emit log err "$*"; }
  progress()      { emit progress "$*"; }
  progress_done() { :; }
  ask()          { emit error interactive "$1"; return 1; }
  confirm()      { emit error interactive "$1"; return 1; }
  confirm_word() { emit error interactive "$1"; return 1; }
  pause()        { emit error interactive "pause"; return 1; }
fi

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
emit_disk() { set -- $(disk_info); emit disk "${1:-0}" "${2:-0}"; }   # always two integers, even if df fails

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
  if [ "$DRY_RUN" = 1 ]; then
    info "$(L "Dry-run: tidak ada yang dihapus." "Dry run: nothing was deleted.")"
    if [ "$ENGINE" = 1 ]; then emit freed 0; emit_disk; fi
    return
  fi
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
  if [ "$ENGINE" = 1 ]; then
    if [ "$diff" -gt 0 ]; then emit freed "$diff"; else emit freed 0; fi
    emit_disk
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
  local p rc
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
      if has osascript; then
        if [ "$DRY_RUN" = 1 ]; then run osascript -e 'tell application "Finder" to empty trash'
        else
          OSA_SHOW_ERR=1; osa_finder -e 'tell application "Finder" to empty trash'; rc=$?; OSA_SHOW_ERR=0
          [ "$rc" = 0 ] || [ "$ENGINE" != 1 ] || warn "$(L "Gagal mengosongkan Trash." "Couldn't empty the Trash.")"
        fi
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

cache_scan() {  # → L_ID L_KB L_LABEL L_KIND (one entry per cache worth showing), T_SAFE, T_HEAVY
  local id kb
  init_paths
  info "$(L "Menghitung ukuran cache… (bisa 10–60 detik)" "Measuring caches… (may take 10–60 seconds)")"
  L_ID=(); L_KB=(); L_LABEL=(); L_KIND=(); T_SAFE=0; T_HEAVY=0
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
      case "$C_KIND" in safe) T_SAFE=$((T_SAFE + kb)) ;; heavy) T_HEAVY=$((T_HEAVY + kb)) ;; esac
    fi
  done
  progress_done
}

cache_run() {  # cache_run id… → clean those caches, then report the freed space
  local id before
  before=$(free_kb)
  for id in "$@"; do
    cache_def "$id"
    info "$(L "Membersihkan" "Cleaning") ${C_LABEL}…"
    cache_clean "$id"
  done
  report_freed "$before"
}

cache_menu() {
  local i n sum=0 ids
  cache_scan
  local t_safe=$T_SAFE t_heavy=$T_HEAVY

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

  ids=(); for i in "${SEL[@]}"; do ids+=("${L_ID[$i]}"); done
  cache_run "${ids[@]}"
}

# ═════════════════════════ 2. DOCKER ═════════════════════════
run_quiet() {  # like run, but hides the command's normal output (errors still show)
  if [ "$DRY_RUN" = 1 ]; then say "  ${DIM}[dry-run]${RST} $*"; return 0; fi
  "$@" >/dev/null
}

pad() { printf "%-${2}s" "$1"; }   # pad text before colouring it, so columns line up

# ── scans: write tab-separated rows to a file. Used by the menus below and by the engine ──
docker_app_present() { [ -d /Applications/Docker.app ]; }

docker_state() {  # prints: missing | running | stopped_orb | stopped_desktop | stopped_other
  if ! has docker; then echo missing
  elif docker info >/dev/null 2>&1; then echo running
  elif has orb; then echo stopped_orb
  elif docker_app_present; then echo stopped_desktop
  else echo stopped_other; fi
}

dk_counts() {  # → DK_NC containers, DK_NR running, DK_NI images (distinct), DK_NV volumes
  DK_NC=$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')
  DK_NR=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
  DK_NI=$(docker images -q 2>/dev/null | sort -u | wc -l | tr -d ' ')
  DK_NV=$(docker volume ls -q 2>/dev/null | wc -l | tr -d ' ')
}

dk_containers_scan() {  # dk_containers_scan out → "id<TAB>state<TAB>size<TAB>name<TAB>image" per container
  docker ps -a -s --format '{{.ID}}\t{{.State}}\t{{.Size}}\t{{.Names}}\t{{.Image}}' 2>/dev/null > "$1"
}

dk_images_in_use() {  # the full ids of the images that containers use, one per line, computed now
  docker ps -aq 2>/dev/null | xargs -r docker inspect --format '{{.Image}}' 2>/dev/null | sort -u
}

dk_images_scan() {  # dk_images_scan out → "ref<TAB>size<TAB>created<TAB>status" (in_use|unused|dangling; dangling images get their 12-char id as ref)
  local out=$1 used id ref size created short st
  used=$(dk_images_in_use)
  : > "$out"
  docker images --no-trunc --format '{{.ID}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' 2>/dev/null \
    | while IFS="$TAB" read -r id ref size created; do
        [ -n "$id" ] || continue
        short="${id#sha256:}"; short="${short:0:12}"
        case $'\n'"$used"$'\n' in
          *$'\n'"$id"$'\n'*) st=in_use ;;
          *) if [ "$ref" = "<none>:<none>" ]; then st=dangling; else st=unused; fi ;;
        esac
        [ "$ref" = "<none>:<none>" ] && ref="$short"
        printf '%s\t%s\t%s\t%s\n' "$ref" "$size" "$created" "$st"
      done >> "$out"
}

dk_volumes_scan() {  # dk_volumes_scan out → "name<TAB>links<TAB>size<TAB>used_by" (used_by is empty when no container uses it)
  local out=$1 raw v links size who more
  mktmp; raw=$MKTMP
  docker system df -v 2>/dev/null | awk '/^VOLUME NAME/ { f = 1; next } f && NF == 0 { f = 0 } f && NF >= 3 { print $1 "\t" $2 "\t" $NF }' > "$raw"
  if [ ! -s "$raw" ]; then   # fallback without sizes
    docker volume ls -q 2>/dev/null | while IFS= read -r v; do
      if docker volume ls -q -f dangling=true 2>/dev/null | grep -qx "$v"; then printf '%s\t0\t?\n' "$v"; else printf '%s\t1\t?\n' "$v"; fi
    done > "$raw"
  fi
  : > "$out"
  while IFS="$TAB" read -r v links size; do
    who=""
    if [ "$links" != 0 ]; then
      who=$(docker ps -a --filter "volume=$v" --format '{{.Names}}' 2>/dev/null | head -1)
      more=$(( links > 1 ? links - 1 : 0 ))
      [ "$more" -gt 0 ] && who="$who +$more"
      who=${who:-?}
    fi
    printf '%s\t%s\t%s\t%s\n' "$v" "$links" "$size" "$who" >> "$out"
  done < "$raw"
}

# ── actions: never prompt (the menus and the app confirm first). Each ends with report_freed where the menu did ──
dkr_containers() {  # dkr_containers id-or-name… → remove those containers (running ones are stopped first)
  # Each argument must equal an id or a name that docker lists now (checked live, like the images). `docker rm -f` itself
  # also takes id prefixes, so a stray "a" could force-remove an unlisted, even running, container. The ids found are
  # what docker gets, and a container named twice (by id and by name) is removed once.
  local before arg i=0 rc=0 map line cid cname hit byname seen=$'\n' keep=()
  map=$(docker ps -a --format '{{.ID}}\t{{.Names}}' 2>/dev/null)
  for arg in "$@"; do
    hit=""; byname=""
    while IFS= read -r line; do
      tab_fields "$line"; cid=${TF[0]}; cname=${TF[1]:-}
      [ -n "$cid" ] || continue
      if [ "$cid" = "$arg" ]; then hit=$cid; break; fi
      if [ -z "$byname" ] && [ "$cname" = "$arg" ]; then byname=$cid; fi
    done <<< "$map"
    [ -n "$hit" ] || hit=$byname
    if [ -z "$hit" ]; then warn "$(L "Dilewati (container tidak ditemukan):" "Skipped (container not found):") $arg"; continue; fi
    case "$seen" in *$'\n'"$hit"$'\n'*) continue ;; esac
    seen="$seen$hit"$'\n'; keep+=("$hit")
  done
  [ "${#keep[@]}" -gt 0 ] || return 0
  before=$(free_kb)
  for cid in "${keep[@]}"; do
    i=$((i + 1)); [ "$ENGINE" = 1 ] && progress_step "$i" "${#keep[@]}" "$(L "Menghapus container" "Removing container") $cid"
    run_quiet docker rm -f "$cid" || rc=1
  done
  report_freed "$before"
  return $rc
}

dkr_images() {  # dkr_images ref… → remove those images; refs a container uses (checked now, not from the list) are skipped
  local before ref i=0 rc=0 skip=0 used map line id short r found inuse keep=()
  used=$(dk_images_in_use)
  map=$(docker images --no-trunc --format '{{.ID}}\t{{.Repository}}:{{.Tag}}' 2>/dev/null)
  for ref in "$@"; do
    found=0; inuse=0
    while IFS= read -r line; do
      tab_fields "$line"; id=${TF[0]}; r=${TF[1]}
      short="${id#sha256:}"; short="${short:0:12}"
      if [ "$r" = "$ref" ] || { [ "$r" = "<none>:<none>" ] && [ "$short" = "$ref" ]; }; then
        found=1
        case $'\n'"$used"$'\n' in *$'\n'"$id"$'\n'*) inuse=1 ;; esac
      fi
    done <<< "$map"
    if [ "$found" = 0 ]; then warn "$(L "Dilewati (image tidak ditemukan):" "Skipped (image not found):") $ref"
    elif [ "$inuse" = 1 ]; then skip=$((skip + 1))
    else keep+=("$ref"); fi
  done
  [ "$skip" -gt 0 ] && warn "$(L "$skip image dilewati karena masih dipakai container — hapus containernya dulu (menu 1)." \
                                  "$skip image(s) skipped because a container uses them — remove the container first (option 1).")"
  [ "${#keep[@]}" -gt 0 ] || return 0
  before=$(free_kb)
  for ref in "${keep[@]}"; do
    i=$((i + 1)); [ "$ENGINE" = 1 ] && progress_step "$i" "${#keep[@]}" "$(L "Menghapus image" "Removing image") $ref"
    run_quiet docker rmi "$ref" || rc=1
  done
  report_freed "$before"
  return $rc
}

dkr_volumes() {  # dkr_volumes name… → remove those volumes; any a container uses (checked now) is skipped
  local before v i=0 rc=0 skip=0 who keep=()
  for v in "$@"; do
    if who=$(docker ps -a --filter "volume=$v" -q 2>/dev/null) && [ -z "$who" ]; then keep+=("$v"); else skip=$((skip + 1)); fi
  done
  [ "$skip" -gt 0 ] && warn "$(L "$skip volume dilewati karena masih dipakai container — hapus containernya dulu (menu 1)." \
                                  "$skip volume(s) skipped because a container uses them — remove the container first (option 1).")"
  [ "${#keep[@]}" -gt 0 ] || return 0
  before=$(free_kb)
  for v in "${keep[@]}"; do
    i=$((i + 1)); [ "$ENGINE" = 1 ] && progress_step "$i" "${#keep[@]}" "$(L "Menghapus volume" "Removing volume") $v"
    run_quiet docker volume rm "$v" || rc=1
  done
  report_freed "$before"
  return $rc
}

dkp_images_unused()   { local before rc=0; before=$(free_kb); run docker image prune -af || rc=1; report_freed "$before"; return $rc; }
dkp_images_dangling() { local before rc=0; before=$(free_kb); run docker image prune -f || rc=1; report_freed "$before"; return $rc; }
dkp_build_all()       { local before rc=0; before=$(free_kb); run docker builder prune -af || rc=1; report_freed "$before"; return $rc; }
dkp_build_old()       { local before rc=0; before=$(free_kb); run docker builder prune -af --filter until=168h || rc=1; report_freed "$before"; return $rc; }
dkp_networks()        { run docker network prune -f; }

dkp_safe() {
  local before rc=0
  before=$(free_kb)
  run docker container prune -f || rc=1
  run docker network prune -f || rc=1
  run docker image prune -f || rc=1
  run docker builder prune -af || rc=1
  report_freed "$before"
  return $rc
}

dkp_all_unused() {
  local before rc=0
  before=$(free_kb)
  run docker system prune -af || rc=1
  # Docker 23+ only prunes anonymous volumes unless -a is given; older versions don't know -a
  run docker volume prune -af 2>/dev/null || run docker volume prune -f || rc=1
  report_freed "$before"
  return $rc
}

dkp_wipe() {
  local before rc=0 ids vols
  before=$(free_kb)
  ids=($(docker ps -aq 2>/dev/null))
  [ "${#ids[@]}" -gt 0 ] && { run_quiet docker rm -f "${ids[@]}" || rc=1; }
  vols=($(docker volume ls -q 2>/dev/null))
  run docker system prune -af || rc=1
  [ "${#vols[@]}" -gt 0 ] && { run_quiet docker volume rm -f "${vols[@]}" || rc=1; }
  run docker builder prune -af || rc=1
  report_freed "$before"
  return $rc
}

dkp_orb_reset() {
  local before rc=0
  before=$(free_kb)
  run orb reset || rc=1
  report_freed "$before"
  return $rc
}

# ── menus ──
dk_containers() {
  local out n i id state size name image st running=0 ids
  mktmp; out=$MKTMP
  dk_containers_scan "$out"
  n=$(wc -l < "$out" | tr -d ' ')
  if [ "$n" -eq 0 ]; then ok "$(L "Tidak ada container." "No containers.")"; return; fi
  D_ID=(); D_STATE=(); D_NAME=(); i=0
  echo
  printf '  %s%3s  %-8s  %9s  %-28s  %s%s\n' "$BOLD" "No" "Status" "$(L "Ukuran" "Size")" "$(L "Nama" "Name")" "Image" "$RST"
  while IFS="$TAB" read -r id state size name image; do
    i=$((i + 1)); D_ID+=("$id"); D_STATE+=("$state"); D_NAME+=("$name")
    if [ "$state" = running ]; then st="${GRN}$(pad "$state" 8)${RST}"; else st="${DIM}$(pad "$state" 8)${RST}"; fi
    printf '  %3d  %s  %9s  %-28.28s  %s\n' "$i" "$st" "${size%% *}" "$name" "$image"
  done < "$out"
  echo
  ask "  $(L "Pilih nomor (mis. 1 3), s = semua yang berhenti, Enter = kembali: " \
             "Pick numbers (e.g. 1 3), s = all stopped, Enter = back: ")" || return
  case "$ANSWER" in
    "") return ;;
    s|S) SEL=(); i=0; while [ "$i" -lt "$n" ]; do [ "${D_STATE[$i]}" != running ] && SEL+=("$i"); i=$((i + 1)); done ;;
    *)   parse_selection "$ANSWER" "$n" ;;
  esac
  if [ "${#SEL[@]}" -eq 0 ]; then info "$(L "Tidak ada yang dipilih." "Nothing selected.")"; return; fi
  say "  $(L "Akan dihapus:" "Will remove:")"
  for i in "${SEL[@]}"; do
    say "    • ${D_NAME[$i]}  (${D_STATE[$i]})"
    [ "${D_STATE[$i]}" = running ] && running=$((running + 1))
  done
  [ "$running" -gt 0 ] && warn "$(L "$running container sedang berjalan dan akan dihentikan dulu." "$running running container(s) will be stopped first.")"
  warn "$(L "File di dalam container (bukan di volume) ikut hilang. Volume tidak disentuh." \
            "Files inside these containers (not in volumes) are lost. Volumes are not touched.")"
  confirm "  $(L "Lanjut?" "Continue?")" || { cancelled; return; }
  ids=(); for i in "${SEL[@]}"; do ids+=("${D_ID[$i]}"); done
  dkr_containers "${ids[@]}"
}

dk_images() {
  local out n i ref size created st shown line skip=0 refs
  local t_use t_unused t_dang
  mktmp; out=$MKTMP
  dk_images_scan "$out"
  n=$(wc -l < "$out" | tr -d ' ')
  if [ "$n" -eq 0 ]; then ok "$(L "Tidak ada image." "No images.")"; return; fi
  t_use="$(L "dipakai" "in use")"; t_unused="$(L "tak dipakai" "unused")"; t_dang="dangling"
  D_REF=(); D_ST=(); i=0
  echo
  printf '  %s%3s  %9s  %-11s  %-16s  %s%s\n' "$BOLD" "No" "$(L "Ukuran" "Size")" "Status" "$(L "Dibuat" "Created")" "Image" "$RST"
  while IFS= read -r line; do
    tab_fields "$line"; ref=${TF[0]}; size=${TF[1]}; created=${TF[2]}; st=${TF[3]}
    i=$((i + 1)); D_REF+=("$ref"); D_ST+=("$st")
    case "$st" in
      in_use)   shown="${GRN}$(pad "$t_use" 11)${RST}" ;;
      dangling) shown="${YEL}$(pad "$t_dang" 11)${RST}" ;;
      *)        shown="${YEL}$(pad "$t_unused" 11)${RST}" ;;
    esac
    case "$ref" in *:*) ;; *) ref="<none> ($ref)" ;; esac   # a dangling image has no name, only its short id
    printf '  %3d  %9s  %s  %-16.16s  %s\n' "$i" "$size" "$shown" "$created" "$ref"
  done < "$out"
  echo
  ask "  $(L "Pilih nomor, u = semua yang tak dipakai, d = dangling saja, Enter = kembali: " \
             "Pick numbers, u = all unused, d = dangling only, Enter = back: ")" || return
  case "$ANSWER" in
    "") return ;;
    u|U) confirm "  $(L "Hapus semua image yang tidak dipakai container?" "Remove every image not used by a container?")" || { cancelled; return; }
         dkp_images_unused; return ;;
    d|D) dkp_images_dangling; return ;;
    *)   parse_selection "$ANSWER" "$n" ;;
  esac
  if [ "${#SEL[@]}" -eq 0 ]; then info "$(L "Tidak ada yang dipilih." "Nothing selected.")"; return; fi
  S2=()
  for i in "${SEL[@]}"; do
    if [ "${D_ST[$i]}" = in_use ]; then skip=$((skip + 1)); else S2+=("$i"); fi
  done
  [ "$skip" -gt 0 ] && warn "$(L "$skip image dilewati karena masih dipakai container — hapus containernya dulu (menu 1)." \
                                  "$skip image(s) skipped because a container uses them — remove the container first (option 1).")"
  if [ "${#S2[@]}" -eq 0 ]; then return; fi
  say "  $(L "Akan dihapus:" "Will remove:")"
  for i in "${S2[@]}"; do say "    • ${D_REF[$i]}"; done
  confirm "  $(L "Lanjut?" "Continue?")" || { cancelled; return; }
  refs=(); for i in "${S2[@]}"; do refs+=("${D_REF[$i]}"); done
  dkr_images "${refs[@]}"
}

dk_volumes() {
  local out n i v links size who skip=0 line names
  mktmp; out=$MKTMP
  dk_volumes_scan "$out"
  n=$(wc -l < "$out" | tr -d ' ')
  if [ "$n" -eq 0 ]; then ok "$(L "Tidak ada volume." "No volumes.")"; return; fi
  D_VOL=(); D_LINKS=(); i=0
  echo
  printf '  %s%3s  %9s  %-24s  %s%s\n' "$BOLD" "No" "$(L "Ukuran" "Size")" "$(L "Dipakai oleh" "Used by")" "Volume" "$RST"
  while IFS= read -r line; do
    tab_fields "$line"; v=${TF[0]}; links=${TF[1]}; size=${TF[2]}; who=${TF[3]}
    i=$((i + 1)); D_VOL+=("$v"); D_LINKS+=("$links")
    if [ "$links" = 0 ]; then
      who="${YEL}$(pad "$(L "tak dipakai" "unused")" 24)${RST}"
    else
      who="${GRN}$(printf '%-24.24s' "$who")${RST}"
    fi
    printf '  %3d  %9s  %s  %s\n' "$i" "$size" "$who" "$v"
  done < "$out"
  echo
  ask "  $(L "Pilih nomor, u = semua yang tak dipakai, Enter = kembali: " "Pick numbers, u = all unused, Enter = back: ")" || return
  case "$ANSWER" in
    "") return ;;
    u|U) SEL=(); i=0; while [ "$i" -lt "$n" ]; do [ "${D_LINKS[$i]}" = 0 ] && SEL+=("$i"); i=$((i + 1)); done ;;
    *)   parse_selection "$ANSWER" "$n" ;;
  esac
  S2=()
  for i in "${SEL[@]}"; do
    if [ "${D_LINKS[$i]}" != 0 ]; then skip=$((skip + 1)); else S2+=("$i"); fi
  done
  [ "$skip" -gt 0 ] && warn "$(L "$skip volume dilewati karena masih dipakai container — hapus containernya dulu (menu 1)." \
                                  "$skip volume(s) skipped because a container uses them — remove the container first (option 1).")"
  if [ "${#S2[@]}" -eq 0 ]; then info "$(L "Tidak ada volume yang bisa dihapus." "No volumes to remove.")"; return; fi
  say "  $(L "Akan dihapus:" "Will remove:")"
  for i in "${S2[@]}"; do say "    • ${D_VOL[$i]}"; done
  warn "$(L "Data di volume ini (mis. database) hilang permanen." "The data in these volumes (e.g. databases) is gone for good.")"
  confirm_word "$(L "HAPUS" "DELETE")" || { cancelled; return; }
  names=(); for i in "${S2[@]}"; do names+=("${D_VOL[$i]}"); done
  dkr_volumes "${names[@]}"
}

dk_build_cache() {
  local size
  size=$(docker system df 2>/dev/null | awk '/^Build Cache/ { print $5 }')
  say "  Build cache: ${BOLD}${size:-?}${RST}"
  ask "  $(L "a = hapus semua, o = hanya yang lebih lama dari 7 hari, Enter = batal: " \
             "a = remove all, o = only older than 7 days, Enter = cancel: ")" || return
  case "$ANSWER" in
    a|A) dkp_build_all ;;
    o|O) dkp_build_old ;;
    *)   cancelled ;;
  esac
}

dk_networks() {
  say "  $(L "Network buatan sendiri yang tidak dipakai container akan dihapus (bridge/host/none aman)." \
             "Custom networks not used by any container will be removed (bridge/host/none are kept).")"
  confirm "  $(L "Lanjut?" "Continue?")" || { cancelled; return; }
  dkp_networks
}

docker_safe() {
  local stopped
  stopped=$(docker ps -a --filter status=exited --filter status=created --filter status=dead \
            --format '{{.Names}}  ({{.Image}}, {{.Status}})' 2>/dev/null)
  if [ -n "$stopped" ]; then
    say "  $(L "Container berhenti yang akan dihapus:" "Stopped containers that will be removed:")"
    printf '%s\n' "$stopped" | sed 's/^/    • /'
    warn "$(L "File yang ditulis di dalam container (bukan di volume) ikut hilang. Volume TIDAK disentuh." \
              "Files written inside these containers (not in volumes) will be lost. Volumes are NOT touched.")"
  fi
  confirm "  $(L "Lanjut bersihkan?" "Go ahead?")" || { cancelled; return; }
  dkp_safe
}

dk_all_unused() {
  say "  $(L "Akan dihapus: container yang berhenti, SEMUA image tak dipakai, network tak dipakai," \
             "Will remove: stopped containers, ALL unused images, unused networks,")"
  say "  $(L "build cache, dan SEMUA volume yang tidak dipakai container." "build cache and ALL volumes not used by a container.")"
  warn "$(L "Termasuk data database proyek yang container-nya sudah 'docker compose down'." \
            "This includes database data of projects stopped with 'docker compose down'.") ${RED}$(L "Tidak bisa dikembalikan." "This cannot be undone.")${RST}"
  confirm_word "$(L "HAPUS" "DELETE")" || { cancelled; return; }
  dkp_all_unused
}

dk_wipe_all() {
  dk_counts
  warn "$(L "Ini menghapus SEMUA data Docker: $DK_NC container ($DK_NR berjalan), $DK_NI image, $DK_NV volume, network & build cache." \
            "This deletes ALL Docker data: $DK_NC containers ($DK_NR running), $DK_NI images, $DK_NV volumes, networks & build cache.")"
  warn "$(L "Pastikan database/volume penting sudah di-backup." "Make sure important databases/volumes are backed up.")"
  confirm_word RESET || { cancelled; return; }
  dkp_wipe
}

orb_reset() {
  warn "$(L "Factory reset: menghapus SEMUA data OrbStack — container, image, volume, Kubernetes & Linux machine." \
            "Factory reset: deletes ALL OrbStack data — containers, images, volumes, Kubernetes and Linux machines.")"
  warn "$(L "Pastikan database/volume penting sudah di-backup." "Make sure important databases/volumes are backed up.")"
  confirm_word RESET || { cancelled; return 1; }
  dkp_orb_reset
  return 0
}

docker_menu() {
  local engine="Docker" state
  has orb && engine="OrbStack"
  state=$(docker_state)
  if [ "$state" = missing ]; then err "$(L "Perintah docker tidak ditemukan." "docker command not found.")"; pause; return; fi
  if [ "$state" != running ]; then
    warn "$engine $(L "belum berjalan." "is not running.")"
    case "$state" in
      stopped_orb)
        confirm "  $(L "Jalankan OrbStack sekarang?" "Start OrbStack now?")" || return
        orb start ;;
      stopped_desktop)
        confirm "  $(L "Buka Docker Desktop?" "Open Docker Desktop?")" && open -a Docker && \
          info "$(L "Tunggu sampai Docker siap, lalu buka menu ini lagi." "Wait until Docker is ready, then open this menu again.")"
        pause; return ;;
    esac
    if ! docker info >/dev/null 2>&1; then err "$(L "Docker belum siap." "Docker is not ready.")"; pause; return; fi
  fi
  while true; do
    echo; say "${BOLD}  Docker ($engine)${RST}"
    docker system df 2>/dev/null | sed 's/^/  /'
    echo
    say "  ${DIM}$(L "Pilih per jenis:" "Pick by type:")${RST}"
    say "  1) Container     — $(L "pilih container yang dihapus" "choose which containers to remove")"
    say "  2) Image         — $(L "pilih image, atau semua yang tak dipakai" "choose images, or all unused ones")"
    say "  3) Volume        — $(L "pilih volume" "choose volumes") ${RED}$(L "(data ikut hilang)" "(data is lost)")${RST}"
    say "  4) Build cache   — $(L "semua, atau yang lebih lama dari 7 hari" "all, or only older than 7 days")"
    say "  5) Network       — $(L "network yang tidak dipakai" "unused networks")"
    say "  ${DIM}$(L "Sekaligus:" "All at once:")${RST}"
    say "  6) $(L "Bersihkan cepat (aman) — container berhenti, image dangling, network, build cache" \
                  "Quick clean (safe) — stopped containers, dangling images, networks, build cache")"
    say "  7) $(L "Hapus semua yang tak dipakai — + semua image & volume tak dipakai" \
                  "Remove everything unused — + all unused images & volumes") ${RED}$(L "(data)" "(data)")${RST}"
    say "  8) $(L "Hapus SEMUA data Docker — termasuk yang sedang berjalan" \
                  "Delete ALL Docker data — including running containers") ${RED}(reset)${RST}"
    if has orb; then
      say "  9) $(L "Factory reset OrbStack — + Linux machine & Kubernetes" \
                    "Factory reset OrbStack — + Linux machines & Kubernetes") ${RED}(reset)${RST}"
    else
      say "  ${DIM}$(L "Mengecilkan disk Docker Desktop: Docker Desktop › Troubleshoot › Clean / Purge data" \
                       "To shrink Docker Desktop's disk: Docker Desktop › Troubleshoot › Clean / Purge data")${RST}"
    fi
    say "  b) $(L "Kembali" "Back")"
    ask "  $(L "Pilih: " "Choose: ")" || return
    case "$ANSWER" in
      1) dk_containers ;;
      2) dk_images ;;
      3) dk_volumes ;;
      4) dk_build_cache ;;
      5) dk_networks ;;
      6) docker_safe ;;
      7) dk_all_unused ;;
      8) dk_wipe_all ;;
      9) if has orb && orb_reset; then pause; return; fi ;;
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

app_dirs() {  # the folders that hold apps, one per line: MAC_CLEANER_APP_DIRS (colon-separated, for tests) or the defaults
  local d rest
  if [ -n "${MAC_CLEANER_APP_DIRS:-}" ]; then
    rest=$MAC_CLEANER_APP_DIRS
    while [ -n "$rest" ]; do
      d=${rest%%:*}
      case "$rest" in *:*) rest=${rest#*:} ;; *) rest="" ;; esac
      [ -z "$d" ] || printf '%s\n' "$d"
    done
  else
    printf '%s\n' /Applications "$H/Applications"
  fi
}

SELF_BUNDLE_ID="io.github.ahmadrio.mac-cleaner"
list_apps() {  # every removable .app in the app folders (one level of subfolders); never Safari or Mac Cleaner itself
  local dirs=() d excl=""
  while IFS= read -r d; do dirs+=("$d"); done < <(app_dirs)
  [ "${#dirs[@]}" -gt 0 ] || return 0   # find with no folder would scan the current directory
  [ -z "${MAC_CLEANER_APP:-}" ] || excl="${MAC_CLEANER_APP%/}"
  if has mdfind; then excl="$excl"$'\n'"$(mdfind "kMDItemCFBundleIdentifier == '$SELF_BUNDLE_ID'" 2>/dev/null)"; fi
  find "${dirs[@]}" -maxdepth 2 -type d -name '*.app' ! -path "*"$'\n'"*" -prune -print 2>/dev/null \
    | grep -v '/Safari\.app$' | sort -u \
    | EXCL="$excl" awk 'BEGIN { n = split(ENVIRON["EXCL"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") x[a[i]] = 1 }
                        !($0 in x)'
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
    i=$((i + 1)); progress_step "$i" "$total" "$(L "Membaca info aplikasi" "Reading app info")"
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
  local i=0 n="${1##*/}"
  n="${n%.app}"
  if [ -n "$2" ]; then
    osascript -e 'on run argv' -e 'tell application id (item 1 of argv) to quit' -e 'end run' "$2" >/dev/null 2>&1
  else
    osascript -e 'on run argv' -e 'tell application (item 1 of argv) to quit' -e 'end run' "$n" >/dev/null 2>&1
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

osa_finder() {  # osa_finder osascript-args… → 0 ok, 2 Finder not allowed (macOS Automation), 1 other failure
  local e
  e=$(osascript "$@" 2>&1 >/dev/null) && return 0
  [ "$OSA_SHOW_ERR" = 1 ] && [ "$ENGINE" != 1 ] && printf '%s\n' "$e" >&2
  case "$e" in
    *-1743*|*"Not authorized"*)
      FINDER_DENIED=1
      [ "$ENGINE" = 1 ] && emit error finder_denied "$e"
      return 2 ;;
  esac
  return 1
}

move_to_trash() {  # move_to_trash path… → Finder Trash (recoverable). Returns 1 if something failed.
  local p fail=0 rc
  [ $# -gt 0 ] || return 0
  if [ "$DRY_RUN" = 1 ]; then
    for p in "$@"; do say "  ${DIM}[dry-run]${RST} $(L "pindah ke Trash:" "move to Trash:") $(tilde "$p")"; done
    return 0
  fi
  if [ "${MAC_CLEANER_TRASH:-}" != home ] && has osascript; then
    osa_finder -e 'on run argv' -e 'set theItems to {}' -e 'repeat with p in argv' \
      -e 'set end of theItems to (POSIX file (p as text) as alias)' -e 'end repeat' \
      -e 'tell application "Finder" to delete theItems' -e 'end run' "$@"
    rc=$?
    [ "$rc" = 0 ] && return 0
    if [ "$rc" = 2 ]; then  # Finder is not allowed: retrying or moving by hand would not help
      err "$(L "Finder tidak diizinkan. Beri izin di System Settings › Privacy & Security › Automation." \
               "Finder isn't allowed. Grant access in System Settings › Privacy & Security › Automation.")"
      return 1
    fi
    for p in "$@"; do  # batch failed: retry one by one to find the culprit
      [ -e "$p" ] || continue
      osa_finder -e 'on run argv' -e 'tell application "Finder" to delete (POSIX file (item 1 of argv) as alias)' \
        -e 'end run' "$p"
      rc=$?
      [ "$rc" = 0 ] && continue
      err "$(L "Gagal memindahkan:" "Couldn't move:") $(tilde "$p")"; fail=1
      [ "$rc" = 2 ] && return 1
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

in_leftover_dir() {  # in_leftover_dir path → success when the path sits directly inside one of USER_LEFTOVER_DIRS
  local d
  for d in "${USER_LEFTOVER_DIRS[@]}"; do [ "${1%/*}" = "$d" ] && return 0; done
  return 1
}

path_has_symlink() {  # path_has_symlink path → success when the path, or a folder between it and HOME, is a symlink
  local d=$1
  while [ -n "$d" ] && [ "$d" != "$H" ]; do
    [ -L "$d" ] && return 0
    d=${d%/*}
  done
  return 1
}

leftover_allowed() {  # leftover_allowed path → may this leftover be moved to the Trash? (exact, nothing is trusted)
  local p=$1 d
  [ -n "$p" ] && [ -e "$p" ] || return 1
  safe_path "$p" || return 1
  in_leftover_dir "$p" || return 1
  case "${p##*/}" in ""|.|..) return 1 ;; esac                     # "Caches/." would be the whole folder
  for d in "${USER_LEFTOVER_DIRS[@]}"; do [ "$p" = "$d" ] || [ "$p" -ef "$d" ] && return 1; done   # e.g. Preferences/BYHOST (-ef: APFS ignores case)
  ! path_has_symlink "$p"                                           # a symlink may point anywhere, even outside HOME
}

is_listed_app() {  # is_listed_app app listfile → success when app is a real .app folder and exactly one line of the list_apps output
  local l
  case "$1" in /*.app) ;; *) return 1 ;; esac
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  while IFS= read -r l; do [ "$l" = "$1" ] && return 0; done < "$2"
  return 1
}

# uninstall_plan app → UN_NAME UN_BID UN_APP_KB UN_DUP UN_VENDOR (0/1), U_PATH + U_KB (user leftovers that pass safe_path),
# U_ADMIN (file: leftover paths outside HOME, which are only reported). APP_IDS must be loaded.
uninstall_plan() {
  local app="$1" leftovers s p dir d
  UN_NAME="${app##*/}"; UN_NAME="${UN_NAME%.app}"
  UN_BID=$(app_bundle_id "$app")
  UN_APP_KB=$(size_kb "$app")
  UN_DUP=""
  mktmp; leftovers=$MKTMP; mktmp; U_ADMIN=$MKTMP
  if [ -n "$UN_BID" ] && [ -n "$APP_IDS" ]; then
    UN_DUP=$(awk -F'\t' -v b="$(lower "$UN_BID")" -v p="$app" '$1 == b && $2 != p { print $2; exit }' "$APP_IDS")
  fi
  if [ -z "$UN_DUP" ]; then
    find_leftovers "$UN_BID" "$UN_NAME" "$app" "${USER_LEFTOVER_DIRS[@]}" > "$leftovers"
    find_leftovers "$UN_BID" "$UN_NAME" "$app" "${ADMIN_LEFTOVER_DIRS[@]}" > "$U_ADMIN"
  fi
  U_PATH=(); U_KB=()
  while IFS= read -r p; do
    [ -n "$p" ] && safe_path "$p" || continue
    s=$(size_kb "$p"); U_PATH+=("$p"); U_KB+=("$s")
  done < "$leftovers"
  UN_VENDOR=1; dir="${app%/*}"
  while IFS= read -r d; do [ "$dir" = "$d" ] && UN_VENDOR=0; done < <(app_dirs)
}

# uninstall_run app leftover… → move the app and those leftovers to the Trash. A running app is quit after
# asking (CLI) or refused with @@error running (engine). The caller has already validated every path.
uninstall_run() {
  local app="$1" name bid total_kb
  shift
  name="${app##*/}"; name="${name%.app}"
  if [ "$DRY_RUN" != 1 ] && app_running "$app"; then
    if [ "$ENGINE" = 1 ]; then
      emit error running "$(L "$name sedang berjalan." "$name is running.")"; return 1
    fi
    bid=$(app_bundle_id "$app")
    warn "$name $(L "sedang berjalan." "is running.")"
    confirm "  $(L "Tutup $name sekarang?" "Quit $name now?")" || { cancelled; return 1; }
    if ! quit_app "$app" "$bid"; then
      err "$(L "$name belum tertutup — tutup manual, lalu ulangi." "$name is still running — quit it yourself, then try again.")"
      return 1
    fi
  fi
  total_kb=$(size_kb "$app" "$@")
  if move_to_trash "$app" "$@"; then
    ok "$(L "$name di-uninstall — $(hsize "$total_kb") dipindah ke Trash." "$name uninstalled — $(hsize "$total_kb") moved to Trash.")"
  else
    return 1
  fi
}

uninstall_app() {  # show the app + its leftover files, then move them to the Trash
  local app="$1" name total_kb n i p
  name="${app##*/}"; name="${name%.app}"
  echo; info "$(L "Mencari file sisa $name…" "Looking for $name's leftover files…")"
  uninstall_plan "$app"
  total_kb=$UN_APP_KB
  for p in "${U_KB[@]}"; do total_kb=$((total_kb + p)); done
  n=${#U_PATH[@]}

  say "  ${BOLD}$UN_NAME${RST}  ${DIM}${UN_BID:-$(L "bundle ID tidak diketahui" "unknown bundle ID")}${RST}"
  printf '  %9s  %s\n' "$(hsize "$UN_APP_KB")" "$(tilde "$app")"
  i=0
  while [ "$i" -lt "$n" ]; do
    printf '  %9s  %s\n' "$(hsize "${U_KB[$i]}")" "$(tilde "${U_PATH[$i]}")"
    i=$((i + 1))
  done
  [ "$n" -gt 0 ] || say "  ${DIM}$(L "Tidak ada file sisa di ~/Library." "No leftover files in ~/Library.")${RST}"
  if [ -n "$UN_DUP" ]; then
    warn "$(L "Ada salinan lain aplikasi ini ($(tilde "$UN_DUP")), jadi file sisanya tidak disentuh." \
              "Another copy of this app is installed ($(tilde "$UN_DUP")), so its files are kept.")"
  fi
  if [ -s "$U_ADMIN" ]; then
    say "  ${DIM}$(L "Juga ada di luar folder home (butuh izin admin, tidak dihapus):" \
                     "Also found outside your home folder (needs admin, not removed):")${RST}"
    while IFS= read -r p; do say "  ${DIM}           $p${RST}"; done < "$U_ADMIN"
  fi
  if [ "$UN_VENDOR" = 1 ]; then
    say "  ${DIM}$(L "Aplikasi ini ada di folder sendiri ($(tilde "${app%/*}")) — cek apakah ada uninstaller dari vendornya." \
                    "This app lives in its own folder ($(tilde "${app%/*}")) — check whether the vendor ships an uninstaller.")${RST}"
  fi
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
         U_PATH=() ;;
    *) cancelled; return 1 ;;
  esac
  uninstall_run "$app" "${U_PATH[@]}"
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

apps_scan() {  # apps_scan outfile → "kb|days|name|path" lines, largest first (days = -1 when macOS has no record). 1 if no apps.
  local list data total i app name kb last d now   # also sets AS_LIST = temp file with the app paths that were scanned
  mktmp; list=$MKTMP; mktmp; data=$MKTMP; AS_LIST=$list
  list_apps > "$list"
  total=$(wc -l < "$list" | tr -d ' ')
  if [ "$total" -eq 0 ]; then warn "$(L "Tidak ada aplikasi ditemukan di /Applications." "No apps found in /Applications.")"; return 1; fi
  info "$(L "Memindai $total aplikasi… (ukuran + kapan terakhir dibuka)" "Scanning $total apps… (size + last opened)")"

  now=$(date +%s); i=0
  while IFS= read -r app <&3; do
    i=$((i + 1)); name="${app##*/}"; name="${name%.app}"
    [ "$name" = "Safari" ] && continue   # part of macOS, cannot be removed
    progress_step "$i" "$total" "$name"
    kb=$(du -sk "$app" 2>/dev/null | awk '{s=$1} END{print s}')
    last=$(last_used_epoch "$app")
    if [ -n "$last" ]; then d=$(( (now - last) / 86400 )); [ "$d" -lt 0 ] && d=0; else d=-1; fi
    printf '%s|%s|%s|%s\n' "${kb:-0}" "$d" "$name" "$app" >> "$data"
  done 3< "$list"
  progress_done
  sort -t'|' -k1,1nr "$data" > "$1"
}

apps_select() {  # apps_select days sortedfile → "kb<TAB>days<TAB>rare<TAB>name<TAB>path" for each row to show (rare, or one of the 10 largest)
  local kb d name app rank=0 rare       # sets RARE_N and RARE_KB (over all apps), so call it without a pipe or $( )
  RARE_N=0; RARE_KB=0
  while IFS='|' read -r kb d name app; do
    rank=$((rank + 1)); rare=0
    if [ "$d" -lt 0 ] || [ "$d" -gt "$1" ]; then rare=1; RARE_KB=$((RARE_KB + kb)); RARE_N=$((RARE_N + 1)); fi
    [ "$rare" = 1 ] || [ "$rank" -le 10 ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$kb" "$d" "$rare" "$name" "$app"
  done < "$2"
}

apps_menu() {
  local thr sorted shown n i app name kb d rare when mark
  local t_rare t_active t_never t_today t_ago
  ask "  $(L "Anggap 'jarang dipakai' kalau tidak dibuka lebih dari berapa hari?" \
             "Treat an app as 'rarely used' after how many days unopened?") [$UNUSED_DAYS] " || return
  thr="${ANSWER:-$UNUSED_DAYS}"
  case "$thr" in *[!0-9]*) warn "$(L "Bukan angka, pakai $UNUSED_DAYS hari." "Not a number, using $UNUSED_DAYS days.")"; thr=$UNUSED_DAYS ;; esac
  thr=$((10#$thr))

  mktmp; sorted=$MKTMP
  apps_scan "$sorted" || return
  mktmp; shown=$MKTMP
  apps_select "$thr" "$sorted" > "$shown"

  # labels once, outside the loop (status labels padded to 6 characters)
  t_rare="$(L "jarang" "rare  ")"; t_active="$(L "aktif " "active")"
  t_never="$(L "tidak tercatat" "never recorded")"; t_today="$(L "hari ini" "today")"; t_ago="$(L "hari lalu" "days ago")"

  A_PATH=(); n=0
  echo
  say "  ${BOLD}$(L "Aplikasi jarang dipakai (> $thr hari) + 10 terbesar" "Rarely used apps (> $thr days) + 10 largest")${RST}, $(L "urut dari yang terbesar:" "largest first:")"
  printf '  %s%3s  %9s  %-7s  %-18s  %s%s\n' "$BOLD" "No" "$(L "Ukuran" "Size")" "Status" "$(L "Terakhir dibuka" "Last opened")" "$(L "Nama" "Name")" "$RST"
  while IFS="$TAB" read -r kb d rare name app; do
    n=$((n + 1)); A_PATH+=("$app")
    if [ "$d" -lt 0 ]; then when="$t_never"
    elif [ "$d" -eq 0 ]; then when="$t_today"
    else when="$d $t_ago"; fi
    if [ "$rare" = 1 ]; then mark="${YEL}${t_rare}${RST} "; else mark="${DIM}${t_active}${RST} "; fi
    printf '  %3d  %9s  %s  %-18s  %s\n' "$n" "$(hsize "$kb")" "$mark" "$when" "$name"
  done < "$shown"
  echo
  say "  ${BOLD}$(L "$RARE_N aplikasi jarang dipakai, total $(hsize "$RARE_KB")." "$RARE_N rarely used apps, $(hsize "$RARE_KB") in total.")${RST}"
  say "  ${DIM}$(L "'tidak tercatat' = macOS tidak punya catatan kapan aplikasi dibuka" \
                   "'never recorded' = macOS has no record of the app being opened")${RST}"
  say "  ${DIM}$(L "(belum pernah dibuka, atau hanya dibuka lewat CLI)." "(never opened, or only launched from the CLI).")${RST}"
  echo
  ask "  $(L "Uninstall? Masukkan nomor (mis. 2 5), Enter = lewati: " "Uninstall? Enter numbers (e.g. 2 5), Enter = skip: ")" || return
  [ -n "$ANSWER" ] || return
  parse_selection "$ANSWER" "$n"
  if [ "${#SEL[@]}" -eq 0 ]; then info "$(L "Tidak ada yang dipilih." "Nothing selected.")"; return; fi
  load_app_ids "$AS_LIST"
  for i in "${SEL[@]}"; do uninstall_app "${A_PATH[$i]}"; done
  echo; empty_trash_hint
}

# ═════════════════════════ 5. LARGEST FOLDERS ═════════════════════════
has_fda() { head -c1 "/Library/Application Support/com.apple.TCC/TCC.db" >/dev/null 2>&1; }

bigdata_scan() {  # bigdata_scan outfile → sets BD_FDA (0/1); writes "kb<TAB>path" lines, largest first (top 25)
  local fda=0 p
  has_fda && fda=1
  BD_FDA=$fda
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
  } | tr '\n' '\000' | xargs -0 -r du -sk 2>/dev/null | sort -nr | head -25 > "$1"
}

bigdata_menu() {
  local out fda n i kb path
  info "$(L "Mengukur folder & data aplikasi terbesar… (bisa 1–3 menit)" "Measuring the largest folders & app data… (may take 1–3 minutes)")"
  mktmp; out=$MKTMP
  bigdata_scan "$out"; fda=$BD_FDA

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

# ═════════════════════════ 6. UPDATES ═════════════════════════
CASK_URL="https://formulae.brew.sh/api/cask.json"
CASK_CACHE="$H/Library/Caches/mac-cleaner/cask.json"

plist_get() {  # plist_get app key → value from the app's Info.plist
  local v=""
  [ -f "$1/Contents/Info.plist" ] || return 0
  if [ -x /usr/libexec/PlistBuddy ]; then
    v=$(/usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null)
  elif has defaults; then
    v=$(defaults read "$1/Contents/Info" "$2" 2>/dev/null)
  fi
  printf '%s' "$v"
}

app_version() {  # the version macOS shows for an app, falling back to its build number
  local v
  v=$(plist_get "$1" CFBundleShortVersionString)
  [ -n "$v" ] || v=$(plist_get "$1" CFBundleVersion)
  printf '%s' "$v"
}

ver_newer() {  # ver_newer A B → success if version A is newer than B
  awk -v a="$1" -v b="$2" 'BEGIN {
    sub(/[ ,(].*/, "", a); sub(/[ ,(].*/, "", b)
    if (a !~ /^[0-9]/ || b !~ /^[0-9]/) exit 1
    na = split(a, x, /[^0-9A-Za-z]+/); nb = split(b, y, /[^0-9A-Za-z]+/)
    n = (na < nb) ? na : nb
    for (i = 1; i <= n; i++) {
      if (x[i] ~ /^[0-9]+$/ && y[i] ~ /^[0-9]+$/) {
        if (x[i] + 0 > y[i] + 0) exit 0
        if (x[i] + 0 < y[i] + 0) exit 1
      } else {
        if (x[i] > y[i]) exit 0
        if (x[i] < y[i]) exit 1
      }
    }
    exit 1   # equal, or one is just a longer form of the other (6.2.11 vs 6.2.11.43613)
  }'
}

ver_core() {  # ver_core "160.0b5" → "160.0": only the leading numbers and dots
  printf '%s' "$1" | sed -E 's/^([0-9][0-9.]*).*/\1/; s/\.+$//'
}

newest_version() {  # newest_version v1 v2 ... → the newest one
  local best="" v
  for v in "$@"; do
    if [ -z "$best" ] || ver_newer "$v" "$best"; then best="$v"; fi
  done
  printf '%s' "$best"
}

cask_catalog() {  # → path to Homebrew's public cask catalog (refreshed once a day), or nothing
  local f="$CASK_CACHE"
  mkdir -p "${f%/*}" 2>/dev/null || return 0
  if [ ! -s "$f" ] || [ -n "$(find "$f" -mmin +1440 2>/dev/null)" ]; then
    if curl -fsSL --compressed --max-time 120 -o "$f.part" "$CASK_URL" 2>/dev/null && [ -s "$f.part" ]; then
      mv -f "$f.part" "$f"
    else
      rm -f "$f.part"
    fi
  fi
  if [ -s "$f" ]; then printf '%s' "$f"; fi
}

catalog_lines() {  # catalog_lines cask.json → "App.app<TAB>token<TAB>version<TAB>homepage" per app
  local js
  has osascript || return 0
  mktmp; js=$MKTMP
  cat > "$js" <<'JXA'
ObjC.import('Foundation');
function catalogLines(d) {
  var out = [], i, j, k, c, art, app, name;
  if (!d || !d.length) return '';
  for (i = 0; i < d.length; i++) {
    c = d[i];
    if (!c || !c.token || !c.artifacts) continue;
    for (j = 0; j < c.artifacts.length; j++) {
      art = c.artifacts[j];
      app = art && art.app;
      if (!app || typeof app[0] !== 'string') continue;
      name = app[0];
      for (k = 1; k < app.length; k++) {
        if (app[k] && typeof app[k].target === 'string') name = app[k].target;
      }
      if (typeof art.target === 'string') name = art.target;
      name = name.split('/').pop();
      if (!/\.app$/.test(name)) continue;
      out.push([name, c.token, String(c.version), c.homepage || ''].join('\t'));
    }
  }
  return out.join('\n');
}
function run(argv) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  if (!s) return '';
  var d = JSON.parse(s.js);
  if (d && !Array.isArray(d) && typeof d.payload === 'string') d = JSON.parse(d.payload);
  return catalogLines(d);
}
JXA
  osascript -l JavaScript "$js" "$1" 2>/dev/null
}

cask_info_lines() {  # cask_info_lines token... → "token<TAB>auto(1|0)<TAB>App.app or /abs/App.app" per candidate app
  local js out
  has osascript || return 0
  mktmp; out=$MKTMP
  brew info --cask --json=v2 "$@" > "$out" 2>/dev/null || return 0
  mktmp; js=$MKTMP
  cat > "$js" <<'JXA'
ObjC.import('Foundation');
function run(argv) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  if (!s) return '';
  var d = JSON.parse(s.js), casks = (d && d.casks) || [], out = [], i, j, k, c, art, app, name, del, apps;
  for (i = 0; i < casks.length; i++) {
    c = casks[i]; apps = [];
    if (!c || !c.token) continue;
    for (j = 0; j < (c.artifacts || []).length; j++) {
      art = c.artifacts[j];
      app = art && art.app;
      if (app && typeof app[0] === 'string') {           // app artifact: name in the Applications folder
        name = app[0];
        for (k = 1; k < app.length; k++) {
          if (app[k] && typeof app[k].target === 'string') name = app[k].target;
        }
        apps.push(name.split('/').pop());
      }
      [].concat((art && art.uninstall) || []).forEach(function (u) {   // pkg casks: the .app they remove
        del = u && u.delete;
        [].concat(del || []).forEach(function (p) {
          if (typeof p === 'string' && /^\/.*\.app$/.test(p)) apps.push(p);
        });
      });
    }
    if (!apps.length) apps.push('');
    for (k = 0; k < apps.length; k++) out.push([c.token, c.auto_updates ? 1 : 0, apps[k]].join('\t'));
  }
  return out.join('\n');
}
JXA
  osascript -l JavaScript "$js" "$out" 2>/dev/null
}

cask_app() {  # cask_app token cask-info-file → path of the cask's installed app, or nothing
  local t a c d
  while IFS="$TAB" read -r t a c; do
    [ "$t" = "$1" ] && [ -n "$c" ] || continue
    case "$c" in
      /*) if [ -d "$c" ]; then printf '%s' "$c"; return; fi ;;
      *)  for d in /Applications "$H/Applications"; do
            if [ -d "$d/$c" ]; then printf '%s' "$d/$c"; return; fi
          done ;;
    esac
  done < "$2"
}

catalog_match() {  # catalog_match installed-casks lines "App.app" preferred-token → "BREW" or "token<TAB>version<TAB>homepage"
  awk -F'\t' -v n="$3" -v want="$4" '
    FNR == NR { inst[$1] = 1; next }
    $1 == n {
      if ($2 in inst) managed = 1
      score = (index($2, "@") ? 0 : 2) + ($2 == want ? 1 : 0)   # prefer the main cask over @beta/@esr variants
      if (!found || score > best) { best = score; line = $2 "\t" $3 "\t" $4; found = 1 }
    }
    END { if (managed) print "BREW"; else if (found) print line }' "$1" "$2"
}

brew_outdated() {  # → "kind<TAB>name<TAB>installed<TAB>latest<TAB>pinned" per outdated formula/cask
  local k
  for k in formula cask; do
    # casks: also those with auto_updates (the caller checks them against the installed app)
    brew outdated "--$k" --verbose $([ "$k" = cask ] && echo --greedy-auto-updates) 2>/dev/null | awk -v k="$k" '
      NF {
        name = $1; inst = ""; pinned = (index($0, "[pinned") > 0)
        if (match($0, /\([^)]*\)/)) inst = substr($0, RSTART + 1, RLENGTH - 2)
        line = $0; sub(/ *\[pinned.*$/, "", line)
        n = split(line, f, " "); latest = f[n]
        sub(/,.*/, "", inst); sub(/,.*/, "", latest)
        print k "\t" name "\t" inst "\t" latest "\t" pinned
      }'
  done
}

mas_outdated() {  # → "id<TAB>name<TAB>installed<TAB>latest" from `mas outdated`
  mas outdated 2>/dev/null | awk '
    $1 ~ /^[0-9]+$/ {
      id = $1; line = $0; sub(/^[ \t]*[0-9]+[ \t]+/, "", line); from = ""; to = ""
      if (match(line, /\([^()]*\)[ \t]*$/)) {
        v = substr(line, RSTART + 1); line = substr(line, 1, RSTART - 1)
        sub(/\)[ \t]*$/, "", v); split(v, p, / -> /); from = p[1]; to = p[2]
      }
      sub(/[ \t]+$/, "", line)
      print id "\t" line "\t" from "\t" to
    }'
}

sparkle_fetch() {  # sparkle_fetch feed-url out-file → version entries of the app's update feed
  curl -fsSL --max-time 8 "$1" 2>/dev/null | tr '\r\n' '  ' \
    | grep -oE 'sparkle:(shortVersionString|version)(="[^"]+"|>[^<]+)' > "$2"
}

up_add() {  # up_add kind name installed latest ref app-path homepage
  UP_KIND+=("$1"); UP_NAME+=("$2"); UP_FROM+=("$3"); UP_TO+=("$4")
  UP_REF+=("$5"); UP_PATH+=("${6:-}"); UP_HOME+=("${7:-}")
}

up_via() {
  case "$1" in
    formula) printf '%s' "Homebrew" ;;
    cask)    printf '%s' "Homebrew cask" ;;
    dmg)     if has brew; then L "Homebrew (ganti DMG)" "Homebrew (replaces DMG)"; else L "halaman download" "download page"; fi ;;
    sparkle) L "updater aplikasi" "app's own updater" ;;
    mas)     printf '%s' "App Store" ;;
  esac
}

replace_with_cask() {  # replace_with_cask app-path token name → old app to Trash, then brew installs the latest
  local app="$1" tok="$2" name="$3" bid
  bid=$(app_bundle_id "$app")
  if [ "$DRY_RUN" != 1 ] && app_running "$app"; then
    if [ "$ENGINE" = 1 ]; then emit error running "$name"; return 1; fi   # the app asks the user, then calls again
    warn "$name $(L "sedang berjalan." "is running.")"
    confirm "  $(L "Tutup $name sekarang?" "Quit $name now?")" || { cancelled; return 1; }
    if ! quit_app "$app" "$bid"; then
      err "$(L "$name belum tertutup — tutup manual, lalu ulangi." "$name is still running — quit it yourself, then try again.")"
      return 1
    fi
  fi
  info "$(L "Mengupdate $name lewat Homebrew ($tok)…" "Updating $name via Homebrew ($tok)…")"
  move_to_trash "$app" || return 1
  if run brew install --cask "$tok"; then
    ok "$(L "$name sudah versi terbaru — sekarang dikelola Homebrew." "$name is up to date — now managed by Homebrew.")"
  else
    err "$(L "Homebrew gagal memasang $tok. Versi lama ada di Trash — kembalikan lewat Finder › Put Back." \
             "Homebrew couldn't install $tok. The old version is in the Trash — restore it with Finder › Put Back.")"
    return 1
  fi
}

# updates_scan → UP_KIND UP_NAME UP_FROM UP_TO UP_REF UP_PATH UP_HOME (one entry per available update), and
# UPS_PINNED (pinned formulae skipped), UPS_AUTO_SKIP (self-updating casks it could not check, as names),
# UPS_MAS_N (App Store apps it could not check), UPS_HAS_BREW and UPS_OFFLINE (1 when Homebrew's catalog couldn't be read).
updates_scan() {
  local list casks lines cat outf sp app name ver row tok cv hp feed f i n kind latest pin cur short build cinfo ctoks
  UP_KIND=(); UP_NAME=(); UP_FROM=(); UP_TO=(); UP_REF=(); UP_PATH=(); UP_HOME=()
  UPS_PINNED=0; UPS_AUTO_SKIP=""; UPS_MAS_N=0; UPS_HAS_BREW=0; UPS_OFFLINE=0
  has brew && UPS_HAS_BREW=1
  mktmp; list=$MKTMP; list_apps > "$list"
  mktmp; casks=$MKTMP; echo "#" > "$casks"   # never empty, so the awk two-file trick works

  # 1) Homebrew formulae and casks
  if [ "$UPS_HAS_BREW" = 1 ]; then
    info "$(L "Memperbarui data Homebrew… (brew update, bisa 1–2 menit)" "Refreshing Homebrew… (brew update, may take 1–2 minutes)")"
    brew update >/dev/null 2>&1 || warn "$(L "brew update gagal — memakai data yang ada." "brew update failed — using the data it already has.")"
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1
    brew list --cask -1 2>/dev/null >> "$casks"
    mktmp; outf=$MKTMP; brew_outdated > "$outf"
    mktmp; cinfo=$MKTMP
    ctoks=$(awk -F'\t' '$1 == "cask" { print $2 }' "$outf")
    [ -n "$ctoks" ] && cask_info_lines $ctoks > "$cinfo"
    while IFS="$TAB" read -r kind name ver latest pin; do
      [ -n "$name" ] || continue
      if [ "$pin" = 1 ]; then UPS_PINNED=$((UPS_PINNED + 1)); continue; fi
      if [ "$kind" = cask ] && awk -F'\t' -v t="$name" '$1 == t && $2 == 1 { f = 1 } END { exit !f }' "$cinfo"; then
        # Self-updating cask: brew's installed version is often stale, so compare with the app itself
        app=$(cask_app "$name" "$cinfo"); cur=""
        [ -n "$app" ] && cur=$(app_version "$app")
        if [ -z "$cur" ]; then UPS_AUTO_SKIP="$UPS_AUTO_SKIP${UPS_AUTO_SKIP:+, }$name"; continue; fi
        ver_newer "$(ver_core "$latest")" "$(ver_core "$cur")" || continue
        ver="$cur"
      fi
      up_add "$kind" "$name" "$ver" "$latest" "$name"
    done < "$outf"
  else
    warn "$(L "Homebrew tidak ditemukan. Aplikasi DMG tetap dicek, tapi update-nya lewat halaman download." \
              "Homebrew not found. DMG apps are still checked, but you'll get their download page to update.")"
  fi

  # 2) Apps installed from a DMG/zip: compare with Homebrew's catalog, or their Sparkle feed
  info "$(L "Membandingkan aplikasi dengan katalog Homebrew…" "Comparing your apps with Homebrew's catalog…")"
  cat=$(cask_catalog)
  mktmp; lines=$MKTMP
  [ -n "$cat" ] && catalog_lines "$cat" > "$lines"
  if [ ! -s "$lines" ]; then
    UPS_OFFLINE=1
    warn "$(L "Katalog Homebrew tidak bisa dibaca (offline?) — hanya aplikasi dengan updater Sparkle yang dicek." \
              "Couldn't read Homebrew's catalog (offline?) — only apps with a Sparkle updater are checked.")"
  fi
  mktmp; sp=$MKTMP
  i=0; n=$(wc -l < "$list" | tr -d ' ')
  while IFS= read -r app <&3; do
    i=$((i + 1)); name="${app##*/}"; progress_step "$i" "$n" "${name%.app}"
    if [ -d "$app/Contents/_MASReceipt" ]; then UPS_MAS_N=$((UPS_MAS_N + 1)); continue; fi
    row=""
    [ -s "$lines" ] && row=$(catalog_match "$casks" "$lines" "$name" "$(lower "${name%.app}" | tr ' ' '-')")
    [ "$row" = BREW ] && continue            # installed with Homebrew: already covered above
    if [ -n "$row" ]; then
      IFS="$TAB" read -r tok cv hp <<< "$row"
      cv="${cv%%,*}"; ver=$(app_version "$app")
      if [ "$cv" != latest ] && ver_newer "$cv" "$ver"; then
        up_add dmg "${name%.app}" "$ver" "$cv" "$tok" "$app" "$hp"
      fi
      continue
    fi
    feed=$(plist_get "$app" SUFeedURL)
    case "$feed" in http*) mktmp; printf '%s\t%s\t%s\n' "$app" "$feed" "$MKTMP" >> "$sp" ;; esac
  done 3< "$list"
  progress_done

  if [ -s "$sp" ]; then
    info "$(L "Mengecek feed update Sparkle…" "Checking Sparkle update feeds…")"
    while IFS="$TAB" read -r app feed f; do sparkle_fetch "$feed" "$f" & done < "$sp"
    wait
    while IFS="$TAB" read -r app feed f; do
      name="${app##*/}"; name="${name%.app}"
      short=$(sed -n 's/^sparkle:shortVersionString[=">]*//p' "$f" | tr -d '"')
      if [ -n "$short" ]; then
        latest=$(newest_version $short); cur=$(plist_get "$app" CFBundleShortVersionString)
      else
        build=$(sed -n 's/^sparkle:version[=">]*//p' "$f" | tr -d '"')
        [ -n "$build" ] || continue
        latest=$(newest_version $build); cur=$(plist_get "$app" CFBundleVersion)
      fi
      if [ -n "$cur" ] && ver_newer "$latest" "$cur"; then up_add sparkle "$name" "$cur" "$latest" "" "$app"; fi
    done < "$sp"
  fi

  # 3) Mac App Store apps (via `mas` when installed)
  if [ "$UPS_MAS_N" -gt 0 ] && has mas; then
    mktmp; outf=$MKTMP; mas_outdated > "$outf"
    while IFS="$TAB" read -r tok name ver latest; do up_add mas "$name" "$ver" "$latest" "$tok"; done < "$outf"
    UPS_MAS_N=0
  fi
  return 0
}

# updates_run → do the updates picked in SEL (indexes into UP_*): brew upgrades, DMG apps replaced through Homebrew,
# Sparkle apps opened, mas upgrades. Returns 1 if any step failed. The menu ignores that; the engine turns it into the exit code.
updates_run() {
  local i rc=0 F_LIST C_LIST M_LIST
  if [ "$ENGINE" = 1 ]; then export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1; fi
  F_LIST=(); C_LIST=(); M_LIST=()
  for i in "${SEL[@]}"; do
    case "${UP_KIND[$i]}" in
      formula) F_LIST+=("${UP_REF[$i]}") ;;
      cask)    C_LIST+=("${UP_REF[$i]}") ;;
      mas)     M_LIST+=("${UP_REF[$i]}") ;;
    esac
  done
  if [ "${#F_LIST[@]}" -gt 0 ]; then run brew upgrade --formula "${F_LIST[@]}" || rc=1; fi
  if [ "${#C_LIST[@]}" -gt 0 ]; then run brew upgrade --cask "${C_LIST[@]}" || rc=1; fi
  for i in "${SEL[@]}"; do
    case "${UP_KIND[$i]}" in
      dmg)
        if [ "$UPS_HAS_BREW" = 1 ]; then replace_with_cask "${UP_PATH[$i]}" "${UP_REF[$i]}" "${UP_NAME[$i]}" || rc=1
        elif [ -n "${UP_HOME[$i]}" ]; then run open "${UP_HOME[$i]}" || rc=1
        fi ;;
      sparkle)
        run open "${UP_PATH[$i]}" || rc=1
        info "$(L "${UP_NAME[$i]} dibuka — kalau tidak muncul tawaran update, pilih menu aplikasi › Check for Updates…" \
                  "${UP_NAME[$i]} opened — if it doesn't offer the update, use the app menu › Check for Updates…")" ;;
    esac
  done
  if [ "${#M_LIST[@]}" -gt 0 ]; then run mas upgrade "${M_LIST[@]}" || rc=1; fi
  return $rc
}

update_menu() {
  local n i any_dmg=0 t_none
  updates_scan

  # Show the list
  n=${#UP_KIND[@]}
  echo
  if [ "$n" -eq 0 ]; then
    ok "$(L "Semua aplikasi yang bisa dicek sudah versi terbaru." "Every app that could be checked is up to date.")"
  else
    printf '  %s%3s  %-26s  %-14s  %-14s  %s%s\n' "$BOLD" "No" "$(L "Nama" "Name")" "$(L "Terpasang" "Installed")" \
      "$(L "Terbaru" "Latest")" "$(L "Update lewat" "Update via")" "$RST"
    i=0
    while [ "$i" -lt "$n" ]; do
      [ "${UP_KIND[$i]}" = dmg ] && any_dmg=1
      printf '  %3d  %-26.26s  %-14.14s  %s  %s\n' $((i + 1)) "${UP_NAME[$i]}" "${UP_FROM[$i]:-?}" \
        "${GRN}$(printf '%-14.14s' "${UP_TO[$i]}")${RST}" "$(up_via "${UP_KIND[$i]}")"
      i=$((i + 1))
    done
  fi
  echo
  [ "$UPS_PINNED" -gt 0 ] && say "  ${DIM}$(L "$UPS_PINNED formula di-pin dilewati (brew unpin <nama> untuk mengizinkan update)." \
                                        "$UPS_PINNED pinned formula(e) skipped (brew unpin <name> to allow updates).")${RST}"
  [ -n "$UPS_AUTO_SKIP" ] && say "  ${DIM}$(L "Tidak dicek (cask yang update sendiri, aplikasinya tidak ada di Applications): $UPS_AUTO_SKIP" \
                                         "Not checked (self-updating casks with no app in Applications): $UPS_AUTO_SKIP")${RST}"
  t_none=""
  if [ "$UPS_MAS_N" -gt 0 ]; then
    say "  $(L "$UPS_MAS_N aplikasi dari App Store — update-nya di App Store." "$UPS_MAS_N App Store app(s) — update them in the App Store.")" \
        "${DIM}$(L "(pasang 'mas' untuk cek dari sini)" "(install 'mas' to check them here)")${RST}"
    t_none="$(L ", s = buka App Store" ", s = open the App Store")"
  fi
  if [ "$n" -eq 0 ] && [ "$UPS_MAS_N" -eq 0 ]; then pause; return; fi
  if [ "$n" -gt 0 ]; then
    ask "  $(L "Pilih nomor, a = semua$t_none, Enter = kembali: " "Pick numbers, a = all$t_none, Enter = back: ")" || return
  else
    ask "  $(L "s = buka App Store, Enter = kembali: " "s = open the App Store, Enter = back: ")" || return
  fi
  case "$ANSWER" in
    "") return ;;
    s|S) if [ "$UPS_MAS_N" -gt 0 ]; then run open "macappstore://showUpdatesPage"; fi; pause; return ;;
    a|A) SEL=(); i=0; while [ "$i" -lt "$n" ]; do SEL+=("$i"); i=$((i + 1)); done ;;
    *)   parse_selection "$ANSWER" "$n" ;;
  esac
  if [ "${#SEL[@]}" -eq 0 ]; then info "$(L "Tidak ada yang dipilih." "Nothing selected.")"; pause; return; fi

  say "  $(L "Akan diupdate:" "Will update:")"
  any_dmg=0
  for i in "${SEL[@]}"; do
    say "    • ${UP_NAME[$i]}  ${UP_FROM[$i]:-?} → ${UP_TO[$i]}  ${DIM}· $(up_via "${UP_KIND[$i]}")${RST}"
    [ "${UP_KIND[$i]}" = dmg ] && any_dmg=1
  done
  if [ "$any_dmg" = 1 ] && [ "$UPS_HAS_BREW" = 1 ]; then
    warn "$(L "Aplikasi dari DMG diganti versi Homebrew: aplikasi lama dipindah ke Trash dulu, setting Anda tetap aman," \
              "DMG apps are replaced with Homebrew's version: the old app goes to the Trash first, your settings stay,")"
    say "  $(L "dan selanjutnya aplikasi itu ikut diupdate lewat menu ini." "and from then on it's updated from this menu.")"
  fi
  [ "$UPS_HAS_BREW" = 1 ] && say "  ${DIM}$(L "Homebrew mungkin meminta password untuk beberapa aplikasi." "Homebrew may ask for your password for some apps.")${RST}"
  confirm "  $(L "Lanjut?" "Continue?")" || { cancelled; pause; return; }

  updates_run
  echo; ok "$(L "Selesai." "Done.")"
  pause
}

# ═════════════════════════ 7. RAM ═════════════════════════
host_app() {  # the .app this script runs in (Terminal, iTerm, VS Code…), so it's never offered for quitting
  local pid=$$ i=0 c
  while [ "$i" -lt 20 ] && [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    c=$(ps -o comm= -p "$pid" 2>/dev/null)
    case "$c" in *.app/*) printf '%s' "${c%%.app/*}.app"; return 0 ;; esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    i=$((i + 1))
  done
}

mem_stats() {  # sets M_TOTAL M_APP M_WIRED M_COMP M_CACHED M_USED M_SWAP (KB) and M_LEVEL (1/2/4)
  local b
  b=$(sysctl -n hw.memsize 2>/dev/null); M_TOTAL=$(( ${b:-0} / 1024 ))
  read -r M_APP M_WIRED M_COMP M_CACHED <<< "$(vm_stat 2>/dev/null | awk '
    /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") ps = $(i + 1) }
    { v = $NF; gsub(/\./, "", v) }
    /^Anonymous pages/              { anon = v }
    /^Pages purgeable/              { purg = v }
    /^Pages wired down/             { wired = v }
    /^Pages occupied by compressor/ { comp = v }
    /^File-backed pages/            { file = v }
    END {
      k = (ps ? ps : 4096) / 1024; app = anon - purg; if (app < 0) app = 0
      printf "%d %d %d %d\n", app * k, wired * k, comp * k, (file + purg) * k
    }')"
  M_APP=${M_APP:-0}; M_WIRED=${M_WIRED:-0}; M_COMP=${M_COMP:-0}; M_CACHED=${M_CACHED:-0}
  M_USED=$((M_APP + M_WIRED + M_COMP))
  M_SWAP=$(sysctl -n vm.swapusage 2>/dev/null | awk '{
    for (i = 1; i < NF; i++) if ($i == "used") { v = $(i + 2); u = substr(v, length(v)); n = v + 0
      if (u == "G") n *= 1048576; else if (u == "M") n *= 1024; printf "%d", n; exit } }')
  M_SWAP=${M_SWAP:-0}
  M_LEVEL=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
}

mem_by_app() {  # → "KB<TAB>app<TAB>/path/Name.app" or "KB<TAB>proc<TAB>name", largest first
  ps -axo rss=,comm= 2>/dev/null | awk '
    {
      c = $0; if (c !~ /^ *[0-9]+ +./) next
      rss = c; sub(/^ */, "", rss); sub(/ .*/, "", rss)
      sub(/^ *[0-9]+ +/, "", c)
      i = index(c, ".app/")
      if (i) key = "app\t" substr(c, 1, i + 3)
      else {
        if (c ~ /^\/(System|usr\/libexec|usr\/sbin|sbin)\// && c !~ /Virtualization\.VirtualMachine/) next   # parts of macOS
        n = c; sub(/.*\//, "", n); key = "proc\t" n
      }
      sum[key] += rss
    }
    END { for (k in sum) printf "%d\t%s\n", sum[k], k }' | sort -t"$TAB" -k1,1nr
}

show_mem() {
  local pct=0 lvl
  mem_stats
  [ "$M_TOTAL" -gt 0 ] && pct=$(( M_USED * 100 / M_TOTAL ))
  case "$M_LEVEL" in
    1) lvl="${GRN}$(L "normal" "normal")${RST}" ;;
    2) lvl="${YEL}$(L "peringatan" "warning")${RST}" ;;
    4) lvl="${RED}$(L "kritis" "critical")${RST}" ;;
    *) lvl="${DIM}?${RST}" ;;
  esac
  say "  RAM: ${BOLD}$(hsize "$M_USED")${RST} $(L "terpakai dari" "used of") $(hsize "$M_TOTAL") (${pct}%)  ·  Memory pressure: $lvl"
  say "  ${DIM}$(L "Aplikasi" "Apps") $(hsize "$M_APP") · Wired $(hsize "$M_WIRED") · $(L "Terkompresi" "Compressed") $(hsize "$M_COMP") · $(L "Cache file" "Cached files") $(hsize "$M_CACHED") · Swap $(hsize "$M_SWAP")${RST}"
}

tab_fields() {  # tab_fields line → TF=(fields); keeps empty fields, which `read` would collapse
  local rest=$1
  TF=()
  while :; do
    case "$rest" in
      *"$TAB"*) TF+=("${rest%%"$TAB"*}"); rest=${rest#*"$TAB"} ;;
      *) TF+=("$rest"); break ;;
    esac
  done
}

ram_rows() {  # ram_rows host outfile → "memapp<TAB>kb<TAB>path<TAB>name<TAB>note<TAB>host" and "memproc<TAB>kb<TAB>path<TAB>note" lines
  local host=$1 out=$2 src n=0 shown_p=0 kb kind path name note h
  mktmp; src=$MKTMP; mem_by_app > "$src"
  : > "$out"
  while IFS="$TAB" read -r kb kind path; do
    [ "$kind" = app ] || continue
    case "$path" in /System/Library/*) continue ;; esac   # Finder, Dock and other parts of macOS
    [ "$n" -ge 12 ] && break
    name="${path##*/}"; name="${name%.app}"; note=""; h=0
    if [ -n "$host" ] && [ "$path" = "$host" ]; then h=1   # not counted, so it's never offered for quitting
    else
      case "$name" in Docker|OrbStack) note="$(L "menghentikan container" "stops containers")" ;; esac
      n=$((n + 1))
    fi
    printf 'memapp\t%s\t%s\t%s\t%s\t%s\n' "$kb" "$path" "$name" "$note" "$h" >> "$out"
  done < "$src"
  while IFS="$TAB" read -r kb kind path; do
    [ "$kind" = proc ] || continue
    [ "$shown_p" -ge 5 ] && break
    [ "$kb" -ge 102400 ] || break   # only those using 100 MB or more
    note=""
    case "$path" in *Virtualization.VirtualMachine*) note="$(L "VM: Docker/OrbStack/UTM — lihat menu 2" "VM: Docker/OrbStack/UTM — see menu 2")" ;; esac
    printf 'memproc\t%s\t%s\t%s\n' "$kb" "$path" "$note" >> "$out"
    shown_p=$((shown_p + 1))
  done < "$src"
}

ram_menu() {
  local out host n i kb path name note line before_used before_cached shown_p
  host=$(host_app)
  while true; do
    echo; show_mem
    say "  ${DIM}$(L "macOS sengaja memakai RAM kosong sebagai cache — yang penting memory pressure." \
                     "macOS uses free RAM as cache on purpose — what matters is memory pressure.")${RST}"
    say "  ${DIM}$(L "Kalau kuning atau merah, tutup aplikasi yang paling berat." "If it's yellow or red, quit the heaviest apps.")${RST}"
    mktmp; out=$MKTMP; ram_rows "$host" "$out"
    R_PATH=(); R_NAME=(); n=0; shown_p=0
    echo
    printf '  %s%3s  %9s  %s%s\n' "$BOLD" "No" "$(L "Memori" "Memory")" "$(L "Aplikasi" "App")" "$RST"
    while IFS= read -r line; do
      tab_fields "$line"
      [ "${TF[0]}" = memapp ] || continue
      kb=${TF[1]}; path=${TF[2]}; name=${TF[3]}; note=${TF[4]}
      if [ "${TF[5]}" = 1 ]; then
        printf '  %3s  %9s  %s %s\n' "" "$(hsize "$kb")" "$name" "${DIM}($(L "terminal ini" "this terminal"))${RST}"
        continue
      fi
      [ -n "$note" ] && note=" ${DIM}(${note})${RST}"
      n=$((n + 1)); R_PATH+=("$path"); R_NAME+=("$name")
      printf '  %3d  %9s  %s%s\n' "$n" "$(hsize "$kb")" "$name" "$note"
    done < "$out"
    echo
    say "  ${DIM}$(L "Proses lain (hentikan dari tempat Anda menjalankannya):" "Other processes (stop them where you started them):")${RST}"
    while IFS= read -r line; do
      tab_fields "$line"
      [ "${TF[0]}" = memproc ] || continue
      kb=${TF[1]}; path=${TF[2]}; note=${TF[3]}
      [ -n "$note" ] && note=" (${note})"
      printf '  %3s  %9s  %s\n' "" "$(hsize "$kb")" "${DIM}${path}${note}${RST}"
      shown_p=$((shown_p + 1))
    done < "$out"
    [ "$shown_p" -gt 0 ] || say "  ${DIM}  —${RST}"
    echo
    ask "  $(L "Tutup aplikasi (mis. 1 3), p = kosongkan cache file (sudo purge), Enter = kembali: " \
               "Quit apps (e.g. 1 3), p = clear cached files (sudo purge), Enter = back: ")" || return
    case "$ANSWER" in
      "") return ;;
      p|P)
        if ! has purge; then err "$(L "Perintah purge tidak ditemukan." "purge command not found.")"; continue; fi
        say "  $(L "purge mengosongkan cache file di RAM. macOS akan mengisinya lagi saat Anda bekerja," \
                   "purge empties the file cache in RAM. macOS fills it again as you work,")"
        say "  $(L "jadi efeknya sementara dan aplikasi bisa terasa lebih lambat sebentar." \
                   "so the effect is temporary and apps may feel slower for a moment.")"
        confirm "  $(L "Jalankan sudo purge? (macOS meminta password Anda)" "Run sudo purge? (macOS will ask for your password)")" || { cancelled; continue; }
        before_used=$M_USED; before_cached=$M_CACHED
        if run sudo purge; then
          [ "$DRY_RUN" = 1 ] || { mem_stats; ok "$(L "Cache file: $(hsize "$before_cached") → $(hsize "$M_CACHED")" "Cached files: $(hsize "$before_cached") → $(hsize "$M_CACHED")")"; }
        fi
        continue ;;
      *) parse_selection "$ANSWER" "$n" ;;
    esac
    [ "${#SEL[@]}" -gt 0 ] || continue
    say "  $(L "Akan ditutup:" "Will quit:")"
    for i in "${SEL[@]}"; do say "    • ${R_NAME[$i]}"; done
    say "  ${DIM}$(L "Aplikasi ditutup secara normal — kalau ada pekerjaan yang belum disimpan, aplikasinya akan bertanya dulu." \
                     "Apps quit normally — if there's unsaved work, the app asks you first.")${RST}"
    confirm "  $(L "Lanjut?" "Continue?")" || { cancelled; continue; }
    before_used=$M_USED
    for i in "${SEL[@]}"; do
      if [ "$DRY_RUN" = 1 ]; then say "  ${DIM}[dry-run]${RST} $(L "tutup" "quit") ${R_NAME[$i]}"; continue; fi
      if quit_app "${R_PATH[$i]}" "$(app_bundle_id "${R_PATH[$i]}")"; then
        ok "${R_NAME[$i]} $(L "ditutup." "quit.")"
      else
        warn "$(L "${R_NAME[$i]} masih berjalan (mungkin menunggu Anda menyimpan). Paksa tutup dengan ⌥⌘⎋ kalau perlu." \
                  "${R_NAME[$i]} is still running (maybe waiting for you to save). Force quit with ⌥⌘⎋ if needed.")"
      fi
    done
    if [ "$DRY_RUN" != 1 ]; then
      sleep 2; mem_stats
      ok "$(L "RAM terpakai: $(hsize "$before_used") → $(hsize "$M_USED")" "RAM used: $(hsize "$before_used") → $(hsize "$M_USED")")"
    fi
  done
}

# ═════════════════════════ ENGINE MODE (used by the Mac app) ═════════════════════════
# Hidden: bash mac-cleaner.command [--lang id|en] [--dry-run] --engine <command> [args…]
# Prints one record per line ("@@type<TAB>field<TAB>…", see emit) and never reads input.
# Exit codes: 0 ok, 1 failed or needs interaction, 2 bad usage.

read_list() {  # read_list file → LIST=(non-blank lines)
  local line
  LIST=()
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *[![:space:]]*) LIST+=("$line") ;; esac
  done < "$1"
}

uniq_list() {  # uniq_list → LIST without repeated lines (the first of each stays)
  local line seen=$'\n' keep=()
  for line in "${LIST[@]}"; do
    case "$seen" in *$'\n'"$line"$'\n'*) continue ;; esac
    seen="$seen$line"$'\n'; keep+=("$line")
  done
  LIST=("${keep[@]}")
}

# valid_token <s> → success for a Homebrew formula/cask reference: "name" or "user/tap/name" (1 or 3 segments split by "/").
# Each segment is non-empty, only letters, digits and @ . _ + - (spelled out, not as ranges: ranges follow the locale and can
# match é and the like), does not start with "-" (brew would read an option) and is not "." or "..". The whole ref must not end
# in .rb or .json: brew loads such a ref as a local formula/cask file, which is Ruby code.
valid_token() {
  local slashes=${1//[!\/]/} rest seg1 seg2 seg3
  case "$1" in *.[rR][bB]|*.[jJ][sS][oO][nN]) return 1 ;; esac
  case ${#slashes} in
    0) token_segment_ok "$1" ;;
    2) seg1=${1%%/*}; rest=${1#*/}; seg2=${rest%%/*}; seg3=${rest#*/}
       token_segment_ok "$seg1" && token_segment_ok "$seg2" && token_segment_ok "$seg3" ;;
    *) return 1 ;;
  esac
}
token_segment_ok() {
  case "$1" in ""|.|..|-*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._+-]*) return 1 ;; esac
  return 0
}

updates_row_ok() {  # updates_row_ok kind ref app homepage applist → success when an updates-apply row may run
  local kind=$1 ref=$2 app=$3 home=$4
  case "$kind" in
    formula|cask|dmg) valid_token "$ref" || return 1 ;;
    mas)              case "$ref" in ""|*[!0123456789]*) return 1 ;; esac ;;
    sparkle)          [ -z "$ref" ] || valid_token "$ref" || return 1 ;;
    *)                return 1 ;;
  esac
  case "$kind" in                                   # an app must be a line of list_apps; dmg and sparkle need one
    dmg|sparkle) is_listed_app "$app" "$5" || return 1 ;;
    *)           [ -z "$app" ] || is_listed_app "$app" "$5" || return 1 ;;
  esac
  case "$home" in
    "") ;;
    http://?*|https://?*) case "$home" in *[[:space:][:cntrl:]]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  return 0
}

docker_require_running() {  # engine: 0 when the Docker daemon answers, otherwise emit the error record and return 1
  case "$(docker_state)" in
    running) return 0 ;;
    missing) emit error docker_missing "$(L "Perintah docker tidak ditemukan." "docker command not found.")" ;;
    *) emit error docker_not_ready "$(L "Docker belum siap." "Docker is not ready.")" ;;
  esac
  return 1
}

# docker-start: starts OrbStack (or Docker Desktop), then polls `docker info` until the daemon answers.
# The daemon is started with its stdio detached: one that kept the app's pipes would hold the job open, or die of SIGPIPE later.
# MAC_CLEANER_DOCKER_WAIT = seconds to wait (default 60), MAC_CLEANER_DOCKER_POLL = seconds between checks (default 2); tests shorten both.
docker_start() {
  local dk_wait=${MAC_CLEANER_DOCKER_WAIT:-60} dk_poll=${MAC_CLEANER_DOCKER_POLL:-2} t0
  case "$dk_wait" in ""|*[!0-9]*) dk_wait=60 ;; esac
  case "$dk_poll" in ""|*[!0-9.]*|*.*.*) dk_poll=2 ;; esac
  if ! has docker; then emit error docker_missing "$(L "Perintah docker tidak ditemukan." "docker command not found.")"; return 1; fi
  if docker info >/dev/null 2>&1; then emit meta state running; return 0; fi
  if has orb; then
    progress "$(L "Menjalankan OrbStack…" "Starting OrbStack…")"
    orb start </dev/null >/dev/null 2>&1 || { emit error docker_not_ready "$(L "OrbStack gagal dijalankan." "OrbStack failed to start.")"; return 1; }
  elif docker_app_present; then
    progress "$(L "Membuka Docker Desktop…" "Opening Docker Desktop…")"
    open -a Docker </dev/null >/dev/null 2>&1 || { emit error docker_not_ready "$(L "Docker Desktop gagal dibuka." "Docker Desktop failed to open.")"; return 1; }
  else
    emit error docker_not_ready "$(L "Docker belum berjalan dan tidak ada OrbStack atau Docker Desktop untuk dijalankan." \
                                     "Docker is not running and there is no OrbStack or Docker Desktop to start.")"
    return 1
  fi
  t0=$SECONDS
  until docker info >/dev/null 2>&1; do
    if [ $((SECONDS - t0)) -ge "$dk_wait" ]; then emit error docker_not_ready "$(L "Docker belum siap." "Docker is not ready.")"; return 1; fi
    progress_step $((SECONDS - t0)) "$dk_wait" "$(L "Menunggu Docker siap…" "Waiting for Docker to be ready…")"
    sleep "$dk_poll"
  done
  emit meta state running
}

engine_dispatch() {
  local cmd="${ENGINE_ARGS[0]:-}"
  [ -x "$SCRIPT_DIR/askpass.sh" ] && export SUDO_ASKPASS="$SCRIPT_DIR/askpass.sh"
  if [ -z "$cmd" ]; then emit error bad_args "missing command"; return 2; fi
  case "$cmd" in
    env)
      emit meta version "$VERSION"
      emit meta lang "$UI_LANG"
      emit meta dry_run "$DRY_RUN"
      local t f
      for t in brew docker orb mas; do
        if has "$t"; then f=1; else f=0; fi
        emit meta "has_$t" "$f"
      done
      if has_fda; then f=1; else f=0; fi
      emit meta has_fda "$f" ;;
    disk)
      emit_disk ;;
    caches-scan)
      cache_scan
      local i=0
      while [ "$i" -lt "${#L_ID[@]}" ]; do
        emit row cache "${L_ID[$i]}" "${L_KB[$i]}" "${L_KIND[$i]}" "${L_LABEL[$i]}"
        i=$((i + 1))
      done
      emit meta total_safe "$T_SAFE"
      emit meta total_heavy "$T_HEAVY" ;;
    caches-clean)
      local a w ok_id
      if [ "${#ENGINE_ARGS[@]}" -lt 2 ]; then emit error bad_args "caches-clean needs at least one id"; return 2; fi
      for a in "${ENGINE_ARGS[@]:1}"; do   # exact match against the known ids, before anything runs
        ok_id=0; for w in $CACHE_IDS; do [ "$a" = "$w" ] && ok_id=1; done
        if [ "$ok_id" = 0 ]; then emit error bad_args "unknown cache id: $a"; return 2; fi
      done
      init_paths
      cache_run "${ENGINE_ARGS[@]:1}"
      [ "$FINDER_DENIED" = 0 ] || return 1 ;;
    bigdata-scan)
      local bd kb path
      mktmp; bd=$MKTMP
      bigdata_scan "$bd"
      emit meta fda "$BD_FDA"
      while IFS="$TAB" read -r kb path; do
        [ -n "$path" ] && emit row dir "$kb" "$path"
      done < "$bd" ;;
    ram-scan)
      local rr line
      mem_stats
      emit meta total "$M_TOTAL"; emit meta app "$M_APP"; emit meta wired "$M_WIRED"; emit meta comp "$M_COMP"
      emit meta cached "$M_CACHED"; emit meta used "$M_USED"; emit meta swap "$M_SWAP"; emit meta level "${M_LEVEL:-0}"
      mktmp; rr=$MKTMP
      ram_rows "$(host_app)" "$rr"
      while IFS= read -r line; do
        tab_fields "$line"
        emit row "${TF[@]}"
      done < "$rr" ;;
    ram-purge)
      local before pe
      mem_stats; before=$M_CACHED
      emit meta cached_before "$before"
      if [ "$DRY_RUN" = 1 ]; then
        run osascript -e 'do shell script "/usr/sbin/purge" with administrator privileges'
      elif ! pe=$(osascript -e 'do shell script "/usr/sbin/purge" with administrator privileges' 2>&1 >/dev/null); then
        case "$pe" in
          *-128*) emit error cancelled "$(L "Dibatalkan." "Cancelled.")"; return 1 ;;
          *) err "$(L "purge gagal: " "purge failed: ")$pe"; return 1 ;;
        esac
      fi
      mem_stats
      emit meta cached_after "$M_CACHED"
      [ "$DRY_RUN" = 1 ] || ok "$(L "Cache file: $(hsize "$before") → $(hsize "$M_CACHED")" "Cached files: $(hsize "$before") → $(hsize "$M_CACHED")")" ;;
    apps-scan)
      local days="${ENGINE_ARGS[1]:-}" ap_sorted ap_shown ap_line ap_n
      case "$days" in ""|*[!0-9]*) emit error bad_args "apps-scan needs a number of days"; return 2 ;; esac
      if [ "${#days}" -gt 6 ] || [ "${#ENGINE_ARGS[@]}" -ne 2 ]; then emit error bad_args "apps-scan takes one number of days (up to 6 digits)"; return 2; fi
      mktmp; ap_sorted=$MKTMP; mktmp; ap_shown=$MKTMP
      RARE_N=0; RARE_KB=0; ap_n=0
      if apps_scan "$ap_sorted"; then
        ap_n=$(wc -l < "$ap_sorted" | tr -d ' ')
        apps_select $((10#$days)) "$ap_sorted" > "$ap_shown"
        while IFS= read -r ap_line; do
          tab_fields "$ap_line"
          emit row app "${TF[@]}"
        done < "$ap_shown"
      fi
      emit meta total "$ap_n"; emit meta rare_n "$RARE_N"; emit meta rare_kb "$RARE_KB" ;;
    apps-list)
      local al_list al_name al_path
      mktmp; al_list=$MKTMP; list_apps > "$al_list"
      awk '{ n = $0; sub(/.*\//, "", n); sub(/\.app$/, "", n); print n "\t" $0 }' "$al_list" | sort -f -t "$TAB" -k1,1 \
        | while IFS="$TAB" read -r al_name al_path; do emit row appname "$al_name" "$al_path"; done ;;
    uninstall-plan)
      local up_app="${ENGINE_ARGS[1]:-}" up_list up_i up_p
      if [ -z "$up_app" ] || [ "${#ENGINE_ARGS[@]}" -ne 2 ]; then emit error bad_args "uninstall-plan needs one app path"; return 2; fi
      mktmp; up_list=$MKTMP; list_apps > "$up_list"
      if ! is_listed_app "$up_app" "$up_list"; then emit error not_allowed "$up_app"; return 2; fi
      load_app_ids "$up_list"
      uninstall_plan "$up_app"
      emit meta name "$UN_NAME"; emit meta bundle_id "$UN_BID"; emit meta app_kb "$UN_APP_KB"
      emit meta dup "$UN_DUP"; emit meta vendor_hint "$UN_VENDOR"
      up_i=0
      while [ "$up_i" -lt "${#U_PATH[@]}" ]; do   # only what `uninstall` would accept
        leftover_allowed "${U_PATH[$up_i]}" && emit row leftover "${U_KB[$up_i]}" "${U_PATH[$up_i]}"
        up_i=$((up_i + 1))
      done
      while IFS= read -r up_p; do [ -z "$up_p" ] || emit row admin "$up_p"; done < "$U_ADMIN" ;;
    uninstall)
      # Nothing moves until the app and every listed path are validated: the app must be a line of list_apps, each
      # leftover must exist, pass safe_path, sit directly inside one of USER_LEFTOVER_DIRS (parent spelled exactly, so a
      # differently-cased parent is refused), not be one of those folders (compared with -ef), and not be a symlink.
      # Duplicates (also by -ef) are moved once. Then running check, then the Trash.
      local un_app="${ENGINE_ARGS[1]:-}" un_file="${ENGINE_ARGS[3]:-}" un_list un_p un_q un_seen un_keep=()
      if [ "${#ENGINE_ARGS[@]}" -ne 4 ] || [ -z "$un_app" ] || [ "${ENGINE_ARGS[2]}" != --list ] || [ ! -f "$un_file" ] || [ ! -r "$un_file" ]; then
        emit error bad_args "usage: uninstall <app> --list <file>"; return 2
      fi
      mktmp; un_list=$MKTMP; list_apps > "$un_list"
      if ! is_listed_app "$un_app" "$un_list"; then emit error not_allowed "$un_app"; return 2; fi
      read_list "$un_file"
      for un_p in "${LIST[@]}"; do
        if [ "$un_p" = "$un_app" ] || [ "$un_p" -ef "$un_app" ] || ! leftover_allowed "$un_p"; then emit error not_allowed "$un_p"; return 2; fi
        un_seen=0   # the same item spelled twice (APFS ignores case) is moved once
        for un_q in "${un_keep[@]}"; do [ "$un_q" = "$un_p" ] || [ "$un_q" -ef "$un_p" ] && un_seen=1; done
        [ "$un_seen" = 1 ] || un_keep+=("$un_p")
      done
      uninstall_run "$un_app" "${un_keep[@]}" || return 1 ;;
    docker-status)
      local ds_st ds_eng=Docker ds_out ds_line
      ds_st=$(docker_state)
      emit meta state "$ds_st"
      [ "$ds_st" = missing ] && return 0
      has orb && ds_eng=OrbStack
      emit meta engine "$ds_eng"
      if [ "$ds_st" = running ]; then   # counts and sizes only exist while the daemon answers
        dk_counts
        emit meta containers "$DK_NC"; emit meta running "$DK_NR"; emit meta images "$DK_NI"; emit meta volumes "$DK_NV"
        mktmp; ds_out=$MKTMP
        docker system df --format '{{.Type}}\t{{.TotalCount}}\t{{.Active}}\t{{.Size}}\t{{.Reclaimable}}' 2>/dev/null > "$ds_out"
        while IFS= read -r ds_line; do
          [ -n "$ds_line" ] || continue
          tab_fields "$ds_line"
          emit row df "${TF[@]}"
        done < "$ds_out"
      fi ;;
    docker-start)
      if [ "${#ENGINE_ARGS[@]}" -ne 1 ]; then emit error bad_args "docker-start takes no arguments"; return 2; fi
      docker_start || return 1 ;;
    docker-list)
      local dl_type="${ENGINE_ARGS[1]:-}" dl_out dl_line
      case "$dl_type" in containers|images|volumes) ;; *) emit error bad_args "usage: docker-list <containers|images|volumes>"; return 2 ;; esac
      if [ "${#ENGINE_ARGS[@]}" -ne 2 ]; then emit error bad_args "usage: docker-list <containers|images|volumes>"; return 2; fi
      docker_require_running || return 1
      mktmp; dl_out=$MKTMP
      case "$dl_type" in
        containers) dk_containers_scan "$dl_out" ;;
        images)     dk_images_scan "$dl_out" ;;
        volumes)    dk_volumes_scan "$dl_out" ;;
      esac
      while IFS= read -r dl_line; do
        [ -n "$dl_line" ] || continue
        tab_fields "$dl_line"
        case "$dl_type" in
          containers) TF[2]=${TF[2]%% *}; emit row container "${TF[@]}" ;;   # "5B (virtual 187MB)" → "5B", as the menu shows it
          images)     emit row image "${TF[@]}" ;;
          volumes)    emit row volume "${TF[@]}" ;;
        esac
      done < "$dl_out" ;;
    docker-rm)
      # Everything is checked before anything runs: type, "--list <file>", and no line that could be read as a docker option.
      # Lines go to docker as single arguments (no splitting, no globbing). Repeated lines count once. Containers must be a listed
      # id or name, and in-use images and volumes are skipped, both re-checked live.
      local dr_type="${ENGINE_ARGS[1]:-}" dr_file="${ENGINE_ARGS[3]:-}" dr_p
      case "$dr_type" in containers|images|volumes) ;; *) emit error bad_args "usage: docker-rm <containers|images|volumes> --list <file>"; return 2 ;; esac
      if [ "${#ENGINE_ARGS[@]}" -ne 4 ] || [ "${ENGINE_ARGS[2]}" != --list ] || [ ! -f "$dr_file" ] || [ ! -r "$dr_file" ]; then
        emit error bad_args "usage: docker-rm <containers|images|volumes> --list <file>"; return 2
      fi
      read_list "$dr_file"; uniq_list
      for dr_p in "${LIST[@]}"; do
        case "$dr_p" in -*) emit error not_allowed "$dr_p"; return 2 ;; esac
      done
      docker_require_running || return 1
      [ "${#LIST[@]}" -gt 0 ] || return 0
      case "$dr_type" in
        containers) dkr_containers "${LIST[@]}" || return 1 ;;
        images)     dkr_images "${LIST[@]}" || return 1 ;;
        volumes)    dkr_volumes "${LIST[@]}" || return 1 ;;
      esac ;;
    docker-prune)
      local dp_act="${ENGINE_ARGS[1]:-}"
      case "$dp_act" in
        images-unused|images-dangling|build-all|build-old|networks|safe|all-unused|wipe|orb-reset) ;;
        *) emit error bad_args "usage: docker-prune <images-unused|images-dangling|build-all|build-old|networks|safe|all-unused|wipe|orb-reset>"; return 2 ;;
      esac
      if [ "${#ENGINE_ARGS[@]}" -ne 2 ]; then emit error bad_args "docker-prune takes one action"; return 2; fi
      docker_require_running || return 1
      case "$dp_act" in
        images-unused)   dkp_images_unused || return 1 ;;
        images-dangling) dkp_images_dangling || return 1 ;;
        build-all)       dkp_build_all || return 1 ;;
        build-old)       dkp_build_old || return 1 ;;
        networks)        dkp_networks || return 1 ;;
        safe)            dkp_safe || return 1 ;;
        all-unused)      dkp_all_unused || return 1 ;;
        wipe)            dkp_wipe || return 1 ;;
        orb-reset)
          if ! has orb; then emit error docker_missing "$(L "OrbStack tidak ditemukan." "OrbStack not found.")"; return 1; fi
          dkp_orb_reset || return 1 ;;
      esac ;;
    updates-scan)
      local us_i=0
      if [ "${#ENGINE_ARGS[@]}" -ne 1 ]; then emit error bad_args "updates-scan takes no arguments"; return 2; fi
      updates_scan
      while [ "$us_i" -lt "${#UP_KIND[@]}" ]; do
        emit row update "${UP_KIND[$us_i]}" "${UP_NAME[$us_i]}" "${UP_FROM[$us_i]}" "${UP_TO[$us_i]}" "$(up_via "${UP_KIND[$us_i]}")" \
          "${UP_REF[$us_i]}" "${UP_PATH[$us_i]}" "${UP_HOME[$us_i]}"
        us_i=$((us_i + 1))
      done
      emit meta has_brew "$UPS_HAS_BREW"; emit meta pinned "$UPS_PINNED"; emit meta auto_skip "$UPS_AUTO_SKIP"
      emit meta mas_n "$UPS_MAS_N"; emit meta offline "$UPS_OFFLINE"
      if has mas; then emit meta has_mas 1; else emit meta has_mas 0; fi ;;
    updates-apply)
      # Every row is validated before anything runs (kind, brew token or digits-only mas id, app = a line of list_apps,
      # homepage empty or http(s)); the first bad one stops everything: bad_args for the wrong shape, not_allowed otherwise.
      # Repeated rows run once. Then updates_run, which exits 1 if a step failed (e.g. emit error running for an open app).
      local ua_file="${ENGINE_ARGS[2]:-}" ua_apps ua_line
      if [ "${#ENGINE_ARGS[@]}" -ne 3 ] || [ "${ENGINE_ARGS[1]}" != --list ] || [ ! -f "$ua_file" ] || [ ! -r "$ua_file" ]; then
        emit error bad_args "usage: updates-apply --list <file>"; return 2
      fi
      mktmp; ua_apps=$MKTMP; list_apps > "$ua_apps"
      read_list "$ua_file"; uniq_list
      UP_KIND=(); UP_NAME=(); UP_FROM=(); UP_TO=(); UP_REF=(); UP_PATH=(); UP_HOME=(); SEL=()
      for ua_line in "${LIST[@]}"; do
        tab_fields "$ua_line"
        if [ "${#TF[@]}" -ne 7 ]; then emit error bad_args "expected kind, name, from, to, ref, app, homepage: $ua_line"; return 2; fi
        if ! updates_row_ok "${TF[0]}" "${TF[4]}" "${TF[5]}" "${TF[6]}" "$ua_apps"; then emit error not_allowed "$ua_line"; return 2; fi
        SEL+=("${#UP_KIND[@]}")
        up_add "${TF[0]}" "${TF[1]}" "${TF[2]}" "${TF[3]}" "${TF[4]}" "${TF[5]}" "${TF[6]}"
      done
      UPS_HAS_BREW=0; has brew && UPS_HAS_BREW=1
      updates_run || return 1 ;;
    set-lang)
      case "${ENGINE_ARGS[1]:-}" in
        id|en) UI_LANG="${ENGINE_ARGS[1]}"; save_lang ;;
        *) emit error bad_args "set-lang needs id or en"; return 2 ;;
      esac ;;
    _probe-confirm)
      confirm "probe" ;;
    *)
      emit error unknown_command "$cmd"; return 2 ;;
  esac
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
    say "  6) $(L "Update aplikasi (Homebrew, DMG, App Store)" "Update apps (Homebrew, DMG, App Store)")"
    say "  7) $(L "RAM: cek pemakaian & tutup aplikasi yang berat" "RAM: check usage & quit heavy apps")"
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
      6) update_menu ;;
      7) ram_menu ;;
      l|L) if [ "$UI_LANG" = id ]; then UI_LANG=en; else UI_LANG=id; fi
           save_lang
           ok "$(L "Bahasa diganti ke Indonesia." "Language switched to English.")" ;;
      q|Q) break ;;
    esac
  done
  echo; say "  $(L "Selesai." "Bye.")"
}

if [ "$ENGINE" = 1 ]; then engine_dispatch; exit $?; else main; fi
