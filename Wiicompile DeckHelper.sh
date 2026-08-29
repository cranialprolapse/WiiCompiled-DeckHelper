#!/usr/bin/env bash
DECKHELPER_VERSION="1.0.0"
DECKHELPER_MAINTAINER="cranialprolapse"
set -Eeuo pipefail

APPIMAGE_URL="https://github.com/theofficialgman/testing/releases/download/gmans-releases/WiiCompiled-Setup-x86_64.AppImage"
RETRO_URL="https://cdn.update.rwfc.net/RetroRewind/zip/6.12.4-full2.zip"

STATE_DIR="${HOME}/.config/wiicompile-deckhelper"
GAME_STATE="${STATE_DIR}/game_path"
VERIFIED_GAME_STATE="${STATE_DIR}/verified_game_path"
GAME_SHA256_STATE="${STATE_DIR}/verified_game_sha256"
GAME_SHA1_STATE="${STATE_DIR}/measured_game_sha1"
GAME_SIZE_STATE="${STATE_DIR}/measured_game_size"
GAME_ID_STATE="${STATE_DIR}/measured_game_id"
GAME_FINGERPRINT_PATH_STATE="${STATE_DIR}/measured_game_path"
GAME_MTIME_STATE="${STATE_DIR}/verified_game_mtime"
GAME_INODE_STATE="${STATE_DIR}/verified_game_inode"
PROGRESS_STATE="${STATE_DIR}/progress_state"
ACTION_LOCK="${STATE_DIR}/action.lock"
VIEW_CONSOLE_STATE="${STATE_DIR}/view_console"
ACTIVE_BUILD_STATE="${STATE_DIR}/active_build_state"
ACTIVE_BASE_PREEXIST_STATE="${STATE_DIR}/active_base_preexisting"
ACTIVE_RETRO_PREEXIST_STATE="${STATE_DIR}/active_retro_preexisting"
ACTIVE_TOPLEVEL_PREEXIST_STATE="${STATE_DIR}/active_wii_toplevel_preexisting"
ACTIVE_REQUESTED_ACTION_STATE="${STATE_DIR}/active_requested_action"
RESUME_STATE="${STATE_DIR}/resume_installation"
SGDB_KEY_STATE="${STATE_DIR}/steamgriddb_api_key"
SGDB_AUTO_STATE="${STATE_DIR}/steamgriddb_auto_art"
BASE_APPID_STATE="${STATE_DIR}/base_steam_appid"
RETRO_APPID_STATE="${STATE_DIR}/retro_steam_appid"
MII_SOURCE_STATE="${STATE_DIR}/mii_source"
SAVE_SOURCE_STATE="${STATE_DIR}/retro_save_source"
STEAM_TOGGLE_STATE="${STATE_DIR}/add_steam_shortcut"
STEAM_MODE_STATE="${STATE_DIR}/steam_integration_mode"
SUDO_MODE_STATE="${STATE_DIR}/sudo_repair_mode"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${SCRIPT_DIR}/Work"
APPIMAGE="${WORKDIR}/WiiCompiled-Setup-x86_64.AppImage"
RETRO_ZIP="${WORKDIR}/RetroRewind.zip"
RETRO_EXTRACT="${WORKDIR}/extracted"
RETRO_DIR="${RETRO_EXTRACT}/RetroRewind6"
LOG="${WORKDIR}/wiicompile-deckhelper.log"
ACTION_LOG="${WORKDIR}/last-action.log"
WII_ROOT="${HOME}/.local/share/WiiCompiled"
INSTALL_ROOT="${WII_ROOT}/Install"
CONFIG_TOML="${WII_ROOT}/Config.toml"
RETRO_RUNTIME_PARENT="${WII_ROOT}/RetroRewind"
RETRO_RUNTIME_DIR="${RETRO_RUNTIME_PARENT}/RetroRewind6"
NAND_ROOT="${HOME}/.local/share/WiiCompiled/NAND"
PAL_GAME_ID="RMCP01"
PAL_ISO_SIZE="4699979776"
PAL_CRC32="3a70d78b"
PAL_MD5="e7b1ff1fabb0789482ce2cb0661d986e"
PAL_SHA1="4fde5ce38d68f632d92c5b0d52bbab0b1d355a95"
PAL_SHA256="2fc548bad45f373bad953d410a32e042e7efeef86a90f9ff63ddc5b62f9e6971"

mkdir -p "$STATE_DIR" "$WORKDIR"
touch "$LOG"
[[ -f "$STEAM_TOGGLE_STATE" ]] || printf 'off' > "$STEAM_TOGGLE_STATE"
[[ -f "$SUDO_MODE_STATE" ]] || printf 'ask' > "$SUDO_MODE_STATE"
[[ -f "$VIEW_CONSOLE_STATE" ]] || printf 'off' > "$VIEW_CONSOLE_STATE"
DEFER_CLEANUP=0
STEAM_BATCH_MODE=0
STEAM_BATCH_STOPPED=0

say(){ printf '\n==> %s\n' "$*"; }
ok(){ printf '  [OK] %s\n' "$*"; }
warn(){ printf '  [WARN] %s\n' "$*"; }
fail(){ printf '  [FAIL] %s\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

short_status() {
  echo
  echo "$1"
  sleep 1.5
}

wait_any_key() {
  echo
  read -r -n 1 -s -p "Press any key to return to the menu..." _ || true
  echo
}

confirm() {
  local p="${1:-Continue?}" a=""
  read -r -n 1 -s -p "$p [Y/n] " a || true
  echo "${a:-Y}"
  [[ -z "${a:-}" || "${a,,}" == "y" ]]
}

PROGRESS_OFFSET=0
PROGRESS_SCALE=100

progress_set() {
  local pct="${1:-0}"
  shift || true
  local msg="${*:-Working...}"
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  printf '%s|%s\n' "$pct" "$msg" > "$PROGRESS_STATE"
}

progress_local() {
  local local_pct="${1:-0}"
  shift || true
  local mapped=$(( PROGRESS_OFFSET + (local_pct * PROGRESS_SCALE / 100) ))
  progress_set "$mapped" "$*"
}

progress_reset() {
  progress_set 0 "Ready"
}

# Pass compiler output through unchanged while deriving progress from Ninja/CMake
# counters such as: [434/894] Building C object ...
# Report every 5 completed steps to keep state-file writes tiny.
monitor_compile_progress() {
  local phase_start="${1:-0}"
  local phase_end="${2:-100}"
  local label="${3:-Compiling}"
  local line="" n=0 total=0 pct=0 last_reported=-999

  while IFS= read -r line; do
    printf '%s\n' "$line"

    if [[ "$line" =~ \[([0-9]+)/([0-9]+)\] ]]; then
      n="${BASH_REMATCH[1]}"
      total="${BASH_REMATCH[2]}"

      if (( total > 0 )); then
        if (( n == 1 || n == total || n - last_reported >= 5 )); then
          pct=$(( phase_start + (n * (phase_end - phase_start) / total) ))
          progress_local "$pct" "$label $n/$total"
          last_reported="$n"
        fi
      fi
    fi
  done
}

run_appimage_with_compile_progress() {
  local phase_start="$1"
  local phase_end="$2"
  local label="$3"
  shift 3

  local rc=0
  set +e
  "$APPIMAGE" "$@" 2>&1 | monitor_compile_progress "$phase_start" "$phase_end" "$label"
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

sgdb_auto_art() {
  if [[ ! -f "$SGDB_AUTO_STATE" ]]; then
    printf 'on' > "$SGDB_AUTO_STATE"
  fi
  cat "$SGDB_AUTO_STATE"
}

set_sgdb_key() {
  local key="${1:-}"
  mkdir -p "$STATE_DIR"
  umask 077
  printf '%s' "$key" > "$SGDB_KEY_STATE"
  chmod 600 "$SGDB_KEY_STATE" 2>/dev/null || true
}

set_sgdb_auto_art() {
  case "${1:-}" in
    on|off) printf '%s' "$1" > "$SGDB_AUTO_STATE" ;;
    *) return 1 ;;
  esac
}

current_game() {
  [[ -f "$GAME_STATE" ]] && cat "$GAME_STATE"
  return 0
}

steam_mode() {
  # GUI-started installs pass an immutable snapshot so shortcut/artwork
  # behavior cannot change halfway through a long compilation. Normal status
  # and command-line calls continue to use the persisted preference.
  if [[ -n "${WIICOMPILED_STEAM_MODE_SNAPSHOT:-}" ]]; then
    case "$WIICOMPILED_STEAM_MODE_SNAPSHOT" in
      art|shortcut|off) printf '%s' "$WIICOMPILED_STEAM_MODE_SNAPSHOT"; return 0 ;;
    esac
  fi

  if [[ ! -f "$STEAM_MODE_STATE" ]]; then
    # Fresh DeckHelper state always defaults to the intended Steam Deck
    # experience: create Steam shortcuts and artwork.  Do not let the obsolete
    # add_steam_shortcut legacy flag override a genuinely fresh preference.
    printf 'art' > "$STEAM_MODE_STATE"
  fi

  # Legacy DeckHelper revisions stored "shortcut" for Add to Steam / No Art.
  # The current UI intentionally has only Add to Steam or Do Not Add, so migrate
  # that old value to the full art-enabled mode.
  local mode
  mode="$(cat "$STEAM_MODE_STATE")"
  if [[ "$mode" == "shortcut" ]]; then
    mode="art"
    printf '%s' "$mode" > "$STEAM_MODE_STATE"
  fi
  printf '%s' "$mode"
}

steam_toggle() {
  [[ "$(steam_mode)" == "off" ]] && printf 'off' || printf 'on'
}

steam_mode_label() {
  case "$(steam_mode)" in
    art) printf 'ADD TO STEAM + COVER ART' ;;
    shortcut) printf 'ADD TO STEAM + COVER ART' ;;
    off) printf 'DO NOT ADD TO STEAM' ;;
    *) printf 'ADD TO STEAM / NO ART' ;;
  esac
}

set_steam_mode() {
  case "${1:-}" in
    art|shortcut|off) printf '%s' "$1" > "$STEAM_MODE_STATE" ;;
    *) return 1 ;;
  esac
}

toggle_steam_shortcuts() {
  # Legacy terminal-menu fallback: cycle off -> shortcut -> art -> off.
  case "$(steam_mode)" in
    off) set_steam_mode shortcut ;;
    shortcut) set_steam_mode art ;;
    art) set_steam_mode off ;;
  esac
  short_status "[OK] Steam integration: $(steam_mode_label)"
}

sudo_mode() {
  local v="ask"
  [[ -f "$SUDO_MODE_STATE" ]] && v="$(cat "$SUDO_MODE_STATE")"
  case "$v" in
    ask|auto|check) printf '%s' "$v" ;;
    *) printf 'ask' ;;
  esac
}

sudo_mode_label() {
  case "$(sudo_mode)" in
    ask) printf 'ASK BEFORE SUDO' ;;
    auto) printf 'AUTO REPAIR WITH SUDO' ;;
    check) printf 'NO SUDO / CHECK ONLY' ;;
  esac
}

cycle_sudo_mode() {
  case "$(sudo_mode)" in
    ask)
      printf 'auto' > "$SUDO_MODE_STATE"
      short_status "[OK] Dependency repair mode: AUTO REPAIR WITH SUDO"
      ;;
    auto)
      printf 'check' > "$SUDO_MODE_STATE"
      short_status "[OK] Dependency repair mode: NO SUDO / CHECK ONLY"
      ;;
    *)
      printf 'ask' > "$SUDO_MODE_STATE"
      short_status "[OK] Dependency repair mode: ASK BEFORE SUDO"
      ;;
  esac
}

ensure_sudo() {
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  echo
  echo "DeckHelper needs administrator access only for the package repairs listed above."
  echo "No game files, saves, or WiiCompiled output require sudo."
  sudo -v
}

require_game() {
  local game=""
  game="$(current_game)"
  if [[ -z "$game" || ! -f "$game" ]]; then
    fail "No valid game file is selected."
    echo "Choose option 2 first."
    return 1
  fi
  printf '%s\n' "$game"
}

download_appimage() {
  if [[ -x "$APPIMAGE" ]]; then
    ok "WiiCompiled installer already present."
    return 0
  fi
  progress_local 10 "Downloading WiiCompiled installer"
  say "Downloading WiiCompiled PR #37 installer"
  wget -O "$APPIMAGE" "$APPIMAGE_URL"
  chmod +x "$APPIMAGE"
  ok "Installer ready: $APPIMAGE"
}

reinstall_pkg() {
  local pkg="$1"
  local mode
  mode="$(sudo_mode)"

  say "Package repair needed: $pkg"
  echo "SteamOS can report a package installed while its development files are pruned."
  echo "An explicit reinstall is used; --needed is intentionally NOT used."

  if [[ "$mode" == "check" ]]; then
    warn "NO SUDO / CHECK ONLY is enabled."
    echo "Would repair with:"
    echo "  sudo pacman -S $pkg"
    return 3
  fi

  if [[ "$mode" == "ask" ]]; then
    echo
    echo "This repair requires sudo:"
    echo "  sudo pacman -S $pkg"
    confirm "Allow DeckHelper to repair $pkg ?" || return 1
  fi

  ensure_sudo || return 1
  sudo pacman -S --noconfirm "$pkg"
}
check_file_or_repair() {
  local path="$1" pkg="$2" label="$3"
  if [[ -e "$path" ]]; then ok "$label"; return 0; fi
  fail "$label missing: $path"
  reinstall_pkg "$pkg" || return 1
  if [[ ! -e "$path" ]]; then
    fail "$label is still missing after reinstalling $pkg."
    echo "If pacman reported file conflicts, try manually:"
    echo "  sudo pacman -S --overwrite='*' $pkg"
    return 1
  fi
  ok "$label restored."
}

dependency_probe() {
  # Read-only preflight used by the GUI. It never repairs, prompts, or uses sudo.
  # Exit 0 = verification should be non-interactive.
  # Exit 10 = a repair is likely required, so the GUI should expose Konsole.
  local needs=0 cmd=""

  for cmd in bash clang clang++ cmake ninja curl unzip wget pkg-config python3 file; do
    have "$cmd" || needs=1
  done

  for path in \
    /usr/include/pthread.h \
    /usr/include/alsa/asoundlib.h \
    /usr/include/X11/Xlib.h \
    /usr/include/GL/gl.h \
    /usr/include/libudev.h \
    /usr/include/libusb-1.0/libusb.h \
    /usr/include/linux/input.h
  do
    [[ -e "$path" ]] || needs=1
  done

  if have clang; then
    if ! echo '#include <pthread.h>
int main(void){return 0;}' | clang -x c -pthread -o /tmp/wiicompile-pthread-probe - >/dev/null 2>&1; then
      needs=1
    fi
    rm -f /tmp/wiicompile-pthread-probe
  else
    needs=1
  fi

  if have pkg-config; then
    pkg-config --exists alsa 2>/dev/null || needs=1
    pkg-config --exists libusb-1.0 2>/dev/null || needs=1
    pkg-config --exists x11 2>/dev/null || needs=1
  else
    needs=1
  fi

  if (( needs )); then
    echo "REPAIR_REQUIRED"
    return 10
  fi

  echo "READY"
  return 0
}

verify_dependencies() {
  PROGRESS_OFFSET=0
  PROGRESS_SCALE=100
  progress_local 3 "Checking build tools"
  say "Verifying WiiCompiled build dependencies"
  echo "Root filesystem:"; df -h / || true
  echo; echo "Home filesystem:"; df -h "$HOME" || true

  local missing=()
  for cmd in bash clang clang++ cmake ninja curl unzip wget pkg-config python3 file; do
    if have "$cmd"; then ok "$cmd -> $(command -v "$cmd")"; else fail "$cmd is missing"; missing+=("$cmd"); fi
  done

  if ((${#missing[@]})); then
    warn "Missing command-line tools detected."
    if confirm "Install missing tools now?"; then
      local pkgs=()
      for cmd in "${missing[@]}"; do
        case "$cmd" in
          bash) pkgs+=(bash) ;;
          clang|clang++) pkgs+=(clang) ;;
          cmake) pkgs+=(cmake) ;;
          ninja) pkgs+=(ninja) ;;
          curl) pkgs+=(curl) ;;
          unzip) pkgs+=(unzip) ;;
          wget) pkgs+=(wget) ;;
          pkg-config) pkgs+=(pkgconf) ;;
          python3) pkgs+=(python) ;;
          file) pkgs+=(file) ;;
        esac
      done
      mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | awk '!seen[$0]++')
      local mode
      mode="$(sudo_mode)"
      if [[ "$mode" == "check" ]]; then
        warn "NO SUDO / CHECK ONLY is enabled."
        echo "Would install:"
        printf '  %s\n' "${pkgs[*]}"
        return 1
      fi
      if [[ "$mode" == "ask" ]]; then
        echo
        echo "These missing tools require sudo to install:"
        printf '  %s\n' "${pkgs[*]}"
        confirm "Allow DeckHelper to install them?" || return 1
      fi
      ensure_sudo || return 1
      sudo pacman -S --noconfirm "${pkgs[@]}"
    else
      return 1
    fi
  fi

  say "Checking SteamOS development headers"
  check_file_or_repair "/usr/include/pthread.h" "glibc" "pthread headers" || return 1

  if echo '#include <pthread.h>
int main(void){return 0;}' | clang -x c -pthread -o /tmp/wiicompile-pthread-test - >/dev/null 2>&1; then
    ok "pthread compile test"
  else
    fail "pthread compile test failed"
    reinstall_pkg glibc || return 1
    echo '#include <pthread.h>
int main(void){return 0;}' | clang -x c -pthread -o /tmp/wiicompile-pthread-test -
    ok "pthread compile test repaired"
  fi
  rm -f /tmp/wiicompile-pthread-test

  check_file_or_repair "/usr/include/alsa/asoundlib.h" "alsa-lib" "ALSA headers" || return 1
  check_file_or_repair "/usr/include/X11/Xlib.h" "libx11" "X11 headers" || return 1
  check_file_or_repair "/usr/include/GL/gl.h" "libglvnd" "OpenGL headers" || return 1
  check_file_or_repair "/usr/include/libudev.h" "systemd-libs" "libudev headers" || return 1
  check_file_or_repair "/usr/include/libusb-1.0/libusb.h" "libusb" "libusb headers" || return 1
  check_file_or_repair "/usr/include/linux/input.h" "linux-api-headers" "Linux input headers" || return 1

  say "Checking pkg-config dependency resolution"
  if ! pkg-config --exists alsa 2>/dev/null; then reinstall_pkg alsa-lib || return 1; fi
  pkg-config --exists alsa 2>/dev/null || { fail "ALSA pkg-config unresolved."; return 1; }
  ok "alsa pkg-config"

  if ! pkg-config --exists libusb-1.0 2>/dev/null; then reinstall_pkg libusb || return 1; fi
  pkg-config --exists libusb-1.0 2>/dev/null || { fail "libusb pkg-config unresolved."; return 1; }
  ok "libusb pkg-config"

  if ! pkg-config --exists x11 2>/dev/null; then
    warn "X11 pkg-config chain is incomplete."
    for pkg in libx11 xorgproto libxcb libxau libxdmcp; do reinstall_pkg "$pkg" || return 1; done
  fi
  pkg-config --exists x11 2>/dev/null || { fail "X11 pkg-config is still unresolved."; return 1; }
  ok "x11 pkg-config"

  download_appimage
  say "Dependency verification complete"
  ok "Build environment looks ready."
}

select_game() {
  say "Select Mario Kart Wii game file"
  local game=""

  if have kdialog; then
    game="$(kdialog --title "Select Mario Kart Wii game image" \
      --getopenfilename "${HOME}/Downloads/" \
      "*.iso *.wbfs|Wii game images (*.iso *.wbfs);;*|All files" 2>/dev/null || true)"
    [[ -n "$game" ]] || { warn "Game selection cancelled."; return 2; }
  else
    read -r -p "Game file: " game || true
    game="${game#\'}"; game="${game%\'}"; game="${game#\"}"; game="${game%\"}"
    game="${game/#\~/$HOME}"
  fi

  [[ -f "$game" ]] || { fail "File not found: $game"; return 1; }
  printf '%s' "$game" > "$GAME_STATE"
  ok "Game file latched:"
  echo "  $game"
}

candidate_scan_roots() {
  # Search the places most likely to contain a game image first, then widen.
  # The final fallback covers the whole Deck while pruning virtual/system trees.
  local roots=(
    "$HOME/Downloads"
    "$HOME/Emulation/roms"
    "$HOME/Emulation"
    "$HOME/Games"
    "$HOME/roms"
    "$HOME/Roms"
    "$HOME/Documents"
    "$HOME/Desktop"
    "$HOME/.var/app/org.DolphinEmu.dolphin-emu/data/dolphin-emu"
    "$HOME/.var/app"
    "$HOME"
  )
  [[ -d "/run/media/$USER" ]] && roots+=("/run/media/$USER")
  printf '%s\n' "${roots[@]}" | awk '!seen[$0]++'
}

whole_deck_candidate_stream() {
  # Final fallback only. Avoid virtual/kernel trees and DeckHelper's own work dir.
  find / \
    \( -path /proc -o -path /sys -o -path /dev -o -path /run \
       -o -path /tmp -o -path /var/tmp \
       -o -path "$WORKDIR" \) -prune -o \
    -type f \
    \( -iname '*.iso' -o -iname '*.gcm' -o -iname '*.gcz' \
       -o -iname '*.ciso' -o -iname '*.wbfs' -o -iname '*.wia' \
       -o -iname '*.rvz' \) -print0 2>/dev/null
}

supported_game_extension() {
  local p="${1:-}" ext=""
  ext="${p##*.}"
  ext="${ext,,}"
  case "$ext" in
    iso|gcm|gcz|ciso|wbfs|wia|rvz) return 0 ;;
    *) return 1 ;;
  esac
}

is_raw_disc_format() {
  local p="${1:-}" ext=""
  ext="${p##*.}"
  ext="${ext,,}"
  [[ "$ext" == "iso" || "$ext" == "gcm" ]]
}

verify_exact_pal_raw_path() {
  local p="${1:-}"
  [[ -n "$p" && -f "$p" ]] || return 1
  is_raw_disc_format "$p" || return 1

  local size="" id="" crc="" md5="" sha1="" sha256=""

  # Cheap checks first so unrelated multi-gigabyte images never get fully hashed.
  size="$(stat -c '%s' "$p" 2>/dev/null || echo 0)"
  [[ "$size" == "$PAL_ISO_SIZE" ]] || return 1

  id="$(dd if="$p" bs=1 count=6 status=none 2>/dev/null || true)"
  [[ "$id" == "$PAL_GAME_ID" ]] || return 1

  crc="$(python3 - "$p" <<'PY'
import sys, zlib
crc = 0
with open(sys.argv[1], "rb") as f:
    for block in iter(lambda: f.read(8 * 1024 * 1024), b""):
        crc = zlib.crc32(block, crc)
print(f"{crc & 0xffffffff:08x}")
PY
)"
  [[ "$crc" == "$PAL_CRC32" ]] || return 1

  md5="$(md5sum "$p" 2>/dev/null | awk '{print $1}')"
  [[ "$md5" == "$PAL_MD5" ]] || return 1

  sha1="$(sha1sum "$p" 2>/dev/null | awk '{print $1}')"
  [[ "$sha1" == "$PAL_SHA1" ]] || return 1

  sha256="$(sha256sum "$p" 2>/dev/null | awk '{print $1}')"
  [[ "$sha256" == "$PAL_SHA256" ]] || return 1

  return 0
}

dolphin_tool_path() {
  if command -v dolphin-tool >/dev/null 2>&1; then
    command -v dolphin-tool
    return 0
  fi
  return 1
}

verify_pal_container_with_dolphin_tool() {
  local p="${1:-}" tool="" out="" md5=""
  [[ -n "$p" && -f "$p" ]] || return 1
  supported_game_extension "$p" || return 1

  tool="$(dolphin_tool_path)" || return 2

  # DolphinTool hashes the logical disc image through its format reader, which
  # lets the same clean-disc MD5 be compared across supported lossless containers.
  out="$("$tool" verify -i "$p" -a md5 2>&1)" || {
    printf '[auto-scan] dolphin-tool could not verify: %s\n%s\n' "$p" "$out" >> "$LOG"
    return 1
  }

  md5="$(printf '%s\n' "$out" | grep -Eio '[0-9a-f]{32}' | tail -n1 | tr 'A-F' 'a-f')"
  [[ "$md5" == "$PAL_MD5" ]] || return 1
  return 0
}

write_verified_pal_state() {
  local p="${1:-}" sha1="" sha256="" size="" id=""
  [[ -n "$p" && -f "$p" ]] || return 1

  size="$(stat -c '%s' "$p" 2>/dev/null || echo 0)"
  if is_raw_disc_format "$p"; then
    id="$PAL_GAME_ID"
    sha1="$PAL_SHA1"
    sha256="$PAL_SHA256"
  else
    id="$PAL_GAME_ID"
    sha1="container-logical-md5:${PAL_MD5}"
    sha256=""
  fi

  printf '%s' "$p" > "$GAME_STATE"
  printf '%s' "$p" > "$VERIFIED_GAME_STATE"
  printf '%s' "$p" > "$GAME_FINGERPRINT_PATH_STATE"
  printf '%s' "$id" > "$GAME_ID_STATE"
  printf '%s' "$size" > "$GAME_SIZE_STATE"
  printf '%s' "$sha1" > "$GAME_SHA1_STATE"
  printf '%s' "$sha256" > "$GAME_SHA256_STATE"
  stat -c '%Y' "$p" 2>/dev/null > "$GAME_MTIME_STATE" || rm -f "$GAME_MTIME_STATE"
  stat -c '%i' "$p" 2>/dev/null > "$GAME_INODE_STATE" || rm -f "$GAME_INODE_STATE"
}


reuse_cached_verified_game() {
  # RC20 fast path: a previously verified image does not need another directory
  # walk or multi-gigabyte hash pass when the exact file identity is unchanged.
  local p="" old_size="" old_mtime="" old_inode="" size="" mtime="" inode=""
  [[ -f "$VERIFIED_GAME_STATE" ]] || return 1
  p="$(cat "$VERIFIED_GAME_STATE" 2>/dev/null || true)"
  [[ -n "$p" && -f "$p" ]] || return 1
  supported_game_extension "$p" || return 1

  old_size="$(cat "$GAME_SIZE_STATE" 2>/dev/null || true)"
  old_mtime="$(cat "$GAME_MTIME_STATE" 2>/dev/null || true)"
  old_inode="$(cat "$GAME_INODE_STATE" 2>/dev/null || true)"
  size="$(stat -c '%s' "$p" 2>/dev/null || true)"
  mtime="$(stat -c '%Y' "$p" 2>/dev/null || true)"
  inode="$(stat -c '%i' "$p" 2>/dev/null || true)"

  # Old RCs do not have mtime/inode cache data. They deliberately fall through
  # to one full verification, which upgrades the cache for subsequent starts.
  [[ -n "$old_size" && -n "$old_mtime" && -n "$old_inode" ]] || return 1
  [[ "$size" == "$old_size" && "$mtime" == "$old_mtime" && "$inode" == "$old_inode" ]] || return 1

  printf '%s' "$p" > "$GAME_STATE"
  printf '[auto-scan] FAST verified-path reuse (size/mtime/inode unchanged): %s\n' "$p" >> "$LOG"
  ok "Previously verified PAL Mario Kart Wii image is unchanged:"
  echo "  $p"
  return 0
}

auto_find_pal_mkwii() {
  say "Auto-detecting a verified PAL Mario Kart Wii image"

  reuse_cached_verified_game && return 0

  local p="" ext="" root="" rc=1
  declare -A seen=()

  verify_candidate_and_accept() {
    local candidate="$1"
    [[ -f "$candidate" ]] || return 1
    [[ -n "${seen[$candidate]:-}" ]] && return 1
    seen["$candidate"]=1

    printf '[auto-scan] candidate: %s\n' "$candidate" >> "$LOG"

    if is_raw_disc_format "$candidate"; then
      # One sequential read computes every canonical hash and avoids rereading
      # a 4.7 GB ISO four times.
      if python3 - "$candidate" "$PAL_ISO_SIZE" "$PAL_GAME_ID" "$PAL_CRC32" "$PAL_MD5" "$PAL_SHA1" "$PAL_SHA256" >>"$LOG" 2>&1 <<'PY'
import sys, os, hashlib, zlib
p, exp_size, exp_id, exp_crc, exp_md5, exp_sha1, exp_sha256 = sys.argv[1:]
try:
    size = os.path.getsize(p)
    if str(size) != exp_size:
        print(f"[auto-scan] raw reject size={size}: {p}")
        raise SystemExit(1)

    crc = 0
    md5 = hashlib.md5()
    sha1 = hashlib.sha1()
    sha256 = hashlib.sha256()

    with open(p, "rb") as f:
        game_id = f.read(6)
        if game_id.decode("ascii", "replace") != exp_id:
            print(f"[auto-scan] raw reject id={game_id!r}: {p}")
            raise SystemExit(1)
        f.seek(0)
        for block in iter(lambda: f.read(8 * 1024 * 1024), b""):
            crc = zlib.crc32(block, crc)
            md5.update(block)
            sha1.update(block)
            sha256.update(block)

    got_crc = f"{crc & 0xffffffff:08x}"
    got_md5 = md5.hexdigest()
    got_sha1 = sha1.hexdigest()
    got_sha256 = sha256.hexdigest()
    print(f"[auto-scan] raw hashes crc32={got_crc} md5={got_md5} sha1={got_sha1} sha256={got_sha256}: {p}")

    ok = (
        got_crc == exp_crc and
        got_md5 == exp_md5 and
        got_sha1 == exp_sha1 and
        got_sha256 == exp_sha256
    )
    raise SystemExit(0 if ok else 1)
except Exception as e:
    print(f"[auto-scan] verifier error {type(e).__name__}: {e}: {p}")
    raise SystemExit(1)
PY
      then
        write_verified_pal_state "$candidate"
        printf '[auto-scan] VERIFIED raw RMCP01: %s\n' "$candidate" >> "$LOG"
        ok "Verified PAL Mario Kart Wii image found:"
        echo "  $candidate"
        return 0
      fi
      return 1
    fi

    if verify_pal_container_with_dolphin_tool "$candidate"; then
      write_verified_pal_state "$candidate"
      printf '[auto-scan] VERIFIED container RMCP01 via dolphin-tool: %s\n' "$candidate" >> "$LOG"
      ok "Verified PAL Mario Kart Wii container found:"
      echo "  $candidate"
      return 0
    else
      rc=$?
      if [[ "$rc" -eq 2 ]]; then
        printf '[auto-scan] supported container seen but dolphin-tool is unavailable: %s\n' "$candidate" >> "$LOG"
      fi
    fi
    return 1
  }

  # Pass 1: likely locations, ordered from fastest/most useful to broader.
  while IFS= read -r root; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' p; do
      verify_candidate_and_accept "$p" && return 0
    done < <(
      find "$root" -maxdepth 6 -type f \
        \( -iname '*.iso' -o -iname '*.gcm' -o -iname '*.gcz' \
           -o -iname '*.ciso' -o -iname '*.wbfs' -o -iname '*.wia' \
           -o -iname '*.rvz' \) -print0 2>/dev/null
    )
  done < <(candidate_scan_roots)

  # Pass 2: whole Deck fallback. This is deliberately last because it can be slow.
  printf '[auto-scan] entering whole-Deck fallback scan\n' >> "$LOG"
  while IFS= read -r -d '' p; do
    verify_candidate_and_accept "$p" && return 0
  done < <(whole_deck_candidate_stream)

  rm -f "$VERIFIED_GAME_STATE"
  warn "No pre-verified PAL image was found automatically."
  return 1
}

verify_selected_game() {
  local p="" rc=1 ext=""
  p="$(current_game)"
  [[ -n "$p" && -f "$p" ]] || {
    rm -f "$VERIFIED_GAME_STATE"
    return 1
  }

  supported_game_extension "$p" || {
    rm -f "$VERIFIED_GAME_STATE"
    return 1
  }

  progress_local 5 "Reading game image"

  if is_raw_disc_format "$p"; then
    if verify_exact_pal_raw_path "$p"; then
      write_verified_pal_state "$p"
      progress_local 100 "PAL RMCP01 raw image verified"
      return 0
    fi
    rm -f "$VERIFIED_GAME_STATE"
    progress_local 100 "Raw image did not match clean PAL RMCP01"
    return 1
  fi

  if verify_pal_container_with_dolphin_tool "$p"; then
    write_verified_pal_state "$p"
    progress_local 100 "PAL RMCP01 container verified"
    return 0
  else
    rc=$?
  fi

  # The format is still supported by WiiCompiled. If DolphinTool is absent,
  # keep the user's selection and let WiiCompiled perform its own authoritative
  # region/content rejection during install rather than falsely claiming a hash match.
  if [[ "$rc" -eq 2 ]]; then
    printf '%s' "$p" > "$GAME_FINGERPRINT_PATH_STATE"
    printf 'SUPPORTED-CONTAINER' > "$GAME_ID_STATE"
    printf '%s' "$(stat -c '%s' "$p" 2>/dev/null || echo 0)" > "$GAME_SIZE_STATE"
    : > "$GAME_SHA1_STATE"
    : > "$GAME_SHA256_STATE"
    rm -f "$VERIFIED_GAME_STATE"
    progress_local 100 "Supported container selected; WiiCompiled will validate during install"
    return 3
  fi

  rm -f "$VERIFIED_GAME_STATE"
  progress_local 100 "Container did not match clean PAL RMCP01"
  return 1
}


auto_find_migration_data() {
  # RC20 fast path: preserve already-discovered external sources while they
  # still exist. The explicit Rescan button can refresh these by deleting the
  # cached source state first through scan-migration below.
  local cached_mii="" cached_save=""
  cached_mii="$(cat "$MII_SOURCE_STATE" 2>/dev/null || true)"
  cached_save="$(cat "$SAVE_SOURCE_STATE" 2>/dev/null || true)"
  if { [[ -n "$cached_mii" && -f "$cached_mii" ]] || [[ -n "$cached_save" && -f "$cached_save" ]]; }; then
    [[ -n "$cached_mii" && -f "$cached_mii" ]] || rm -f "$MII_SOURCE_STATE"
    [[ -n "$cached_save" && -f "$cached_save" ]] || rm -f "$SAVE_SOURCE_STATE"
    ok "Reusing previously detected save/Mii source paths."
    return 0
  fi
  say "Scanning for Retro Rewind save + Mii data"

  local mii="" save="" p="" root="" score=0 best_score=-1

  score_candidate() {
    local path="$1" s=0
    case "$path" in
      "$HOME/.local/share/"*) ((s+=50)) ;;
      "$HOME/"*) ((s+=35)) ;;
      "/run/media/$USER/"*) ((s+=25)) ;;
    esac
    case "${path,,}" in
      *wheelwizard*) ((s+=60)) ;;
      *dolphin*) ((s+=45)) ;;
      *retrorewind*) ((s+=40)) ;;
      *retrowfc2*) ((s+=35)) ;;
      *retrowfc*) ((s+=30)) ;;
    esac
    printf '%s\n' "$s"
  }

  # Collect all plausible Mii DBs and choose the strongest source rather than
  # blindly latching the first filesystem result.
  best_score=-1
  while IFS= read -r root; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' p; do
      [[ "$p" == "$NAND_ROOT"* ]] && continue
      [[ "$p" == */shared2/menu/FaceLib/RFL_DB.dat ]] || continue
      score="$(score_candidate "$p")"
      if (( score > best_score )); then
        best_score="$score"
        mii="$p"
      fi
    done < <(find "$root" -maxdepth 12 -type f -name 'RFL_DB.dat' -print0 2>/dev/null)
  done < <(candidate_scan_roots)

  # Same ranking for Retro Rewind PAL save candidates.
  best_score=-1
  while IFS= read -r root; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' p; do
      [[ "$p" == "$NAND_ROOT"* ]] && continue
      case "$p" in
        */riivolution/save/RetroWFC/RMCP/rksys.dat|\
        */riivolution/save/RetroWFC2/RMCP/rksys.dat|\
        */Riivolution/WheelWizard/riivolution/save/RetroWFC/RMCP/rksys.dat|\
        */Riivolution/WheelWizard/riivolution/save/RetroWFC2/RMCP/rksys.dat)
          score="$(score_candidate "$p")"
          if (( score > best_score )); then
            best_score="$score"
            save="$p"
          fi
          ;;
      esac
    done < <(find "$root" -maxdepth 14 -type f -name 'rksys.dat' -print0 2>/dev/null)
  done < <(candidate_scan_roots)

  if [[ -n "$mii" ]]; then
    printf '%s' "$mii" > "$MII_SOURCE_STATE"
    ok "Best Mii database source:"
    echo "  $mii"
  else
    warn "No external RFL_DB.dat found."
    rm -f "$MII_SOURCE_STATE"
  fi

  if [[ -n "$save" ]]; then
    printf '%s' "$save" > "$SAVE_SOURCE_STATE"
    ok "Best Retro Rewind PAL save source:"
    echo "  $save"
  else
    warn "No Wheel Wizard / Retro Rewind PAL rksys.dat found."
    rm -f "$SAVE_SOURCE_STATE"
  fi

  [[ -n "$mii" || -n "$save" ]]
}

auto_detect_everything() {
  local rc=0
  auto_find_pal_mkwii || rc=1
  auto_find_migration_data || true
  return "$rc"
}

cleanup_legacy_rc_state() {
  # Remove only DeckHelper-owned experimental leftovers that have no meaning in
  # RC20. Never touch WiiCompiled NAND, saves, Config.toml, ROMs, or installs.
  rm -f \
    "$STATE_DIR/resume_checkpoint" \
    "$STATE_DIR/controller_backend" \
    "$STATE_DIR/controller_input_backend" \
    "$WORKDIR/controller-input.log" 2>/dev/null || true

  # Stale detached-process markers are safe to discard only when that PID no
  # longer exists. Live RC19 background builds remain reattachable.
  local bgpid=""
  bgpid="$(cat "$STATE_DIR/background_build_pid" 2>/dev/null || true)"
  if [[ -n "$bgpid" && "$bgpid" =~ ^[0-9]+$ ]] && ! kill -0 "$bgpid" 2>/dev/null; then
    rm -f "$STATE_DIR/background_build_pid" "$STATE_DIR/background_build_action"
  fi
}

rescan_game_image() {
  # Explicit user rescan bypasses RC20's startup cache. Fingerprint details are
  # retained only until a new candidate is verified, then rewritten together.
  rm -f "$VERIFIED_GAME_STATE" "$GAME_MTIME_STATE" "$GAME_INODE_STATE"
  auto_find_pal_mkwii
}

rescan_migration_data() {
  rm -f "$MII_SOURCE_STATE" "$SAVE_SOURCE_STATE"
  auto_find_migration_data
}

startup_auto_detect() {
  cleanup_legacy_rc_state
  auto_find_pal_mkwii || true
  auto_find_migration_data || true
  recover_orphaned_installation || true
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp -a -- "$f" "${f}.deckhelper-backup-${stamp}"
  ok "Backed up existing file:"
  echo "  ${f}.deckhelper-backup-${stamp}"
}

find_wiicomp_rksys_target() {
  local p=""
  if [[ -d "$NAND_ROOT" ]]; then
    p="$(find "$NAND_ROOT" -type f -name 'rksys.dat' -print -quit 2>/dev/null || true)"
  fi
  if [[ -n "$p" ]]; then
    printf '%s\n' "$p"
  else
    printf '%s\n' "$NAND_ROOT/title/00010004/524d4350/data/rksys.dat"
  fi
}

import_migration_data() {
  local mii="" save="" mii_dst="" save_dst="" src_dir=""

  [[ -f "$MII_SOURCE_STATE" ]] && mii="$(cat "$MII_SOURCE_STATE")"
  [[ -f "$SAVE_SOURCE_STATE" ]] && save="$(cat "$SAVE_SOURCE_STATE")"

  if [[ -z "$mii" && -z "$save" ]]; then
    fail "No migration data is latched."
    echo "Use Scan for Saves + Miis first, then try the import again."
    return 1
  fi

  say "Import Retro Rewind save + Mii data"
  echo "DeckHelper will back up existing WiiCompiled files before replacing them."
  echo

  if [[ -n "$mii" && -f "$mii" ]]; then
    mii_dst="$NAND_ROOT/shared2/menu/FaceLib/RFL_DB.dat"
    mkdir -p "$(dirname "$mii_dst")"
    backup_file "$mii_dst"
    cp -a -- "$mii" "$mii_dst"
    ok "Mii database imported."
  fi

  if [[ -n "$save" && -f "$save" ]]; then
    save_dst="$(find_wiicomp_rksys_target)"
    mkdir -p "$(dirname "$save_dst")"
    backup_file "$save_dst"
    cp -a -- "$save" "$save_dst"
    ok "Retro Rewind rksys.dat imported:"
    echo "  $save_dst"

    # If the source folder contains the companion WC24 files, copy them too.
    src_dir="$(dirname "$save")"
    for f in banner.bin wc24dl.vff wc24scr.vff; do
      if [[ -f "$src_dir/$f" ]]; then
        backup_file "$(dirname "$save_dst")/$f"
        cp -a -- "$src_dir/$f" "$(dirname "$save_dst")/$f"
        ok "Imported companion file: $f"
      fi
    done
  fi

  say "Migration import complete"
  echo "If you already had WiiCompiled save data, timestamped backups were kept beside it."
}

require_installed_elf() {
  local exe="$1" label="${2:-Installed game}"
  [[ -x "$exe" ]] || { fail "$label executable was not installed at the expected path: $exe"; return 1; }
  file -b "$exe" 2>/dev/null | grep -qE 'ELF .* executable' || { fail "$label output exists but is not a native ELF executable: $exe"; return 1; }
}

is_native_elf() {
  local exe="$1"
  [[ -x "$exe" ]] && file -b "$exe" 2>/dev/null | grep -qE 'ELF .* executable'
}

base_install_valid() {
  is_native_elf "${INSTALL_ROOT}/Base/WiiCompiled"
}

retro_install_valid() {
  is_native_elf "${INSTALL_ROOT}/RetroRewind/RetroRewind" && verify_retro_runtime
}

mark_active_build() {
  local phase="${1:-unknown}"
  printf '%s' "$phase" > "$ACTIVE_BUILD_STATE"
}

clear_active_build_markers() {
  rm -f "$ACTIVE_BUILD_STATE" "$ACTIVE_BASE_PREEXIST_STATE" "$ACTIVE_RETRO_PREEXIST_STATE" "$ACTIVE_TOPLEVEL_PREEXIST_STATE" "$ACTIVE_REQUESTED_ACTION_STATE"
}

snapshot_wii_toplevel() {
  : > "$ACTIVE_TOPLEVEL_PREEXIST_STATE"
  [[ -d "$WII_ROOT" ]] || return 0
  find "$WII_ROOT" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort > "$ACTIVE_TOPLEVEL_PREEXIST_STATE" || true
}

prepare_build_transaction() {
  local requested_action="${1:-build}"
  base_install_valid && printf '1' > "$ACTIVE_BASE_PREEXIST_STATE" || printf '0' > "$ACTIVE_BASE_PREEXIST_STATE"
  retro_install_valid && printf '1' > "$ACTIVE_RETRO_PREEXIST_STATE" || printf '0' > "$ACTIVE_RETRO_PREEXIST_STATE"
  snapshot_wii_toplevel
  printf '%s' "$requested_action" > "$ACTIVE_REQUESTED_ACTION_STATE"
  rm -f "$RESUME_STATE"
}

write_resume_checkpoint() {
  local requested_action="${1:-build}" phase="" game="" steam="off"
  [[ -f "$ACTIVE_BUILD_STATE" ]] && phase="$(cat "$ACTIVE_BUILD_STATE")"
  [[ -f "$GAME_STATE" ]] && game="$(cat "$GAME_STATE")"
  steam="$(steam_mode)"
  {
    printf 'version=%q\n' "$DECKHELPER_VERSION"
    printf 'action=%q\n' "$requested_action"
    printf 'phase=%q\n' "${phase:-unknown}"
    printf 'game=%q\n' "$game"
    printf 'steam_mode=%q\n' "$steam"
    printf 'created=%q\n' "$(date -Is 2>/dev/null || date)"
  } > "$RESUME_STATE"
  chmod 600 "$RESUME_STATE" 2>/dev/null || true
}

recover_orphaned_installation() {
  # A normal preserved cancellation already has an explicit checkpoint.  This
  # recovery path is only for an installation whose manager disappeared (power
  # loss, killed GUI, or an older DeckHelper background run) while compiler
  # state survived.
  [[ -f "$RESUME_STATE" ]] && return 0
  [[ -f "$ACTIVE_BUILD_STATE" ]] || return 0
  [[ -d "${WII_ROOT}/workspace" ]] || return 0

  local game="" phase="" action=""
  [[ -f "$GAME_STATE" ]] && game="$(cat "$GAME_STATE")"
  [[ -n "$game" && -f "$game" ]] || return 0
  phase="$(cat "$ACTIVE_BUILD_STATE" 2>/dev/null || true)"

  # If the action lock is still held, the compiler is genuinely alive in the
  # background.  Do not manufacture a resume checkpoint while it is running.
  exec 8>"$ACTION_LOCK"
  if ! flock -n 8; then
    exec 8>&-
    return 0
  fi
  flock -u 8 2>/dev/null || true
  exec 8>&-

  if [[ -f "$ACTIVE_REQUESTED_ACTION_STATE" ]]; then
    action="$(cat "$ACTIVE_REQUESTED_ACTION_STATE")"
  else
    # Legacy RC16/RC17 recovery.  A Retro phase after a completed/attempted
    # Base stage is safely resumed as Build Both; Build Both is state-aware and
    # will skip a valid Base executable rather than rebuilding it.
    case "$phase" in
      retro-started|retro-complete|build-both-started|base-complete) action="build-both" ;;
      base-started) action="build-base" ;;
      *) return 0 ;;
    esac
  fi

  case "$action" in
    build-base|build-retro|build-both) ;;
    *) return 0 ;;
  esac

  write_resume_checkpoint "$action"
  ok "Recovered an interrupted WiiCompiled installation; Resume Previous Installation is available."
}

purge_new_wii_toplevel_entries() {
  [[ -d "$WII_ROOT" ]] || return 0
  local name=""
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    # NAND may contain imported saves/Miis and is never compiled build data.
    [[ "$name" == "NAND" ]] && continue
    # Preserve user runtime preferences. Future build-option validation must
    # explicitly decide when Config.toml needs regeneration.
    [[ "$name" == "Config.toml" ]] && continue
    if ! grep -Fxq -- "$name" "$ACTIVE_TOPLEVEL_PREEXIST_STATE" 2>/dev/null; then
      rm -rf -- "$WII_ROOT/$name" 2>/dev/null || true
      ok "Removed generated WiiCompiled data: $name"
    fi
  done < <(find "$WII_ROOT" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null || true)
}

cleanup_interrupted_build() {
  local spec="${1:-build:delete}" requested_action="" cleanup_mode="delete"
  local phase="" base_pre="0" retro_pre="0"
  requested_action="${spec%%:*}"
  [[ "$spec" == *:* ]] && cleanup_mode="${spec##*:}"
  [[ "$cleanup_mode" == "keep" || "$cleanup_mode" == "delete" ]] || cleanup_mode="delete"
  [[ -f "$ACTIVE_BUILD_STATE" ]] && phase="$(cat "$ACTIVE_BUILD_STATE")"
  [[ -f "$ACTIVE_BASE_PREEXIST_STATE" ]] && base_pre="$(cat "$ACTIVE_BASE_PREEXIST_STATE")"
  [[ -f "$ACTIVE_RETRO_PREEXIST_STATE" ]] && retro_pre="$(cat "$ACTIVE_RETRO_PREEXIST_STATE")"

  say "Stopping interrupted installation"
  echo "Action: $requested_action"
  echo "Last phase: ${phase:-unknown}"
  echo "Compiled progress: $cleanup_mode"

  if [[ "$cleanup_mode" == "keep" ]]; then
    write_resume_checkpoint "$requested_action"
    progress_reset
    ok "Compilation progress preserved. DeckHelper can resume this installation later."
    return 0
  fi

  # Delete mode is the default. Remove DeckHelper-owned disposable staging and
  # ALL resumable compiler/generated state, while preserving source game files,
  # NAND save/Mii data, preferences, and known-good installs that existed before
  # this transaction.
  cleanup_downloads
  rm -rf -- "${RETRO_RUNTIME_DIR}.deckhelper-new" 2>/dev/null || true

  # WiiCompiled's workspace is build/cache material, not user data. Keeping it
  # after a deliberate "Delete compiled installation data" cancellation is
  # exactly what RC16 got wrong: a later build could silently reuse stale
  # options/artifacts. Always remove it in delete mode.
  rm -rf -- "${WII_ROOT}/workspace" 2>/dev/null || true
  rm -f -- "${WII_ROOT}/install-state.json" 2>/dev/null || true
  ok "Removed resumable WiiCompiled compiler workspace/state."

  if [[ "$base_pre" != "1" ]]; then
    rm -rf -- "${INSTALL_ROOT}/Base" 2>/dev/null || true
    ok "Removed Base compiled installation data from this transaction."
  fi
  if [[ "$retro_pre" != "1" ]]; then
    rm -rf -- "${INSTALL_ROOT}/RetroRewind" 2>/dev/null || true
    rm -rf -- "$RETRO_RUNTIME_DIR" 2>/dev/null || true
    ok "Removed Retro Rewind compiled/runtime data from this transaction."
  fi

  # Catch any other top-level generated entries introduced by the transaction.
  # NAND and Config.toml are explicitly preserved by this helper.
  purge_new_wii_toplevel_entries

  # Tidy empty compiled-data parent directories without touching persistent data.
  rmdir "$INSTALL_ROOT" 2>/dev/null || true
  rmdir "$RETRO_RUNTIME_PARENT" 2>/dev/null || true

  rm -f "$RESUME_STATE"
  clear_active_build_markers
  progress_reset
  ok "Interrupted-install compiled-data cleanup complete."
}

resume_installation() {
  [[ -f "$RESUME_STATE" ]] || { fail "No preserved installation progress is available."; return 2; }
  local version="" action="" phase="" game="" steam_mode=""
  # File is written by DeckHelper itself with shell-escaped values.
  # shellcheck disable=SC1090
  source "$RESUME_STATE"
  [[ -n "${action:-}" ]] || { fail "Resume checkpoint is incomplete."; return 2; }
  [[ -n "${game:-}" && -f "$game" ]] || { fail "The game image used by the preserved installation is no longer available."; return 2; }
  printf '%s' "$game" > "$GAME_STATE"
  export WIICOMPILED_STEAM_MODE_SNAPSHOT="${steam_mode:-art}"
  say "Resuming preserved WiiCompiled installation"
  echo "Saved phase: ${phase:-unknown}"
  echo "Saved action: $action"
  echo "Saved game: $game"
  case "$action" in
    build-base) build_base ;;
    build-retro) build_retro ;;
    build-both) RESUMING_INSTALL=1 build_both ;;
    *) fail "Saved resume action is not supported: $action"; return 2 ;;
  esac
}

persist_retro_runtime() {
  [[ -d "$RETRO_DIR" ]] || { fail "Retro Rewind source folder disappeared before runtime assets could be installed: $RETRO_DIR"; return 1; }
  say "Installing persistent Retro Rewind runtime assets"
  mkdir -p "$RETRO_RUNTIME_PARENT"
  local staged="${RETRO_RUNTIME_DIR}.deckhelper-new"
  rm -rf -- "$staged"
  cp -a -- "$RETRO_DIR" "$staged" || { rm -rf -- "$staged"; fail "Could not copy Retro Rewind runtime assets into WiiCompiled's persistent data directory."; return 1; }
  [[ -d "$staged" ]] && find "$staged" -mindepth 1 -print -quit | grep -q . || { rm -rf -- "$staged"; fail "Staged Retro Rewind runtime folder is empty."; return 1; }
  rm -rf -- "$RETRO_RUNTIME_DIR"
  mv -- "$staged" "$RETRO_RUNTIME_DIR"
  [[ -f "$CONFIG_TOML" ]] || { fail "WiiCompiled Config.toml was not created by the Retro Rewind installer: $CONFIG_TOML"; return 1; }
  python3 - "$CONFIG_TOML" "$RETRO_RUNTIME_DIR" <<'PYTOML'
import json,re,sys
from pathlib import Path
p=Path(sys.argv[1]); runtime=sys.argv[2]; text=p.read_text(encoding='utf-8')
line='retro_rewind_root = '+json.dumps(runtime)
pat=re.compile(r'(?m)^\s*retro_rewind_root\s*=.*$')
if pat.search(text): text=pat.sub(line,text,count=1)
else:
    m=re.search(r'(?m)^\[paths\]\s*$',text)
    if m: text=text[:m.end()]+'\n'+line+text[m.end():]
    else: text=text.rstrip()+'\n\n[paths]\n'+line+'\n'
p.write_text(text,encoding='utf-8')
PYTOML
  verify_retro_runtime || { fail "Persistent Retro Rewind runtime path did not verify in Config.toml."; return 1; }
  ok "Retro Rewind runtime assets installed persistently: $RETRO_RUNTIME_DIR"
}

verify_retro_runtime() {
  [[ -d "$RETRO_RUNTIME_DIR" ]] || return 1
  [[ -f "$CONFIG_TOML" ]] || return 1
  find "$RETRO_RUNTIME_DIR" -mindepth 1 -print -quit | grep -q . || return 1
  python3 - "$CONFIG_TOML" "$RETRO_RUNTIME_DIR" <<'PYVERIFY'
import re,sys
from pathlib import Path
text=Path(sys.argv[1]).read_text(encoding='utf-8'); expected=sys.argv[2]
m=re.search(r'(?m)^\s*retro_rewind_root\s*=\s*["\']([^"\']+)["\']\s*$',text)
raise SystemExit(0 if m and m.group(1)==expected else 1)
PYVERIFY
}


set_steam_fullscreen_mode() {
  # RC20: real-Deck testing confirmed that video.display_mode="borderless"
  # makes both Base and Retro Rewind Steam shortcuts start fullscreen. Keep this
  # native persisted preference instead of synthesizing Alt+Enter or Gamescope.
  [[ -f "$CONFIG_TOML" ]] || { warn "Config.toml not found yet; fullscreen preference was not changed."; return 0; }
  python3 - "$CONFIG_TOML" <<'PYFULL'
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
line = 'display_mode = "borderless"'
pat = re.compile(r'(?m)^\s*display_mode\s*=.*$')
if pat.search(text):
    text = pat.sub(line, text, count=1)
else:
    section = re.search(r'(?m)^\[video\]\s*$', text)
    if section:
        text = text[:section.end()] + "\n" + line + text[section.end():]
    else:
        text = text.rstrip() + "\n\n[video]\n" + line + "\n"
p.write_text(text, encoding="utf-8")
PYFULL
  if grep -Eq '^[[:space:]]*display_mode[[:space:]]*=[[:space:]]*"borderless"[[:space:]]*$' "$CONFIG_TOML"; then
    ok "WiiCompiled Steam launch display mode set to borderless fullscreen."
  else
    warn "Could not verify borderless fullscreen in Config.toml."
  fi
}

find_steam_shortcuts_file() {
  local root="${HOME}/.local/share/Steam/userdata"
  [[ -d "$root" ]] || root="${HOME}/.steam/steam/userdata"
  [[ -d "$root" ]] || return 1

  local best=""
  best="$(find "$root" -mindepth 2 -maxdepth 3 -type f \
    \( -name shortcuts.vdf -o -name localconfig.vdf \) \
    -printf '%T@ %h\n' 2>/dev/null \
    | sort -nr | head -n1 | cut -d' ' -f2- || true)"

  [[ -n "$best" ]] || return 1
  printf '%s/shortcuts.vdf\n' "$best"
}

stop_steam_for_shortcut_edit() {
  if pgrep -x steam >/dev/null 2>&1 || pgrep -f '/steamwebhelper' >/dev/null 2>&1; then
    say "Restarting Steam to safely add the shortcut"
    echo "Steam must be stopped before editing shortcuts.vdf."
    steam -shutdown >/dev/null 2>&1 || true
    local n=0
    while (pgrep -x steam >/dev/null 2>&1 || pgrep -f '/steamwebhelper' >/dev/null 2>&1) && (( n < 30 )); do
      sleep 1
      ((n+=1))
    done
    if pgrep -x steam >/dev/null 2>&1; then
      fail "Steam did not close cleanly. Shortcut edit cancelled."
      return 1
    fi
  fi
  return 0
}

restart_steam_after_shortcut_edit() {
  # On Steam Deck Desktop Mode (KDE/Wayland), scripted Steam relaunches can
  # trigger Steam's PipeWire/xdg-desktop-portal screen-share chooser. The
  # shortcut/art files are already safely written at this point, so do not
  # relaunch Steam from the helper on Wayland. Steam will load the changes the
  # next time the user opens it or returns to Gaming Mode.
  if [[ -n "${WAYLAND_DISPLAY:-}" || "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    ok "Steam files updated."
    echo "Steam was left closed to avoid the Desktop Mode screen-share prompt."
    echo "Open Steam normally or return to Gaming Mode when ready."
    return 0
  fi

  if have steam; then
    (nohup steam >/dev/null 2>&1 &) || true
    ok "Steam restart requested."
  else
    warn "Steam command not found; start Steam manually."
  fi
}


verify_steam_shortcut_entry() {
  local appname="$1" exe="$2" vdf="$3"
  python3 - "$vdf" "$appname" "$exe" <<'PY'
import os, struct, sys
from pathlib import Path

vdf_path = Path(sys.argv[1])
appname = sys.argv[2]
exe = os.path.abspath(sys.argv[3])

if not vdf_path.exists() or not vdf_path.stat().st_size:
    raise SystemExit(1)

data = vdf_path.read_bytes()
TYPE_OBJ=0x00; TYPE_STR=0x01; TYPE_INT=0x02; TYPE_END=0x08

def read_cstr(data,pos):
    end=data.find(b'\0',pos)
    if end<0: raise ValueError
    return data[pos:end].decode("utf-8","replace"), end+1

def parse_obj(data,pos=0):
    out={}
    while pos < len(data):
        typ=data[pos]; pos+=1
        if typ==TYPE_END:
            return out,pos
        key,pos=read_cstr(data,pos)
        if typ==TYPE_OBJ:
            val,pos=parse_obj(data,pos)
        elif typ==TYPE_STR:
            val,pos=read_cstr(data,pos)
        elif typ==TYPE_INT:
            if pos+4>len(data): raise ValueError
            val=struct.unpack_from("<i",data,pos)[0]; pos+=4
        else:
            raise ValueError
        out[key]=val
    raise ValueError

root,_=parse_obj(data,0)
shortcuts=root.get("shortcuts",{})

def norm(s):
    return os.path.normpath(str(s).strip('"'))

for item in shortcuts.values():
    if not isinstance(item,dict):
        continue
    oldname=item.get("AppName", item.get("appname",""))
    oldexe=item.get("exe", item.get("Exe",""))
    if oldname == appname and oldexe and norm(oldexe) == norm(exe):
        raise SystemExit(0)

raise SystemExit(1)
PY
}

add_steam_shortcut() {
  local appname="$1" exe="$2" kind="${3:-base}"
  local startdir
  startdir="$(dirname "$exe")"

  [[ "$(steam_toggle)" == "on" ]] || return 0
  [[ -f "$exe" ]] || { fail "Compiled executable not found: $exe"; return 1; }

  set_steam_fullscreen_mode

  local vdf
  vdf="$(find_steam_shortcuts_file)" || {
    fail "Could not locate the current Steam user's config folder."
    return 1
  }

  if [[ "$STEAM_BATCH_MODE" -eq 1 ]]; then
    if [[ "$STEAM_BATCH_STOPPED" -eq 0 ]]; then
      stop_steam_for_shortcut_edit || return 1
      STEAM_BATCH_STOPPED=1
    fi
  else
    stop_steam_for_shortcut_edit || return 1
  fi

  say "Adding Steam shortcut: $appname"
  echo "Executable: $exe"
  echo "Steam VDF:  $vdf"

  local appid_state="$BASE_APPID_STATE"
  [[ "$kind" == "retro" ]] && appid_state="$RETRO_APPID_STATE"

  python3 - "$vdf" "$appname" "$exe" "$startdir" "$appid_state" <<'PY'
import sys, os, struct, shutil, time
from pathlib import Path

vdf_path = Path(sys.argv[1])
appname = sys.argv[2]
exe = os.path.abspath(sys.argv[3])
startdir = os.path.abspath(sys.argv[4])
appid_state = Path(sys.argv[5])

TYPE_OBJ=0x00; TYPE_STR=0x01; TYPE_INT=0x02; TYPE_END=0x08
class VDFError(Exception): pass

def read_cstr(data,pos):
    end=data.find(b'\0',pos)
    if end<0: raise VDFError("unterminated string")
    return data[pos:end].decode("utf-8","replace"), end+1

def parse_obj(data,pos=0):
    out={}
    while pos<len(data):
        typ=data[pos]; pos+=1
        if typ==TYPE_END: return out,pos
        key,pos=read_cstr(data,pos)
        if typ==TYPE_OBJ: val,pos=parse_obj(data,pos)
        elif typ==TYPE_STR: val,pos=read_cstr(data,pos)
        elif typ==TYPE_INT:
            if pos+4>len(data): raise VDFError("truncated int")
            val=struct.unpack_from("<i",data,pos)[0]; pos+=4
        else: raise VDFError(f"unsupported type 0x{typ:02x}")
        out[key]=val
    raise VDFError("object missing terminator")

def cstr(s): return str(s).encode("utf-8")+b"\0"

def write_obj(obj):
    b=bytearray()
    for k,v in obj.items():
        if isinstance(v,dict):
            b.append(TYPE_OBJ); b+=cstr(k); b+=write_obj(v)
        elif isinstance(v,int):
            b.append(TYPE_INT); b+=cstr(k); b+=struct.pack("<i",v)
        else:
            b.append(TYPE_STR); b+=cstr(k); b+=cstr(v)
    b.append(TYPE_END)
    return bytes(b)

root={}
if vdf_path.exists() and vdf_path.stat().st_size:
    raw=vdf_path.read_bytes()
    root,pos=parse_obj(raw,0)
shortcuts=root.setdefault("shortcuts",{})

def norm(s): return os.path.normpath(str(s).strip('"'))

target=None
for _,item in shortcuts.items():
    if not isinstance(item,dict): continue
    oldexe=item.get("exe",item.get("Exe",""))
    oldname=item.get("AppName",item.get("appname",""))
    if (oldexe and norm(oldexe)==norm(exe)) or oldname==appname:
        target=item; break

if target is None:
    numeric=[int(k) for k in shortcuts if str(k).isdigit()]
    key=str(max(numeric,default=-1)+1)
    target={}
    shortcuts[key]=target

import zlib
grid_id = (zlib.crc32((exe + appname).encode("utf-8")) | 0x80000000) & 0xffffffff
signed_appid = grid_id if grid_id < 0x80000000 else grid_id - 0x100000000

target["appid"]=signed_appid
target["AppName"]=appname
target["exe"]=f'"{exe}"'
target["StartDir"]=f'"{startdir}"'
target["icon"]=""
target["ShortcutPath"]=""
target["LaunchOptions"]=""
target["IsHidden"]=0
target["AllowDesktopConfig"]=1
target["AllowOverlay"]=1
target["openvr"]=0
target["Devkit"]=0
target["DevkitGameID"]=""
target["LastPlayTime"]=int(target.get("LastPlayTime",0) or 0)
target.setdefault("tags",{})

vdf_path.parent.mkdir(parents=True,exist_ok=True)
if vdf_path.exists():
    backup=vdf_path.with_name(f"shortcuts.vdf.deckhelper-backup-{int(time.time())}")
    shutil.copy2(vdf_path,backup)
    print(f"Backup: {backup}")

tmp=vdf_path.with_suffix(".vdf.deckhelper-tmp")
tmp.write_bytes(write_obj(root))
os.replace(tmp,vdf_path)
appid_state.parent.mkdir(parents=True,exist_ok=True)
appid_state.write_text(str(grid_id))
print(f"Shortcut written successfully. AppID: {grid_id}")
PY

  local rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "Steam shortcut write failed."
    [[ "$STEAM_BATCH_MODE" -eq 0 ]] && restart_steam_after_shortcut_edit
    return $rc
  fi

  # First-run safety check: parse the file back and make sure Steam's exact
  # shortcut record exists before we declare success.
  if ! verify_steam_shortcut_entry "$appname" "$exe" "$vdf"; then
    warn "Shortcut did not verify after the first write; retrying once."
    stop_steam_for_shortcut_edit || return 1

    python3 - "$vdf" "$appname" "$exe" "$startdir" "$appid_state" <<'PY'
import sys, os, struct, shutil, time, zlib
from pathlib import Path

vdf_path = Path(sys.argv[1])
appname = sys.argv[2]
exe = os.path.abspath(sys.argv[3])
startdir = os.path.abspath(sys.argv[4])
appid_state = Path(sys.argv[5])

TYPE_OBJ=0x00; TYPE_STR=0x01; TYPE_INT=0x02; TYPE_END=0x08
def read_cstr(data,pos):
    end=data.find(b'\0',pos)
    if end<0: raise ValueError("unterminated string")
    return data[pos:end].decode("utf-8","replace"), end+1
def parse_obj(data,pos=0):
    out={}
    while pos<len(data):
        typ=data[pos]; pos+=1
        if typ==TYPE_END: return out,pos
        key,pos=read_cstr(data,pos)
        if typ==TYPE_OBJ: val,pos=parse_obj(data,pos)
        elif typ==TYPE_STR: val,pos=read_cstr(data,pos)
        elif typ==TYPE_INT:
            if pos+4>len(data): raise ValueError("truncated int")
            val=struct.unpack_from("<i",data,pos)[0]; pos+=4
        else: raise ValueError(f"unsupported type 0x{typ:02x}")
        out[key]=val
    raise ValueError("missing terminator")
def cstr(s): return str(s).encode("utf-8")+b"\0"
def write_obj(obj):
    b=bytearray()
    for k,v in obj.items():
        if isinstance(v,dict):
            b.append(TYPE_OBJ); b+=cstr(k); b+=write_obj(v)
        elif isinstance(v,int):
            b.append(TYPE_INT); b+=cstr(k); b+=struct.pack("<i",v)
        else:
            b.append(TYPE_STR); b+=cstr(k); b+=cstr(v)
    b.append(TYPE_END); return bytes(b)

root={}
if vdf_path.exists() and vdf_path.stat().st_size:
    root,_=parse_obj(vdf_path.read_bytes(),0)
shortcuts=root.setdefault("shortcuts",{})

def norm(s): return os.path.normpath(str(s).strip('"'))
target=None
for item in shortcuts.values():
    if not isinstance(item,dict): continue
    oldexe=item.get("exe",item.get("Exe",""))
    oldname=item.get("AppName",item.get("appname",""))
    if (oldexe and norm(oldexe)==norm(exe)) or oldname==appname:
        target=item; break
if target is None:
    numeric=[int(k) for k in shortcuts if str(k).isdigit()]
    key=str(max(numeric,default=-1)+1)
    target={}; shortcuts[key]=target

grid_id=(zlib.crc32((exe+appname).encode("utf-8"))|0x80000000)&0xffffffff
signed_appid=grid_id if grid_id<0x80000000 else grid_id-0x100000000
target.update({
    "appid": signed_appid,
    "AppName": appname,
    "exe": f'"{exe}"',
    "StartDir": f'"{startdir}"',
    "icon": "",
    "ShortcutPath": "",
    "LaunchOptions": "",
    "IsHidden": 0,
    "AllowDesktopConfig": 1,
    "AllowOverlay": 1,
    "openvr": 0,
    "Devkit": 0,
    "DevkitGameID": "",
})
target["LastPlayTime"]=int(target.get("LastPlayTime",0) or 0)
target.setdefault("tags",{})

vdf_path.parent.mkdir(parents=True,exist_ok=True)
tmp=vdf_path.with_suffix(".vdf.deckhelper-tmp")
tmp.write_bytes(write_obj(root))
os.replace(tmp,vdf_path)
appid_state.parent.mkdir(parents=True,exist_ok=True)
appid_state.write_text(str(grid_id))
print(f"Shortcut rewrite completed. AppID: {grid_id}")
PY
    rc=$?
    if [[ $rc -ne 0 ]] || ! verify_steam_shortcut_entry "$appname" "$exe" "$vdf"; then
      fail "Steam shortcut could not be verified after retry."
      [[ "$STEAM_BATCH_MODE" -eq 0 ]] && restart_steam_after_shortcut_edit
      return 1
    fi
  fi

  ok "Steam shortcut written and verified."
  [[ "$STEAM_BATCH_MODE" -eq 0 ]] && restart_steam_after_shortcut_edit
  return 0
}

find_steam_grid_dir() {
  local vdf
  vdf="$(find_steam_shortcuts_file)" || return 1
  dirname "$vdf"
}

fetch_gametdb_cover() {
  local which="${1:-base}"
  local appid_state="$BASE_APPID_STATE"
  [[ "$which" == "retro" ]] && appid_state="$RETRO_APPID_STATE"

  [[ -f "$appid_state" ]] || {
    fail "Steam shortcut AppID is not known yet; add/build the Steam shortcut first."
    return 1
  }

  local appid grid_dir game_id="RMCP01"
  appid="$(cat "$appid_state")"
  grid_dir="$(find_steam_grid_dir)/grid"
  mkdir -p "$grid_dir"

  progress_local 8 "Looking up Wii cover on GameTDB"

  # RMCP01 is the verified PAL Mario Kart Wii disc ID. Prefer English PAL art,
  # then try common PAL-language fallbacks.
  local region url out=""
  for region in EN FR DE ES IT NL PT AU; do
    url="https://art.gametdb.com/wii/cover/${region}/${game_id}.png"
    out="${grid_dir}/${appid}p.png"
    if curl -fL --silent --show-error "$url" -o "${out}.tmp"; then
      if [[ -s "${out}.tmp" ]]; then
        mv -f "${out}.tmp" "$out"
        ok "GameTDB Wii cover installed (${region}, ${game_id})."
        progress_local 100 "GameTDB Wii cover installed"
        return 0
      fi
    fi
    rm -f "${out}.tmp"
  done

  fail "No GameTDB cover could be downloaded for ${game_id}."
  return 1
}

fetch_steamgriddb_artwork() {
  local which="${1:-both}"
  [[ -f "$SGDB_KEY_STATE" ]] || {
    fail "No SteamGridDB API key is saved."
    echo "Create one at SteamGridDB > Profile > Preferences > API."
    return 1
  }

  local key
  key="$(cat "$SGDB_KEY_STATE")"
  [[ -n "$key" ]] || { fail "SteamGridDB API key is empty."; return 1; }

  local grid_dir
  grid_dir="$(find_steam_grid_dir)/grid"
  mkdir -p "$grid_dir"

  progress_local 5 "Searching SteamGridDB artwork"

  python3 - "$key" "$grid_dir" "$which" "$BASE_APPID_STATE" "$RETRO_APPID_STATE" <<'PY'
import json, os, sys, urllib.parse, urllib.request
from pathlib import Path

key = sys.argv[1]
grid_dir = Path(sys.argv[2])
which = sys.argv[3]
base_state = Path(sys.argv[4])
retro_state = Path(sys.argv[5])
base_url = "https://www.steamgriddb.com/api/v2"
headers = {"Authorization": f"Bearer {key}", "User-Agent": "WiiCompiled-DeckHelper/0.2"}

targets = []
if which in ("base","both"):
    targets.append(("base", "Mario Kart Wii", base_state))
if which in ("retro","both"):
    targets.append(("retro", "Mario Kart: Retro Rewind", retro_state))

def api(path):
    req = urllib.request.Request(base_url + path, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))

def best_search(name):
    data = api("/search/autocomplete/" + urllib.parse.quote(name)).get("data", [])
    if not data:
        raise RuntimeError(f"No SteamGridDB game result for {name}")
    lname = name.lower()
    exact = [x for x in data if x.get("name","").lower() == lname]
    return (exact or data)[0]

def choose_asset(endpoint, gid, preferred_dims=None):
    qs = ""
    if preferred_dims:
        qs = "?dimensions=" + urllib.parse.quote(",".join(preferred_dims), safe=",x")
    data = api(f"/{endpoint}/game/{gid}{qs}").get("data", [])
    if not data:
        # Retry without dimension filter.
        data = api(f"/{endpoint}/game/{gid}").get("data", [])
    if not data:
        return None
    # API ordering is already useful; score is a decent tiebreaker.
    data.sort(key=lambda x: x.get("score", 0), reverse=True)
    return data[0].get("url")

def download(url, stem):
    if not url:
        return None
    ext = Path(urllib.parse.urlparse(url).path).suffix.lower()
    if ext not in (".png",".jpg",".jpeg",".webp"):
        ext = ".png"
    out = Path(str(stem) + ext)
    req = urllib.request.Request(url, headers={"User-Agent": headers["User-Agent"]})
    with urllib.request.urlopen(req, timeout=60) as r, open(out, "wb") as f:
        while True:
            chunk = r.read(1024*256)
            if not chunk:
                break
            f.write(chunk)
    if out.stat().st_size < 1024:
        out.unlink(missing_ok=True)
        raise RuntimeError(f"Downloaded artwork was unexpectedly small: {url}")
    return out

errors = []
for kind, title, appid_state in targets:
    if not appid_state.exists():
        errors.append(f"{title}: Steam shortcut AppID is not known yet; build/add the shortcut first.")
        continue
    appid = appid_state.read_text().strip()
    try:
        game = best_search(title)
        gid = game["id"]
        print(f"{title}: matched SteamGridDB '{game.get('name')}' (game {gid})")
        assets = {
            "portrait": choose_asset("grids", gid, ["600x900"]),
            "wide": choose_asset("grids", gid, ["920x430"]),
            "hero": choose_asset("heroes", gid, ["1920x620", "3840x1240"]),
            "logo": choose_asset("logos", gid),
            "icon": choose_asset("icons", gid),
        }
        mapping = {
            "portrait": grid_dir / f"{appid}p",
            "wide": grid_dir / f"{appid}",
            "hero": grid_dir / f"{appid}_hero",
            "logo": grid_dir / f"{appid}_logo",
            "icon": grid_dir / f"{appid}_icon",
        }
        for typ, url in assets.items():
            if not url:
                print(f"  {typ}: no asset found")
                continue
            p = download(url, mapping[typ])
            print(f"  {typ}: {p}")
    except Exception as e:
        errors.append(f"{title}: {e}")

if errors:
    print("Artwork issues:", file=sys.stderr)
    for e in errors:
        print(" - " + e, file=sys.stderr)
    sys.exit(1)
PY
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    progress_local 100 "Steam artwork installed"
    ok "SteamGridDB artwork installed."
  else
    fail "SteamGridDB artwork fetch/apply did not fully complete."
  fi
  return $rc
}

fetch_all_artwork() {
  local which="${1:-both}" rc=0
  progress_local 2 "Fetching GameTDB + SteamGridDB artwork"

  if [[ "$which" == "base" || "$which" == "both" ]]; then
    fetch_gametdb_cover "base" || rc=1
  fi
  if [[ "$which" == "retro" || "$which" == "both" ]]; then
    # Retro Rewind still launches the PAL MKWii base, so GameTDB can provide
    # the Wii-box portrait while SteamGridDB supplies mod-specific art.
    fetch_gametdb_cover "retro" || rc=1
  fi

  if [[ -s "$SGDB_KEY_STATE" ]]; then
    fetch_steamgriddb_artwork "$which" || rc=1
  else
    warn "No SteamGridDB key saved; GameTDB cover(s) applied, Steam-specific hero/logo/icon skipped."
  fi

  progress_local 100 "Artwork pass complete"
  return $rc
}

maybe_fetch_artwork() {
  local kind="$1"
  [[ "$(steam_mode)" == "art" ]] || return 0
  fetch_all_artwork "$kind"
}

verify_artwork_installed() {
  local kind="$1" appid_state="$BASE_APPID_STATE"
  [[ "$kind" == "retro" ]] && appid_state="$RETRO_APPID_STATE"
  [[ -s "$appid_state" ]] || { fail "Steam AppID state is missing for $kind artwork verification."; return 1; }
  local appid grid_dir found=0 f
  appid="$(cat "$appid_state")"
  grid_dir="$(find_steam_grid_dir)/grid" || return 1
  [[ -s "${grid_dir}/${appid}p.png" ]] || { fail "Required Steam portrait artwork was not installed for $kind (AppID $appid)."; return 1; }
  if [[ -s "$SGDB_KEY_STATE" ]]; then
    for f in "${grid_dir}/${appid}".* "${grid_dir}/${appid}_hero".* "${grid_dir}/${appid}_logo".* "${grid_dir}/${appid}_icon".*; do
      [[ -s "$f" ]] && { found=1; break; }
    done
    (( found == 1 )) || { fail "SteamGridDB key is configured, but no SGDB-specific artwork was installed for $kind."; return 1; }
  fi
  ok "Steam artwork verified for $kind."
}


repair_steam_integration() {
  local mode base_exe="" retro_exe="" rc=0
  mode="$(steam_mode)"

  if [[ "$mode" == "off" ]]; then
    warn "Steam integration is currently disabled."
    echo "Choose 'Add to Steam' in DeckHelper first."
    return 1
  fi

  progress_set 2 "Preparing Steam integration repair"
  say "Repairing Steam shortcuts and artwork"
  echo "No game compilation will be performed."

  # Prefer the known installer output paths, with a conservative executable
  # fallback for compatibility with nearby PR revisions.
  [[ -x "$INSTALL_ROOT/Base/WiiCompiled" ]] && base_exe="$INSTALL_ROOT/Base/WiiCompiled"
  [[ -x "$INSTALL_ROOT/RetroRewind/RetroRewind" ]] && retro_exe="$INSTALL_ROOT/RetroRewind/RetroRewind"

  if [[ -z "$base_exe" && -d "$INSTALL_ROOT/Base" ]]; then
    base_exe="$(find "$INSTALL_ROOT/Base" -maxdepth 2 -type f -perm -111 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$retro_exe" && -d "$INSTALL_ROOT/RetroRewind" ]]; then
    retro_exe="$(find "$INSTALL_ROOT/RetroRewind" -maxdepth 2 -type f -perm -111 2>/dev/null | head -n1 || true)"
  fi

  if [[ -z "$base_exe" && -z "$retro_exe" ]]; then
    fail "No existing WiiCompiled Base or Retro Rewind executable was found."
    return 1
  fi

  # Batch the edit so Steam is closed once, both shortcuts/artwork are written,
  # then Steam is restarted once.
  STEAM_BATCH_MODE=1
  STEAM_BATCH_STOPPED=0

  if [[ -n "$base_exe" ]]; then
    progress_set 15 "Adding Base shortcut to Steam"
    add_steam_shortcut "Mario Kart Wii - WiiCompiled" "$base_exe" "base" || rc=1
    if [[ $rc -eq 0 ]]; then
      progress_set 35 "Applying Base artwork"
      fetch_all_artwork "base" || rc=1
      [[ $rc -eq 0 ]] && verify_artwork_installed "base" || rc=1
    fi
  fi

  if [[ -n "$retro_exe" ]]; then
    progress_set 55 "Adding Retro Rewind shortcut to Steam"
    add_steam_shortcut "Retro Rewind - WiiCompiled" "$retro_exe" "retro" || rc=1
    if [[ $rc -eq 0 ]]; then
      progress_set 75 "Applying Retro Rewind artwork"
      fetch_all_artwork "retro" || rc=1
      [[ $rc -eq 0 ]] && verify_artwork_installed "retro" || rc=1
    fi
  fi

  if [[ "$STEAM_BATCH_STOPPED" -eq 1 ]]; then
    progress_set 92 "Finalizing Steam integration"
    restart_steam_after_shortcut_edit
  fi
  STEAM_BATCH_MODE=0
  STEAM_BATCH_STOPPED=0

  if [[ $rc -ne 0 ]]; then
    fail "Steam integration repair did not fully complete."
    return $rc
  fi

  progress_set 100 "Steam integration repaired"
  ok "Steam shortcuts and artwork repair complete."
}

build_base() {
  local game="" exe="${INSTALL_ROOT}/Base/WiiCompiled" rc=0
  game="$(require_game)" || return 1
  [[ -f "$ACTIVE_BASE_PREEXIST_STATE" ]] || prepare_build_transaction "build-base"
  mark_active_build "base-started"
  progress_local 2 "Preparing Base build"
  download_appimage || return 1
  progress_local 18 "Launching WiiCompiled Base compilation"
  say "Building Base Mario Kart Wii"
  echo "Game: $game"
  run_appimage_with_compile_progress 18 86 "Base compilation" install --game "$game" || rc=$?
  if (( rc != 0 )); then
    fail "WiiCompiled Base installer failed with exit code $rc. Work files were kept for diagnosis."
    return "$rc"
  fi
  progress_local 86 "Base compilation finished"
  require_installed_elf "$exe" "Base" || return 1
  mark_active_build "base-complete"
  say "Base build finished"
  if [[ "$(steam_toggle)" == "on" ]]; then
    progress_local 90 "Adding + verifying Base in Steam"
    add_steam_shortcut "Mario Kart Wii - WiiCompiled" "$exe" "base" || return 1
    progress_local 94 "Applying + verifying Base artwork"
    maybe_fetch_artwork "base" || return 1
    verify_artwork_installed "base" || return 1
  fi
  if [[ "$DEFER_CLEANUP" -eq 1 ]]; then
    :
  else
    cleanup_downloads
    rm -f "$RESUME_STATE"
    clear_active_build_markers
  fi
  progress_local 100 "Base build complete"
}

build_retro() {
  local game="" exe="${INSTALL_ROOT}/RetroRewind/RetroRewind" rc=0
  game="$(require_game)" || return 1
  [[ -f "$ACTIVE_RETRO_PREEXIST_STATE" ]] || prepare_build_transaction "build-retro"
  mark_active_build "retro-started"
  progress_local 2 "Preparing Retro Rewind build"
  download_appimage || return 1
  progress_local 15 "Downloading Retro Rewind"
  say "Preparing Retro Rewind"
  curl -fL --progress-bar "$RETRO_URL" -o "$RETRO_ZIP" || return 1
  rm -rf "$RETRO_EXTRACT"; mkdir -p "$RETRO_EXTRACT"
  unzip -q "$RETRO_ZIP" -d "$RETRO_EXTRACT" || return 1
  progress_local 28 "Retro Rewind extracted"
  [[ -d "$RETRO_DIR" ]] || { fail "Expected Retro Rewind folder not found: $RETRO_DIR"; return 1; }
  ok "Retro Rewind extracted."
  progress_local 35 "Launching Retro Rewind compilation"
  say "Building Retro Rewind"
  echo "Game: $game"
  run_appimage_with_compile_progress 35 84 "Retro Rewind compilation" install --game "$game" --retro-dir "$RETRO_DIR" --download-retro-wfc-payload || rc=$?
  if (( rc != 0 )); then
    fail "WiiCompiled Retro Rewind installer failed with exit code $rc. Work files were kept for diagnosis."
    return "$rc"
  fi
  progress_local 84 "Retro Rewind compilation finished"
  require_installed_elf "$exe" "Retro Rewind" || return 1
  progress_local 87 "Installing persistent Retro Rewind runtime assets"
  persist_retro_runtime || return 1
  mark_active_build "retro-complete"
  progress_local 90 "Retro Rewind runtime verified"
  say "Retro Rewind build finished"
  if [[ "$(steam_toggle)" == "on" ]]; then
    progress_local 92 "Adding + verifying Retro Rewind in Steam"
    add_steam_shortcut "Retro Rewind - WiiCompiled" "$exe" "retro" || return 1
    progress_local 96 "Applying + verifying Retro Rewind artwork"
    maybe_fetch_artwork "retro" || return 1
    verify_artwork_installed "retro" || return 1
  fi
  if [[ "$DEFER_CLEANUP" -eq 1 ]]; then
    :
  else
    cleanup_downloads
    rm -f "$RESUME_STATE"
    clear_active_build_markers
  fi
  progress_local 100 "Retro Rewind build complete"
}

build_both() {
  local game="" base_exe="${INSTALL_ROOT}/Base/WiiCompiled"
  game="$(require_game)" || return 1

  say "Build Both: Base + Retro Rewind"
  echo "Game: $game"
  echo "Steam integration: $(steam_mode_label)"

  if [[ "${RESUMING_INSTALL:-0}" == "1" && -f "$ACTIVE_BASE_PREEXIST_STATE" && -f "$ACTIVE_RETRO_PREEXIST_STATE" ]]; then
    say "Resume checkpoint accepted; preserving original transaction boundaries."
  else
    prepare_build_transaction "build-both"
  fi
  mark_active_build "build-both-started"
  DEFER_CLEANUP=1
  progress_set 1 "Starting Base + Retro Rewind build"
  if [[ "$(steam_toggle)" == "on" ]]; then
    STEAM_BATCH_MODE=1
    STEAM_BATCH_STOPPED=0
  fi

  PROGRESS_OFFSET=0
  PROGRESS_SCALE=48
  if base_install_valid; then
    say "Base installation already valid"
    ok "Skipping Base compilation and keeping the existing native WiiCompiled executable."
    mark_active_build "base-complete"
    progress_set 42 "Existing Base install verified · skipping recompilation"
    # A previous interrupted Build Both may have finished Base before Steam
    # integration. If Steam is requested now, repair Base's shortcut/artwork.
    if [[ "$(steam_toggle)" == "on" ]]; then
      progress_set 44 "Ensuring Base Steam shortcut + artwork"
      add_steam_shortcut "Mario Kart Wii - WiiCompiled" "$base_exe" "base" || { DEFER_CLEANUP=0; return 1; }
      maybe_fetch_artwork "base" || { DEFER_CLEANUP=0; return 1; }
      verify_artwork_installed "base" || { DEFER_CLEANUP=0; return 1; }
    fi
  else
    # If a stale/incomplete Base directory exists, remove only that invalid
    # target before asking upstream to build it again.
    if [[ -d "${INSTALL_ROOT}/Base" ]]; then
      warn "An incomplete Base installation was detected; replacing it."
      rm -rf -- "${INSTALL_ROOT}/Base"
    fi
    if ! build_base; then
      DEFER_CLEANUP=0
      if [[ "$STEAM_BATCH_STOPPED" -eq 1 ]]; then restart_steam_after_shortcut_edit; fi
      STEAM_BATCH_MODE=0
      STEAM_BATCH_STOPPED=0
      return 1
    fi
  fi

  PROGRESS_OFFSET=48
  PROGRESS_SCALE=48
  if retro_install_valid; then
    say "Retro Rewind installation already valid"
    ok "Retro Rewind is already complete; skipping recompilation."
    mark_active_build "retro-complete"
    progress_set 92 "Existing Retro Rewind install verified"
    if [[ "$(steam_toggle)" == "on" ]]; then
      add_steam_shortcut "Retro Rewind - WiiCompiled" "${INSTALL_ROOT}/RetroRewind/RetroRewind" "retro" || { DEFER_CLEANUP=0; return 1; }
      maybe_fetch_artwork "retro" || { DEFER_CLEANUP=0; return 1; }
      verify_artwork_installed "retro" || { DEFER_CLEANUP=0; return 1; }
    fi
  else
    if [[ -d "${INSTALL_ROOT}/RetroRewind" ]] && [[ "$(cat "$ACTIVE_RETRO_PREEXIST_STATE" 2>/dev/null || echo 0)" != "1" ]]; then
      warn "An incomplete Retro Rewind installation was detected; replacing it."
      rm -rf -- "${INSTALL_ROOT}/RetroRewind"
    fi
    if ! build_retro; then
      DEFER_CLEANUP=0
      if [[ "$STEAM_BATCH_STOPPED" -eq 1 ]]; then restart_steam_after_shortcut_edit; fi
      STEAM_BATCH_MODE=0
      STEAM_BATCH_STOPPED=0
      return 1
    fi
  fi

  if [[ "$STEAM_BATCH_STOPPED" -eq 1 ]]; then
    say "Finalizing Steam integration"
    restart_steam_after_shortcut_edit
  fi
  STEAM_BATCH_MODE=0
  STEAM_BATCH_STOPPED=0

  PROGRESS_OFFSET=0
  PROGRESS_SCALE=100
  progress_set 97 "Cleaning temporary files"
  DEFER_CLEANUP=0
  cleanup_downloads
  rm -f "$RESUME_STATE"
  clear_active_build_markers
  progress_set 100 "Base + Retro Rewind complete"

  say "Build Both finished"
  ok "Base and Retro Rewind completed successfully."
}

cleanup_downloads() {
  say "Cleaning temporary DeckHelper downloads"

  # Only remove DeckHelper-owned temporary files/folders.
  rm -f "$APPIMAGE" "$RETRO_ZIP"
  rm -rf "$RETRO_EXTRACT"

  # Keep both support logs. RC18 preserved the backend log but accidentally
  # unlinked the GUI's last-action.log while the active process still had it
  # open, leaving a successful install with no readable per-action transcript.
  if [[ -d "$WORKDIR" ]]; then
    find "$WORKDIR" -mindepth 1 -maxdepth 1 \
      ! -name "$(basename "$LOG")" \
      ! -name "$(basename "$ACTION_LOG")" \
      -exec rm -rf -- {} + 2>/dev/null || true
  fi

  ok "Temporary downloads cleared."
}

show_menu() {
  clear
  echo "============================================================"
  echo "             WiiCompiled DeckHelper"
  echo "============================================================"
  echo

  local game="" st=""
  game="$(current_game)"
  st="$(steam_toggle)"
  local sm=""
  sm="$(sudo_mode_label)"

  if [[ -n "$game" && -f "$game" ]]; then
    echo "Selected game: $game"
  elif [[ -n "$game" ]]; then
    echo "Selected game: $game  [MISSING]"
  else
    echo "Selected game: none"
  fi

  if [[ "$st" == "on" ]]; then
    echo "Add Steam Shortcut: ON"
  else
    echo "Add Steam Shortcut: OFF"
  fi
  echo "Dependency repair mode: $sm"
  [[ -f "$MII_SOURCE_STATE" ]] && echo "Detected Mii data: YES" || echo "Detected Mii data: NO"
  [[ -f "$SAVE_SOURCE_STATE" ]] && echo "Detected RR save: YES" || echo "Detected RR save: NO"

  echo
  echo "  1) Verify / Download Dependencies"
  echo "  2) Select Game File"
  echo "  3) Build Base"
  echo "  4) Build Retro Rewind"
  echo "  5) Build BOTH (Base + Retro Rewind)"
  echo "  S) Toggle Add Steam Shortcut ON/OFF"
  echo "  R) Cycle Dependency Repair Mode"
  echo "  I) Import Detected Save + Miis"
  echo "  0) Exit"
  echo
}

main() {
  exec > >(tee -a "$LOG") 2>&1

  startup_auto_detect

  while true; do
    show_menu
    local choice="" rc=0
    read -r -n 1 -s -p "Choose an option: " choice || true
    echo "$choice"

    case "$choice" in
      1)
        verify_dependencies && rc=0 || rc=$?
        [[ $rc -eq 0 ]] && short_status "[OK] Dependency verification finished." || wait_any_key
        ;;
      2)
        select_game && rc=0 || rc=$?
        if [[ $rc -eq 0 ]]; then short_status "[OK] Game selected."
        elif [[ $rc -eq 2 ]]; then sleep 0.5
        else wait_any_key
        fi
        ;;
      3)
        build_base && rc=0 || rc=$?
        [[ $rc -eq 0 ]] && short_status "[OK] Base build completed." || wait_any_key
        ;;
      4)
        build_retro && rc=0 || rc=$?
        [[ $rc -eq 0 ]] && short_status "[OK] Retro Rewind build completed." || wait_any_key
        ;;
      5)
        build_both && rc=0 || rc=$?
        [[ $rc -eq 0 ]] && short_status "[OK] Base + Retro Rewind builds completed." || wait_any_key
        ;;
      s|S)
        toggle_steam_shortcuts
        ;;
      r|R)
        cycle_sudo_mode
        ;;
      i|I)
        import_migration_data && rc=0 || rc=$?
        [[ $rc -eq 0 ]] && short_status "[OK] Save + Mii import finished." || wait_any_key
        ;;
      0|q|Q)
        cleanup_downloads
        echo "Goodbye."
        exit 0
        ;;
      *)
        echo "Invalid option."
        sleep 1
        ;;
    esac
  done
}



release_validation() {
  local report="${WORKDIR}/release-test-report.txt"
  local failures=0
  local game="" vdf="" mode="" base_exe="" retro_exe=""

  mkdir -p "$WORKDIR"
  : > "$report"

  report_line() {
    printf '%s\n' "$*" | tee -a "$report"
  }

  pass() {
    report_line "[PASS] $*"
  }

  failcheck() {
    report_line "[FAIL] $*"
    failures=$((failures + 1))
  }

  report_line "WiiCompiled DeckHelper Release Validation"
  report_line "Version: ${DECKHELPER_VERSION}"
  report_line "Maintainer: ${DECKHELPER_MAINTAINER}"
  report_line "Generated: $(date -Is 2>/dev/null || date)"
  report_line "Host: $(uname -a)"
  report_line ""

  progress_set 5 "Validating release package"

  [[ -x "${SCRIPT_DIR}/Wiicompile DeckHelper.sh" ]] \
    && pass "Backend is executable" \
    || failcheck "Backend is not executable"

  [[ -x "${SCRIPT_DIR}/WiiCompiled DeckHelper Launcher.sh" ]] \
    && pass "Launcher is executable" \
    || failcheck "Launcher is not executable"

  [[ -f "${SCRIPT_DIR}/WiiCompiled DeckHelper GUI.py" ]] \
    && pass "GUI source exists" \
    || failcheck "GUI source is missing"

  [[ -f "${SCRIPT_DIR}/WiiCompiled DeckHelper.desktop" ]] \
    && pass "Desktop launcher exists" \
    || failcheck "Desktop launcher is missing"

  for required_doc in README.md LICENSE THIRD-PARTY-NOTICES.md CHANGELOG.md; do
    [[ -f "${SCRIPT_DIR}/${required_doc}" ]] \
      && pass "${required_doc} exists" \
      || failcheck "${required_doc} is missing"
  done

  progress_set 15 "Checking script syntax"

  bash -n "${SCRIPT_DIR}/Wiicompile DeckHelper.sh" >/dev/null 2>&1 \
    && pass "Backend bash syntax passes" \
    || failcheck "Backend bash syntax failed"

  bash -n "${SCRIPT_DIR}/WiiCompiled DeckHelper Launcher.sh" >/dev/null 2>&1 \
    && pass "Launcher bash syntax passes" \
    || failcheck "Launcher bash syntax failed"

  python3 - "${SCRIPT_DIR}/WiiCompiled DeckHelper GUI.py" <<'PY' >/dev/null 2>&1
import ast, pathlib, sys
ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
PY
  [[ $? -eq 0 ]] \
    && pass "GUI Python syntax passes" \
    || failcheck "GUI Python syntax failed"

  progress_set 25 "Checking SteamOS dependencies"

  if dependency_probe >/dev/null 2>&1; then
    pass "Dependency probe passes"
  else
    failcheck "Dependency probe reports missing/pruned dependencies"
  fi

  progress_set 40 "Checking verified game"

  game="$(current_game)"
  if [[ -n "$game" && -f "$game" ]]; then
    pass "Selected game exists: $game"
  else
    failcheck "No selected game file is available"
  fi

  local measured_id="" measured_sha1="" measured_sha256="" measured_size="" measured_path=""
  [[ -f "$GAME_ID_STATE" ]] && measured_id="$(cat "$GAME_ID_STATE")"
  [[ -f "$GAME_SHA1_STATE" ]] && measured_sha1="$(cat "$GAME_SHA1_STATE")"
  [[ -f "$GAME_SHA256_STATE" ]] && measured_sha256="$(cat "$GAME_SHA256_STATE")"
  [[ -f "$GAME_SIZE_STATE" ]] && measured_size="$(cat "$GAME_SIZE_STATE")"
  [[ -f "$GAME_FINGERPRINT_PATH_STATE" ]] && measured_path="$(cat "$GAME_FINGERPRINT_PATH_STATE")"

  if [[ "$measured_path" == "$game" \
        && "$measured_id" == "$PAL_GAME_ID" \
        && "$measured_size" == "$PAL_ISO_SIZE" \
        && "$measured_sha1" == "$PAL_SHA1" \
        && "$measured_sha256" == "$PAL_SHA256" ]]; then
    pass "PAL RMCP01 fingerprint is verified"
  else
    failcheck "Selected game fingerprint is not currently verified"
  fi

  progress_set 55 "Checking native installs"

  base_exe="${INSTALL_ROOT}/Base/WiiCompiled"
  retro_exe="${INSTALL_ROOT}/RetroRewind/RetroRewind"

  if [[ -x "$base_exe" ]] && file -b "$base_exe" 2>/dev/null | grep -qE 'ELF .* executable'; then
    pass "Base native executable exists and is ELF"
  else
    failcheck "Base native executable is missing or invalid"
  fi

  if [[ -x "$retro_exe" ]] && file -b "$retro_exe" 2>/dev/null | grep -qE 'ELF .* executable'; then
    pass "Retro Rewind native executable exists and is ELF"
  else
    failcheck "Retro Rewind native executable is missing or invalid"
  fi

  if verify_retro_runtime; then
    pass "Retro Rewind runtime assets are persistent and Config.toml points to them"
  else
    failcheck "Retro Rewind runtime assets/config are not persistent"
  fi

  progress_set 70 "Checking Steam integration"

  mode="$(steam_mode)"
  report_line "Steam integration mode: $mode"

  if [[ "$mode" == "off" ]]; then
    failcheck "Steam integration is disabled; full RC validation expects Add to Steam"
  else
    if vdf="$(find_steam_shortcuts_file 2>/dev/null)" && [[ -f "$vdf" ]]; then
      pass "Steam shortcuts.vdf located: $vdf"

      verify_steam_shortcut_entry "Mario Kart Wii - WiiCompiled" "$base_exe" "$vdf" \
        && pass "Base Steam shortcut verifies" \
        || failcheck "Base Steam shortcut failed verification"

      verify_steam_shortcut_entry "Retro Rewind - WiiCompiled" "$retro_exe" "$vdf" \
        && pass "Retro Rewind Steam shortcut verifies" \
        || failcheck "Retro Rewind Steam shortcut failed verification"
    else
      failcheck "Steam shortcuts.vdf could not be located"
    fi
  fi

  progress_set 85 "Checking Steam artwork"

  local grid_dir=""
  if grid_dir="$(find_steam_grid_dir 2>/dev/null)"; then
    grid_dir="${grid_dir}/grid"
    local base_appid="" retro_appid=""
    [[ -f "$BASE_APPID_STATE" ]] && base_appid="$(cat "$BASE_APPID_STATE")"
    [[ -f "$RETRO_APPID_STATE" ]] && retro_appid="$(cat "$RETRO_APPID_STATE")"

    if [[ -n "$base_appid" ]] && compgen -G "${grid_dir}/${base_appid}*" >/dev/null; then
      pass "Base Steam artwork files exist"
    else
      failcheck "Base Steam artwork was not found"
    fi

    if [[ -n "$retro_appid" ]] && compgen -G "${grid_dir}/${retro_appid}*" >/dev/null; then
      pass "Retro Rewind Steam artwork files exist"
    else
      failcheck "Retro Rewind Steam artwork was not found"
    fi
  else
    failcheck "Steam grid artwork directory could not be located"
  fi

  progress_set 95 "Checking runtime state safety"

  [[ -w "$WORKDIR" ]] \
    && pass "Work directory is writable" \
    || failcheck "Work directory is not writable"

  [[ -w "$STATE_DIR" ]] \
    && pass "State directory is writable" \
    || failcheck "State directory is not writable"

  report_line ""
  if (( failures == 0 )); then
    report_line "RESULT: PASS"
    report_line "Full native Base + Retro Rewind + Steam integration validation passed."
    progress_set 100 "RC validation passed"
    return 0
  fi

  report_line "RESULT: FAIL (${failures} check(s))"
  progress_set 100 "RC validation failed"
  return 1
}


print_gui_status() {
  local game="" steam="" repair="" mii="NO" save="NO" verified="NO" sha256=""
  game="$(current_game)"
  steam="$(steam_toggle | tr '[:lower:]' '[:upper:]')"
  repair="$(sudo_mode_label)"
  [[ -f "$MII_SOURCE_STATE" ]] && mii="YES"
  [[ -f "$SAVE_SOURCE_STATE" ]] && save="YES"

  if [[ -n "$game" && -f "$game" ]]; then
    printf 'Game: %s\n' "$game"
  elif [[ -n "$game" ]]; then
    printf 'Game: MISSING (%s)\n' "$game"
  else
    printf 'Game: Not selected\n'
  fi

  local measured_id="" measured_sha1="" measured_sha256="" measured_size="" measured_path=""
  [[ -f "$GAME_ID_STATE" ]] && measured_id="$(cat "$GAME_ID_STATE")"
  [[ -f "$GAME_SHA1_STATE" ]] && measured_sha1="$(cat "$GAME_SHA1_STATE")"
  [[ -f "$GAME_SIZE_STATE" ]] && measured_size="$(cat "$GAME_SIZE_STATE")"
  [[ -f "$GAME_SHA256_STATE" ]] && measured_sha256="$(cat "$GAME_SHA256_STATE")"
  [[ -f "$GAME_FINGERPRINT_PATH_STATE" ]] && measured_path="$(cat "$GAME_FINGERPRINT_PATH_STATE")"
  sha256="$measured_sha256"

  # Normal state-file path.
  if [[ -f "$VERIFIED_GAME_STATE" ]] && [[ "$(cat "$VERIFIED_GAME_STATE")" == "$game" ]]; then
    verified="YES"
  fi

  # Recovery path: the fingerprint itself is authoritative. This avoids a GUI
  # false-negative if the tiny "verified path" state file failed to propagate,
  # was lost during an upgrade, or was written by an older revision.
  if [[ "$measured_path" == "$game"         && "$measured_id" == "$PAL_GAME_ID"         && "$measured_size" == "$PAL_ISO_SIZE"         && "$measured_sha1" == "$PAL_SHA1"         && "$measured_sha256" == "$PAL_SHA256" ]]; then
    verified="YES"
    # Repair the convenience state file while we're here.
    printf '%s' "$game" > "$VERIFIED_GAME_STATE"
  fi

  printf 'Game verified: %s\n' "$verified"
  printf 'Game ID: %s\n' "${measured_id:-$PAL_GAME_ID}"
  printf 'Game SHA1: %s\n' "$measured_sha1"
  printf 'Game size: %s\n' "$measured_size"
  printf 'Game SHA256: %s\n' "$sha256"
  printf 'Steam shortcuts: %s\n' "$steam"
  printf 'Steam integration mode: %s\n' "$(steam_mode_label)"
  printf 'Dependency repair: %s\n' "$repair"
  printf 'Retro Rewind save: %s\n' "$save"
  printf 'Mii data: %s\n' "$mii"
  [[ -f "$RESUME_STATE" ]] && printf 'Resume available: YES\n' || printf 'Resume available: NO\n'
  [[ -f "$SAVE_SOURCE_STATE" ]] && printf 'Retro Rewind source: %s\n' "$(cat "$SAVE_SOURCE_STATE")"
  [[ -f "$MII_SOURCE_STATE" ]] && printf 'Mii source: %s\n' "$(cat "$MII_SOURCE_STATE")"
}

action_requires_lock() {
  case "$1" in
    build-base|build-retro|build-both|resume-install|repair-steam|import|cleanup|cleanup-interrupted) return 0 ;;
    *) return 1 ;;
  esac
}

acquire_action_lock() {
  have flock || { fail "Required utility 'flock' is unavailable; refusing an unsafe concurrent action."; return 1; }
  exec 9>"$ACTION_LOCK"
  if ! flock -n 9; then
    fail "A WiiCompiled build is already running."
    return 73
  fi
}

acquire_cleanup_lock() {
  # The GUI calls cleanup immediately after terminating the active build.
  # The old build shell can need a moment to exit and release its flock, so a
  # non-blocking lock made RC16 silently skip cleanup while the lock was still
  # transiently held. Wait briefly instead; if it still cannot be acquired,
  # fail loudly rather than pretending cleanup succeeded.
  have flock || { fail "Required utility 'flock' is unavailable; refusing an unsafe cleanup."; return 1; }
  exec 9>"$ACTION_LOCK"
  if ! flock -w 15 9; then
    fail "Could not obtain the installer lock after waiting for the stopped build to exit. Compiled data was NOT deleted."
    return 73
  fi
}

run_action() {
  local action="${1:-}"
  local arg="${2:-}"
  exec > >(tee -a "$LOG") 2>&1

  if [[ "$action" == "cleanup-interrupted" ]]; then
    acquire_cleanup_lock || return $?
  elif action_requires_lock "$action"; then
    acquire_action_lock || return $?
  fi

  case "$action" in
    build-base|build-retro|build-both|resume-install|repair-steam)
      if [[ -n "${WIICOMPILED_STEAM_MODE_SNAPSHOT:-}" ]]; then
        echo "DeckHelper Steam integration snapshot: $(steam_mode_label)"
      fi
      ;;
  esac

  case "$action" in
    startup-detect) startup_auto_detect ;;
    scan-game) rescan_game_image ;;
    verify-selected) verify_selected_game ;;
    scan-migration) rescan_migration_data ;;
    dependency-probe) dependency_probe ;;
    verify) verify_dependencies ;;
    select) select_game ;;
    build-base) build_base ;;
    build-retro) build_retro ;;
    build-both) build_both ;;
    resume-install) resume_installation ;;
    repair-steam) repair_steam_integration ;;
    release-validation) release_validation ;;
    toggle-steam) toggle_steam_shortcuts ;;
    set-steam-mode) set_steam_mode "$arg" ;;
    cycle-sudo) cycle_sudo_mode ;;
    import) import_migration_data ;;
    status) print_gui_status ;;
    progress-status) [[ -f "$PROGRESS_STATE" ]] && cat "$PROGRESS_STATE" || echo "0|Ready" ;;
    set-sgdb-key) set_sgdb_key "$arg" ;;
    set-sgdb-auto) set_sgdb_auto_art "$arg" ;;
    fetch-gametdb-cover) fetch_gametdb_cover "${arg:-base}" ;;
    cleanup) cleanup_downloads ;;
    cleanup-interrupted) cleanup_interrupted_build "$arg" ;;
    *)
      echo "Unknown DeckHelper action: $action" >&2
      return 2
      ;;
  esac
}

if [[ "${1:-}" == "--action" ]]; then
  action="${2:-}"

  # Do NOT install a global EXIT cleanup trap here. The GUI calls short-lived
  # actions such as "progress-status" while a build is running; historically
  # their EXIT traps could delete the AppImage out from under the active build.
  #
  # Successful builds clean their own DeckHelper-owned temporary downloads.
  # Failed builds intentionally keep Work artifacts/logs around for diagnosis.
  run_action "$action" "${3:-}"
  exit $?
fi

main "$@"
