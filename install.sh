#!/bin/bash
set -euo pipefail

##
## install.sh
## Installs a Beatmania IIDX version on Linux with spicetools, bmsound and proton-ge
##

IIDX_BASE="/var/games/iidx"
AUTOMIZATION_DIR="$IIDX_BASE/automatization"
STEAM_HOME=""  # will be detected or prompted
STEAM_ROOT=""  # set after STEAM_HOME is resolved
REPO_URL="https://github.com/julianZ99/iidx-linux-installer"
UNINSTALL=0

## Colors
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[1;34m'
CYN='\033[0;36m'
MAG='\033[0;35m'
BLD='\033[1m'
RST='\033[0m'

## Distro / package manager - populated by detect_distro()
DISTRO_ID=""
DISTRO_NAME=""
PKG_MGR=""
PKG_QUERY=""
PKG_INSTALL=""

## Pagination state
PAGE_NAMES=(
    "Welcome"
    "Configuration"
    "Steam"
    "Monitor"
    "Versions"
    "Summary"
    "Dependencies"
    "User Groups"
    "Base Setup"
    "Proton-GE"
    "Binaries"
    "Game Setup"
    "Network"
    "Verification"
    "Launchers"
    "Patches"
    "Done"
)
TOTAL_PAGES=${#PAGE_NAMES[@]}

## Page history stack for back navigation
PAGE_HISTORY=()

## Cleanup on exit / interrupt
cleanup() {
    local rc=$?
    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
    exit "$rc"
}
trap cleanup EXIT

usage() {
    cat <<EOF
Usage: $0 [options]

Interactive setup wizard with no arguments required.
All values can be entered through the menu pages.
Use CLI flags to pre-fill values and skip prompts.

Options:
  --style          <NUM>   Game version number (e.g. 32)
  --dump           <PATH>  Path to game dump directory (must contain a contents/ folder)
  --monitor        <n>     Primary monitor name (e.g. DP-1). Game runs on this display.
  --secondary-monitor <n>  Optional. Secondary monitor name (e.g. HDMI-A-1).
                           Disabled during gameplay, restored after.
  --rate           <HZ>    Game refresh rate (default: 120)
  --proton-ver     <VER>   Proton-GE version (default: 8.32)
  --bmsound-ver    <VER>   bmsound_wine version (default: latest)
  --spice-date     <DATE>  spicetools date (default: latest)
  --steam-home     <PATH>  Steam root path (auto-detected)
  --uninstall              Remove all installed files and optionally revert system changes
  --asphyxia-url   <URL>   Asphyxia server URL
  --asphyxia-pcbid <ID>    Cabinet PCBID
  --yes, -y                Skip all confirmations
  -h, --help               Show this help

Examples:
  $0                                         # interactive mode
  $0 --style 32 --dump /mnt/disk/IIDX/LDJ-012-2025041500 --monitor DP-1
EOF
    exit 0
}

##
## Helpers
##

expand_path() {
    local path="$1"
    if [[ "$path" == \~/* ]]; then
        path="${HOME}${path:1}"
    fi
    echo "$path"
}

sanitize_str() {
    local s="$1"
    # Strip any char that is not alphanumeric, dash, underscore, colon, slash, dot
    echo "${s//[^a-zA-Z0-9_\-\.:\/]/}"
}

preflight_check() {
    detect_distro
    init_pkg_maps

    log "Distro: ${DISTRO_NAME} (${DISTRO_ID}) - package manager: ${PKG_MGR:-none}"
    if [ "$PKG_MGR" = "unknown" ] || [ -z "$PKG_MGR" ]; then
        warn "Distro '$DISTRO_ID' is not officially supported."
        warn "Automatic package installation will be skipped."
        local ok=0
        confirm "Continue anyway?" "n" || die "Aborting - unsupported distro"
    fi

    local required=(git wget curl tar jq patch make gcc)
    [ "$SESSION_TYPE" = "x11" ] && required+=(xrandr)
    local missing=()
    for cmd in "${required[@]}"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing required commands: ${missing[*]}"
    fi

    if ! sudo -v &>/dev/null; then
        die "sudo access is required but not available."
    fi

    if ! curl -sf "https://codeberg.org" >/dev/null 2>&1; then
        warn "Cannot reach codeberg.org - network may be unavailable."
        confirm "Continue anyway?" "n" || die "Aborting due to network check"
    fi
}

check_disk_space() {
    local path="$1"
    local needed_mb="$2"
    local label="${3:-$path}"
    local available_kb
    available_kb="$(df --output=avail "$path" 2>/dev/null | tail -1)" || return 0
    local available_mb=$((available_kb / 1024))
    if [ "$available_mb" -lt "$needed_mb" ]; then
        warn "Only ${available_mb}MB free on ${label}, need ${needed_mb}MB"
        confirm "Continue anyway?" "n" || die "Aborting - not enough disk space on ${label}"
    fi
}

detect_distro() {
    [ -f /etc/os-release ] && . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_NAME="${NAME:-$DISTRO_ID}"

    case "$DISTRO_ID" in
        arch)
            PKG_MGR="pacman"
            PKG_QUERY="pacman -Q"
            PKG_INSTALL="pacman -S"
            PKG_INSTALL_OPTS=(--needed)
            ;;
        debian|ubuntu)
            PKG_MGR="apt"
            PKG_QUERY="dpkg -l"
            PKG_INSTALL="apt install"
            PKG_INSTALL_OPTS=( )
            ;;
        fedora)
            PKG_MGR="dnf"
            PKG_QUERY="rpm -q"
            PKG_INSTALL="dnf install"
            PKG_INSTALL_OPTS=( )
            ;;
        *)
            # Fallback: detect by package manager binary
            if command -v pacman &>/dev/null; then
                PKG_MGR="pacman"
                PKG_QUERY="pacman -Q"
                PKG_INSTALL="pacman -S"
                PKG_INSTALL_OPTS=(--needed)
            elif command -v apt &>/dev/null; then
                PKG_MGR="apt"
                PKG_QUERY="dpkg -l"
                PKG_INSTALL="apt install"
                PKG_INSTALL_OPTS=( )
            elif command -v dnf &>/dev/null; then
                PKG_MGR="dnf"
                PKG_QUERY="rpm -q"
                PKG_INSTALL="dnf install"
                PKG_INSTALL_OPTS=( )
            else
                PKG_MGR="unknown"
                PKG_QUERY=""
                PKG_INSTALL=""
            fi
            ;;
    esac
}

init_pkg_maps() {
    # Must be called after detect_distro()
    case "$PKG_MGR" in
        apt)
            CMD_PKG=(
                [git]="git" [wget]="wget" [tar]="tar" [make]="make" [gcc]="gcc"
                [jq]="jq" [patch]="patch" [curl]="curl"
                [xrandr]="x11-xserver-utils"
                [pipewire]="pipewire" [ffmpeg]="ffmpeg"
                [pw-metadata]="pipewire"
            )
            PKG_CHECK=(
                [pipewire-pulse]="pipewire-pulse"
                [pipewire-jack]="pipewire-jack"
                [pipewire-alsa]="pipewire-alsa"
                [wireplumber]="wireplumber"
                [gst-plugin-pipewire]="gst-plugin-pipewire"
            )
            WINE_DEPS=(
                [libgnutls30]="libgnutls30:i386"
                [libldap]="libldap-2.5-2:i386"
                [libsqlite3]="libsqlite3-0:i386"
                [libpulse0]="libpulse0:i386"
                [alsa-plugins]="alsa-plugins:i386"
                [libmpg123]="libmpg123-0:i386"
                [liblcms2]="liblcms2-2:i386"
                [libjpeg-turbo8]="libjpeg-turbo8:i386"
                [libfreetype6]="libfreetype6:i386"
                [libdbus1]="libdbus-1-3:i386"
                [libvulkan1]="libvulkan1:i386"
                [mesa]="mesa:i386"
            )
            ;;
        dnf)
            CMD_PKG=(
                [git]="git" [wget]="wget" [tar]="tar" [make]="make" [gcc]="gcc"
                [jq]="jq" [patch]="patch" [curl]="curl"
                [xrandr]="xorg-x11-xrandr"
                [pipewire]="pipewire" [ffmpeg]="ffmpeg"
                [pw-metadata]="pipewire"
            )
            PKG_CHECK=(
                [pipewire-pulse]="pipewire-pulse"
                [pipewire-jack]="pipewire-jack"
                [pipewire-alsa]="pipewire-alsa"
                [wireplumber]="wireplumber"
            )
            WINE_DEPS=(
                [gnutls]="gnutls.i686"
                [openldap]="openldap.i686"
                [sqlite]="sqlite.i686"
                [pulseaudio-libs]="pulseaudio-libs.i686"
                [alsa-plugins-pulseaudio]="alsa-plugins-pulseaudio.i686"
                [mpg123]="mpg123.i686"
                [lcms2]="lcms2.i686"
                [libjpeg-turbo]="libjpeg-turbo.i686"
                [freetype]="freetype.i686"
                [dbus-libs]="dbus-libs.i686"
                [vulkan-loader]="vulkan-loader.i686"
                [mesa-libGL]="mesa-libGL.i686"
                [mesa-dri-drivers]="mesa-dri-drivers.i686"
            )
            ;;
        pacman|*)
            CMD_PKG=(
                [git]="git" [wget]="wget" [tar]="tar" [make]="make" [gcc]="gcc"
                [jq]="jq" [patch]="patch" [curl]="curl"
                [xrandr]="xorg-xrandr"
                [pipewire]="pipewire" [ffmpeg]="ffmpeg"
                [pw-metadata]="pipewire"
            )
            PKG_CHECK=(
                [pipewire-pulse]="pipewire-pulse"
                [pipewire-jack]="pipewire-jack"
                [pipewire-alsa]="pipewire-alsa"
                [wireplumber]="wireplumber"
                [gst-plugin-pipewire]="gst-plugin-pipewire"
            )
            WINE_DEPS=(
                [lib32-gnutls]="lib32-gnutls"
                [lib32-libldap]="lib32-libldap"
                [lib32-sqlite]="lib32-sqlite"
                [lib32-libpulse]="lib32-libpulse"
                [lib32-alsa-plugins]="lib32-alsa-plugins"
                [lib32-mpg123]="lib32-mpg123"
                [lib32-lcms2]="lib32-lcms2"
                [lib32-libjpeg-turbo]="lib32-libjpeg-turbo"
                [lib32-freetype2]="lib32-freetype2"
                [lib32-dbus]="lib32-dbus"
                [lib32-vulkan-icd-loader]="lib32-vulkan-icd-loader"
                [lib32-mesa]="lib32-mesa"
            )
            ;;
    esac
    [ "$SESSION_TYPE" != "x11" ] && unset CMD_PKG[xrandr]
}

##
## UI helpers
##

draw_header() {
    local page_idx="$1"
    local page_name="${PAGE_NAMES[$page_idx]}"
    local term_width
    term_width="$(tput cols 2>/dev/null || echo 80)"

    clear

    _CURRENT_TERM_WIDTH="$term_width"

    # ASCII art
    echo -e "${MAG}${BLD}"
    echo "▄█ ▄█ ██▄      ▄      █    ▄█    ▄     ▄       ▄      ▄█    ▄      ▄▄▄▄▄      ▄▄▄▄▀ ██   █     ▄███▄   █▄▄▄▄ "
    echo "██ ██ █  █ ▀▄   █     █    ██     █     █  ▀▄   █     ██     █    █     ▀▄ ▀▀▀ █    █ █  █     █▀   ▀  █  ▄▀ "
    echo "██ ██ █   █  █ ▀      █    ██ ██   █ █   █   █ ▀      ██ ██   █ ▄  ▀▀▀▀▄       █    █▄▄█ █     ██▄▄    █▀▀▌  "
    echo "▐█ ▐█ █  █  ▄ █       ███▄ ▐█ █ █  █ █   █  ▄ █       ▐█ █ █  █  ▀▄▄▄▄▀       █     █  █ ███▄  █▄   ▄▀ █  █  "
    echo " ▐  ▐ ███▀ █   ▀▄         ▀ ▐ █  █ █ █▄ ▄█ █   ▀▄      ▐ █  █ █              ▀         █     ▀ ▀███▀     █   "
    echo "            ▀                 █   ██  ▀▀▀   ▀            █   ██                       █                 ▀    "
    echo "                                                                                     ▀ "
    echo -e "${RST}"
    echo ""

    # Divider: header ↔ navbar
    local div=""
    for ((i=0; i<term_width; i++)); do div="${div}─"; done
    echo -e "${BLU}${div}${RST}"

    # Step label (centered)
    local page_label="Step $((page_idx + 1)) / $TOTAL_PAGES - $page_name"
    local label_len=${#page_label}
    local label_pad=$(( (term_width - label_len) / 2 ))
    local lp=""
    for ((i=0; i<label_pad; i++)); do lp="$lp "; done
    echo -e "${lp}${CYN}${BLD}${page_label}${RST}"

    # Progress bar (centered)
    local bar_width=40
    local filled=$(( (page_idx * bar_width) / (TOTAL_PAGES - 1) ))
    local bar="${GRN}"
    for ((i=0; i<filled; i++)); do bar="${bar}█"; done
    bar="${bar}${YLW}"
    for ((i=filled; i<bar_width; i++)); do bar="${bar}░"; done
    bar="${bar}${RST}"
    local bar_pad=$(( (term_width - bar_width) / 2 ))
    local bp=""
    for ((i=0; i<bar_pad; i++)); do bp="$bp "; done
    echo -e "${bp}${bar}"

    # Nav hint (centered, same width reference as bar)
    local hint="b=back  q=quit  Enter=continue"
    local hint_len=${#hint}
    local hint_pad=$(( (term_width - hint_len) / 2 ))
    local hp=""
    for ((i=0; i<hint_pad; i++)); do hp="$hp "; done
    echo -e "${hp}${YLW}b${RST}=back  ${YLW}q${RST}=quit  ${YLW}Enter${RST}=continue"

    # Divider: navbar ↔ content
    echo -e "${BLU}${div}${RST}"
    echo ""
}

page_footer() {
    # Footer is now just a closing divider - navbar is in the header
    local term_width="${_CURRENT_TERM_WIDTH:-80}"
    echo ""
    local div=""
    for ((i=0; i<term_width; i++)); do div="${div}─"; done
    echo -e "${BLU}${div}${RST}"
}

read_nav() {
    local input
    while true; do
        echo -en "\n${YLW}[?]${RST} Press ${BLD}Enter${RST} to continue, ${BLD}b${RST} to go back, ${BLD}q${RST} to quit: "
        read -r input
        case "${input,,}" in
            "") return 0 ;;
            b)  return 1 ;;
            q)  echo "Aborted."; exit 0 ;;
            *)  echo "  Enter=continue  b=back  q=quit" ;;
        esac
    done
}

pop_page() {
    if [ ${#PAGE_HISTORY[@]} -gt 0 ]; then
        unset 'PAGE_HISTORY[-1]'
    fi
}

log()     { echo -e "${BLU}[INFO]${RST} $*"; }
warn()    { echo -e "${YLW}[WARN]${RST} $*"; }
die()     { echo -e "${RED}[ERROR]${RST} $*"; exit 1; }
success() { echo -e "${GRN}[OK]${RST} $*"; }

download_file() {
    # download_file "label" "url" "dest"
    local label="$1"
    local url="$2"
    local dest="$3"

    echo -e "  ${BLU}↓${RST} ${BLD}${label}${RST}"
    wget -q --show-progress "$url" -O "$dest"
    success "$label downloaded"
}

confirm() {
    local msg="$1"
    local default="${2:-y}"
    if [ "$AUTO_YES" = "1" ]; then return 0; fi
    local prompt
    [ "$default" = "y" ] && prompt="[Y/n]" || prompt="[y/N]"
    while true; do
        echo -en "${YLW}[?]${RST} $msg $prompt "
        read -r answer
        answer="${answer:-$default}"
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            b) return 2 ;;
            q) echo "Aborted."; exit 0 ;;
            *) echo "  Please answer y/n  b=back  q=quit" ;;
        esac
    done
}

prompt_value() {
    # prompt_value "label" VARNAME [default] [example]
    local msg="$1"
    local varname="$2"
    local default="$3"
    local example="$4"
    local current="${!varname}"
    if [ -n "$current" ]; then return; fi
    default="$(expand_path "${default:-}")"
    local hint=""
    [ -n "$default" ] && hint=" ${BLU}(default: $default)${RST}"
    [ -n "$example" ] && hint="$hint ${BLU}e.g. $example${RST}"
    while true; do
        echo -en "${CYN}[?]${RST} $msg$hint: "
        read -r value
        case "${value,,}" in
            b) return 1 ;;
            q) echo "Aborted."; exit 0 ;;
        esac
        value="${value:-$default}"
        value="$(expand_path "$value")"
        if [ -n "$value" ]; then
            printf -v "$varname" '%s' "$value"
            return 0
        fi
        echo "  Value required.  b=back  q=quit"
    done
}

##
## Arguments
##
GAME_STYLE=""
DUMP_PATH=""
MONITOR=""
SECONDARY_MONITOR=""
BMSOUND_VER=""
SPICE_DATE=""
PROTON_VER="8.32"
GAME_RATE=""
GAME_RES=""
ASPHYXIA_URL=""
ASPHYXIA_PCBID=""
AUTO_YES=0
SESSION_TYPE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --style)              GAME_STYLE="$2";           shift 2 ;;
        --dump)               DUMP_PATH="${2%/}";         shift 2 ;;
        --monitor)            MONITOR="$2";               shift 2 ;;
        --secondary-monitor)  SECONDARY_MONITOR="$2";    shift 2 ;;
        --bmsound-ver)        BMSOUND_VER="$2";           shift 2 ;;
        --spice-date)         SPICE_DATE="$2";            shift 2 ;;
        --proton-ver)         PROTON_VER="$2";            shift 2 ;;
        --rate)               GAME_RATE="$2";             shift 2 ;;
        --asphyxia-url)       ASPHYXIA_URL="$2";          shift 2 ;;
        --asphyxia-pcbid)     ASPHYXIA_PCBID="$2";        shift 2 ;;
        --steam-home)         STEAM_HOME="${2%/}";        shift 2 ;;
        --uninstall)          UNINSTALL=1;                shift   ;;
        --yes|-y)             AUTO_YES=1;                 shift   ;;
        -h|--help)            usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# Expand ~ in CLI-provided paths
STEAM_HOME="$(expand_path "$STEAM_HOME")"
DUMP_PATH="$(expand_path "$DUMP_PATH")"

# Validate arguments
if [ -n "$GAME_STYLE" ] && ! [[ "$GAME_STYLE" =~ ^[0-9]+$ ]]; then
    die "--style must be a number, got: '$GAME_STYLE'"
fi
if [ -n "$DUMP_PATH" ] && [ ! -d "$DUMP_PATH" ]; then
    die "Dump path does not exist: $DUMP_PATH"
fi
if [ -n "$GAME_RATE" ] && ! [[ "$GAME_RATE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    die "--rate must be a number, got: '$GAME_RATE'"
fi

##
## Version fetchers
##
fetch_latest_bmsound() {
    curl -sf "https://codeberg.org/nixac/bmsound_wine/releases" 2>/dev/null \
        | grep -oP 'releases/tag/\K[^"]+' \
        | head -1 || echo ""
}

fetch_latest_spice_date() {
    curl -sf "https://codeberg.org/nixac/spicetools/releases" 2>/dev/null \
        | grep -oP 'releases/tag/\Kv[^_"]+_\K[0-9]{4}-[0-9]{2}-[0-9]{2}' \
        | head -1 || echo ""
}

detect_steam_home() {
    # Search all known locations, deduplicate by real path.
    # Only real Steam installations (with steam.sh), not library folders.
    local candidates=(
        "$HOME/.steam/steam"
        "$HOME/.steam/root"
        "$HOME/.local/share/Steam"
        "$HOME/.steam"
        "/var/lib/steam"
    )

    declare -A seen_real
    local found=()

    for path in "${candidates[@]}"; do
        local real
        real="$(realpath "$path" 2>/dev/null)" || continue
        [ -d "$real/steamapps" ] || continue
        [ -f "$real/steam.sh" ] || continue  # real installation, not library
        [ -z "${seen_real[$real]+x}" ] || continue
        seen_real["$real"]=1
        found+=("$path")
    done

    printf '%s\n' "${found[@]}"
}

detect_resolution() {
    xrandr 2>/dev/null | grep "^$MONITOR " -A1 | grep -oP '\d+x\d+(?=\+0\+0)' | head -1 || true
}

detect_rate() {
    xrandr 2>/dev/null | grep "^$MONITOR " | grep -oP '\d+\.\d+(?=\*)' | head -1 || true
}

detect_compositor() {
    local stype="${XDG_SESSION_TYPE:-x11}"
    case "$stype" in
        wayland)
            if command -v hyprctl &>/dev/null && hyprctl monitors &>/dev/null 2>&1; then
                echo "hyprland"
                return
            fi
            # future: swaymsg, niri msg
            echo "wayland-unknown" ;;
        *) echo "x11" ;;
    esac
}

## Hyprland-specific monitor helpers
list_monitors_hyprland() {
    hyprctl monitors all 2>/dev/null | grep "^Monitor " | awk '{print $2}'
}
monitor_res_hyprland() {
    hyprctl monitors all 2>/dev/null | grep -A1 "^Monitor $1 " | tail -1 | grep -oP '\d+x\d+(?=@)' || true
}
monitor_rate_hyprland() {
    hyprctl monitors all 2>/dev/null | grep -A1 "^Monitor $1 " | tail -1 | grep -oP '@\K[\d.]+' || true
}
monitor_disable_hyprland() {
    hyprctl keyword monitor "$1,disable"
}
monitor_enable_hyprland() {
    hyprctl keyword monitor "$1,preferred,auto,1"
}

##
## Package maps - populated by init_pkg_maps()
##
declare -A CMD_PKG
declare -A PKG_CHECK
declare -A WINE_DEPS

declare -A GROUP_DESC=(
    [games]="required - access to /var/games"
    [input]="required - controller/peripheral input"
    [realtime]="recommended - low-latency audio scheduling"
    [audio]="recommended - audio device access"
)

##
## Pages
##

page_intro() {
    draw_header 0
    echo -e "  ${BLD}What this installer does:${RST}
"
    echo -e "  This script automates the full setup of Beatmania IIDX on Linux, including:"
    echo -e "    •  Downloading and patching ${BLD}Proton-GE${RST} (dedicated per game version)"
    echo -e "    •  Building ${BLD}bmsound_wine${RST} - audio bridge between spice and PipeWire"
    echo -e "    •  Installing ${BLD}spicetools${RST} - the launcher and I/O layer for IIDX"
    echo -e "    •  Setting up symlinks, prefixes and Steam compatibility data"
    echo -e "    •  Creating ${BLD}.desktop${RST} entries for your launcher"
    echo -e "    •  Optionally configuring ${BLD}Asphyxia${RST} local network server
"

    echo -e "  ${BLD}System:${RST} ${DISTRO_NAME} - ${PKG_MGR:-no package manager detected}
"
    echo -e "  ${YLW}${BLD}Warnings and requirements:${RST}
"
    if [ "$PKG_MGR" != "pacman" ]; then
        echo -e "    ${YLW}!${RST}  ${BLD}Arch Linux is the primary target${RST} - other distros may need manual steps"
    fi
    echo -e "    ${YLW}!${RST}  You must have a ${BLD}legal dump${RST} of the game - this script does not provide one"
    echo -e "    ${YLW}!${RST}  ${BLD}Steam${RST} must be installed - the script uses its runtime and compatdata"
    echo -e "    ${YLW}!${RST}  ${BLD}sudo${RST} access is required for group and directory setup"
    echo -e "    ${YLW}!${RST}  Some steps download large files (~500MB) - ensure a stable connection"
    echo -e "    ${YLW}!${RST}  A ${BLD}relogin may be required${RST} after group changes (controller, audio)
"

    echo -e "  ${BLD}Credits:${RST}
"
    echo -e "    This installer is a wrapper around tools and guides by ${BLD}nixac${RST}:"
    echo -e "    ${CYN}https://nixac.codeberg.page${RST}     - setup guide and documentation"
    echo -e "    ${CYN}https://codeberg.org/nixac/automatization${RST}  - proton patches & wrappers"
    echo -e "    ${CYN}https://codeberg.org/nixac/spicetools${RST}       - IIDX launcher (spice fork)"
    echo -e "    ${CYN}https://codeberg.org/nixac/bmsound_wine${RST}     - PipeWire audio bridge"
    echo ""
    echo -e "    Proton-GE by ${BLD}GloriousEggroll${RST}: ${CYN}https://github.com/GloriousEggroll/proton-ge-custom${RST}"
    echo ""
    warn "This installer is unofficial. Always refer to the upstream guide for authoritative info."

    page_footer
    read_nav || { pop_page; return; }
}

page_configuration() {
    draw_header 1
    echo -e "  Configure the game version and dump path.\n"

    while true; do
        prompt_value "Game style/version" GAME_STYLE "" "32" || { GAME_STYLE=""; pop_page; return; }
        if [[ "$GAME_STYLE" =~ ^[0-9]+$ ]]; then
            break
        fi
        warn "Game style must be a number, got: $GAME_STYLE"
        GAME_STYLE=""
    done

    if [ -z "$DUMP_PATH" ]; then
        while true; do
            prompt_value "Path to game dump" DUMP_PATH "" "/mnt/disk/IIDX/LDJ-012-2025041500" || { DUMP_PATH=""; pop_page; return; }
            if [ -d "$DUMP_PATH/contents" ]; then
                success "Dump found at: $DUMP_PATH"
                break
            elif [ -d "$DUMP_PATH" ]; then
                warn "Path exists but no 'contents/' subdirectory found"
                DUMP_PATH=""
            else
                warn "Path not found: $DUMP_PATH"
                DUMP_PATH=""
            fi
        done
    else
        success "Dump: $DUMP_PATH"
    fi

    page_footer
    read_nav || { pop_page; return; }
}

page_steam() {
    draw_header 2

    if [ -n "$STEAM_HOME" ]; then
        success "Steam already set: $STEAM_HOME"
        page_footer
        read_nav || { pop_page; return; }
        return
    fi

    echo -e "  Scanning for Steam installations...\n"
    local detected_raw
    detected_raw="$(detect_steam_home)"

    local found_list=()
    while IFS= read -r line; do
        [ -n "$line" ] && found_list+=("$line")
    done <<< "$detected_raw"

    if [ ${#found_list[@]} -eq 0 ]; then
        warn "No Steam installation found automatically."
        echo -e "  Common locations: ~/.steam/steam  ~/.local/share/Steam\n"
        prompt_value "Steam root path (where steamapps/ lives)" STEAM_HOME "" "~/.steam/steam" || { pop_page; return; }

    elif [ ${#found_list[@]} -eq 1 ]; then
        success "Found: ${found_list[0]}"
        echo ""
        local ret=0
        confirm "Use this Steam installation?" "y" || ret=$?
        if [ $ret -eq 0 ]; then
            STEAM_HOME="${found_list[0]}"
        elif [ $ret -eq 2 ]; then
            pop_page; return
        else
            prompt_value "Steam root path (where steamapps/ lives)" STEAM_HOME "" "~/.steam/steam" || { pop_page; return; }
        fi

    else
        log "Found ${#found_list[@]} Steam installations:"
        echo ""
        local i
        for i in "${!found_list[@]}"; do
            local acf_count
            acf_count="$(ls "${found_list[$i]}/steamapps"/appmanifest_*.acf 2>/dev/null | wc -l)"
            echo -e "    ${CYN}$((i+1))${RST}  ${found_list[$i]}  ${BLU}(${acf_count} games)${RST}"
        done
        echo ""
        local choice=""
        while true; do
            echo -en "${CYN}[?]${RST} Select installation [1-${#found_list[@]}], or type a custom path: "
            read -r choice
            case "${choice,,}" in
                b) pop_page; return ;;
                q) echo "Aborted."; exit 0 ;;
            esac
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#found_list[@]}" ]; then
                STEAM_HOME="${found_list[$((choice-1))]}"
                break
            elif [ -d "$choice/steamapps" ]; then
                STEAM_HOME="$choice"
                break
            else
                warn "Invalid selection. Enter a number or a valid path."
            fi
        done
        success "Selected: $STEAM_HOME"
    fi

    if [ ! -d "$STEAM_HOME/steamapps" ]; then
        warn "No steamapps/ found at $STEAM_HOME"
        STEAM_HOME=""
        page_footer
        read_nav || { pop_page; return; }
        return
    fi

    STEAM_ROOT="$AUTOMIZATION_DIR/.steam/root"
    success "Using Steam at: $STEAM_HOME"

    page_footer
    read_nav || { STEAM_HOME=""; pop_page; return; }
}

page_monitor() {
    draw_header 3
    echo -e "  Configure your monitor setup.\n"

    if [ -z "$MONITOR" ]; then
        echo -e "  ${BLD}Connected monitors:${RST}"
        case "$SESSION_TYPE" in
            hyprland)
                list_monitors_hyprland | awk '{print "    " NR ") " $0}'
                echo ""
                while true; do
                    prompt_value "Primary monitor name" MONITOR "" "DP-1" || { MONITOR=""; pop_page; return; }
                    if hyprctl monitors all 2>/dev/null | grep -q "^Monitor $MONITOR "; then
                        break
                    fi
                    warn "Monitor '$MONITOR' not found. Use a name from the list above."
                    MONITOR=""
                done
                ;;
            x11)
                xrandr 2>/dev/null | grep " connected" | awk '{print "    " NR ") " $1 " - " $3}'
                echo ""
                while true; do
                    prompt_value "Primary monitor name" MONITOR "" "DP-1" || { MONITOR=""; pop_page; return; }
                    if xrandr 2>/dev/null | grep -q "^$MONITOR "; then
                        break
                    fi
                    warn "Monitor '$MONITOR' not found. Use a name from the list above."
                    MONITOR=""
                done
                ;;
            *)
                warn "Unknown session '$SESSION_TYPE' - cannot auto-detect monitors."
                prompt_value "Primary monitor name" MONITOR "" "DP-1" || { MONITOR=""; pop_page; return; }
                ;;
        esac
    else
        success "Primary monitor: $MONITOR"
    fi

    if [ -z "$SECONDARY_MONITOR" ]; then
        local others=""
        case "$SESSION_TYPE" in
            hyprland)
                others="$(list_monitors_hyprland | grep -v "^${MONITOR}$" || true)"
                ;;
            x11)
                others="$(xrandr 2>/dev/null | grep " connected" | awk '{print $1}' | grep -v "^${MONITOR}$" || true)"
                ;;
        esac
        if [ -n "$others" ]; then
            echo ""
            echo -e "  Other connected monitors: ${BLD}$(echo "$others" | tr '\n' ' ')${RST}"
            warn "Multi-monitor setups can cause incorrect framerate in IIDX."
            case "$SESSION_TYPE" in
                hyprland|x11)
                    warn "The secondary monitor will be disabled while the game runs."
                    ;;
            esac
            echo ""
            local ret=0
            confirm "Disable secondary monitor during gameplay?" "y" || ret=$?
            if [ $ret -eq 0 ]; then
                prompt_value "Secondary monitor name" SECONDARY_MONITOR "" "$(echo "$others" | head -1)" || { pop_page; return; }
            elif [ $ret -eq 2 ]; then
                pop_page; return
            fi
        fi
    else
        success "Secondary monitor: $SECONDARY_MONITOR (will be disabled)"
    fi

    if [ -z "$GAME_RATE" ]; then
        echo ""
        local detected_rate=""
        case "$SESSION_TYPE" in
            hyprland) detected_rate="$(monitor_rate_hyprland "$MONITOR")" ;;
            x11)      detected_rate="$(detect_rate)" ;;
        esac
        log "Current refresh rate on $MONITOR: ${detected_rate:-unknown}hz"
        log "IIDX requires 120hz. The launcher will switch the primary monitor rate on every launch."
        echo ""
        prompt_value "Target game refresh rate" GAME_RATE "120" "120" || { GAME_RATE=""; pop_page; return; }
    else
        success "Game refresh rate: ${GAME_RATE}hz"
    fi

    if [ -z "$GAME_RES" ]; then
        local detected_res=""
        case "$SESSION_TYPE" in
            hyprland) detected_res="$(monitor_res_hyprland "$MONITOR")" ;;
            x11)      detected_res="$(detect_resolution)" ;;
        esac
        if [ -n "$detected_res" ]; then
            GAME_RES="$detected_res"
            success "Detected resolution: $GAME_RES"
        else
            warn "Could not auto-detect resolution for $MONITOR"
            prompt_value "Monitor resolution" GAME_RES "1920x1080" "1920x1080" || { GAME_RES=""; pop_page; return; }
        fi
    else
        success "Resolution: $GAME_RES"
    fi

    page_footer
    read_nav || { MONITOR=""; SECONDARY_MONITOR=""; GAME_RATE=""; GAME_RES=""; pop_page; return; }
}

page_versions() {
    draw_header 4
    echo -e "  Fetching component versions...\n"

    if [ -z "$BMSOUND_VER" ]; then
        log "Fetching latest bmsound_wine version..."
        BMSOUND_VER="$(fetch_latest_bmsound)"
        [ -n "$BMSOUND_VER" ] || die "Could not fetch bmsound_wine version"
        success "bmsound_wine: $BMSOUND_VER"
    else
        success "bmsound_wine: $BMSOUND_VER (from argument)"
    fi

    if [ -z "$SPICE_DATE" ]; then
        log "Fetching latest spicetools version..."
        SPICE_DATE="$(fetch_latest_spice_date)"
        [ -n "$SPICE_DATE" ] || die "Could not fetch spicetools date"
        success "spicetools date: $SPICE_DATE"
    else
        success "spicetools date: $SPICE_DATE (from argument)"
    fi

    SPICE_VER="${BMSOUND_VER}_${SPICE_DATE}"
    PROTON_DIR="proton-ge-${PROTON_VER//./-}-iidx${GAME_STYLE}"
    GAME_DIR="$STEAM_ROOT/steamapps/common/Beatmania IIDX $GAME_STYLE"
    WORK_DIR="$(mktemp -d /tmp/iidx-install-XXXXXX)"

    success "proton-ge: $PROTON_VER (will be installed as $PROTON_DIR)"

    page_footer
    read_nav || { BMSOUND_VER=""; SPICE_DATE=""; pop_page; return; }
}

page_summary() {
    draw_header 5
    echo -e "  ${BLD}Installation summary${RST}\n"
    echo -e "  Game style        : ${BLD}${GRN}$GAME_STYLE${RST}"
    echo -e "  Dump path         : ${BLD}$DUMP_PATH${RST}"
    echo -e "  Primary monitor   : ${BLD}$MONITOR${RST}"
    [ -n "$SECONDARY_MONITOR" ] && \
        echo -e "  Secondary monitor : ${BLD}$SECONDARY_MONITOR${RST} ${YLW}(off during game)${RST}"
    echo -e "  Resolution        : ${BLD}$GAME_RES @ ${GAME_RATE}hz${RST}"
    echo -e "  bmsound_wine      : ${BLD}$BMSOUND_VER${RST}"
    echo -e "  spicetools        : ${BLD}$SPICE_VER${RST}"
    echo -e "  proton-ge         : ${BLD}$PROTON_VER${RST} → $PROTON_DIR"
    echo -e "  Steam home        : ${BLD}$STEAM_HOME${RST}"
    echo -e "  Install base      : ${BLD}$IIDX_BASE${RST}"
    echo -e "  Distro / PM      : ${BLD}$DISTRO_NAME / ${PKG_MGR:-none}${RST}"
    echo ""
    warn "This will modify your system. Make sure everything above is correct."
    echo ""
    confirm "Proceed with installation?" "y" || { pop_page; return; }

    page_footer
    read_nav || { pop_page; return; }
}

verify_wine_deps() {
    if [ ${#WINE_DEPS[@]} -eq 0 ]; then
        echo ""
        warn "No 32-bit library map for your distro."
        warn "See: https://github.com/lutris/docs/blob/master/WineDependencies.md"
        echo ""
        local ret=0
        confirm "Are wine dependencies already installed?" "y" || ret=$?
        if [ $ret -eq 2 ]; then
            pop_page; return
        elif [ $ret -eq 1 ]; then
            echo -e "\n  Please follow the lutris guide above and re-run this script."
            exit 0
        fi
        return
    fi

    echo ""
    echo -e "  ${BLD}Checking 32-bit libraries for Wine/Proton...${RST}"

    # Arch: ensure multilib is enabled
    if [ "$PKG_MGR" = "pacman" ]; then
        if grep -q "^\[multilib\]" /etc/pacman.conf 2>/dev/null; then
            :
        elif grep -q "^#\[multilib\]" /etc/pacman.conf 2>/dev/null; then
            warn "Multilib repository is disabled in /etc/pacman.conf"
            local ret=0
            confirm "Enable multilib and refresh mirrors?" "y" || ret=$?
            if [ $ret -eq 0 ]; then
                sudo sed -i '/^#\[multilib\]/,/^#Include/s/^#//' /etc/pacman.conf
                sudo pacman -Sy
            elif [ $ret -eq 2 ]; then
                pop_page; return
            fi
        fi
    fi

    # Debian/Ubuntu: ensure i386 architecture
    if [ "$PKG_MGR" = "apt" ]; then
        if ! dpkg --print-foreign-architectures 2>/dev/null | grep -q i386; then
            warn "i386 architecture not enabled"
            local ret=0
            confirm "Add i386 architecture and update package lists?" "y" || ret=$?
            if [ $ret -eq 0 ]; then
                sudo dpkg --add-architecture i386
                sudo apt update
            elif [ $ret -eq 2 ]; then
                pop_page; return
            fi
        fi
    fi

    local missing=()
    for pkg in "${!WINE_DEPS[@]}"; do
        local pkgname="${WINE_DEPS[$pkg]}"
        if $PKG_QUERY "$pkgname" &>/dev/null; then
            success "$pkgname"
        else
            warn "$pkgname not installed"
            missing+=("$pkgname")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo ""
        warn "Missing 32-bit libraries: ${missing[*]}"
        local ret=0
        confirm "Install missing libraries with $PKG_MGR?" "y" || ret=$?
        if [ $ret -eq 0 ]; then
            local install_opts=( "${PKG_INSTALL_OPTS[@]:-}" )
            [ "$AUTO_YES" = "1" ] && install_opts+=("-y")
            sudo $PKG_INSTALL "${install_opts[@]}" "${missing[@]}"
            success "32-bit libraries installed"
        elif [ $ret -eq 2 ]; then
            pop_page; return
        fi
    else
        success "All 32-bit libraries present"
    fi
}

page_deps() {
    draw_header 6
    echo -e "  Checking required packages...\n"

    if [ -z "$PKG_MGR" ] || [ "$PKG_MGR" = "unknown" ]; then
        local manual="git, wget, curl, tar, jq, patch, make, gcc"
        [ "$SESSION_TYPE" = "x11" ] && manual+=", xrandr"
        warn "No supported package manager detected - skipping package checks."
        warn "Install required packages manually: $manual, pipewire, ffmpeg"
        page_footer
        read_nav || { pop_page; return; }
        return
    fi

    local missing_cmds=()
    local missing_pkgs=()

    local check_cmds=(git wget tar make gcc jq patch curl pipewire ffmpeg pw-metadata)
    [ "$SESSION_TYPE" = "x11" ] && check_cmds+=(xrandr)
    for cmd in "${check_cmds[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            success "$cmd"
        else
            warn "$cmd not found (package: ${CMD_PKG[$cmd]:-$cmd})"
            missing_cmds+=("${CMD_PKG[$cmd]:-$cmd}")
        fi
    done

    for pkg in "${!PKG_CHECK[@]}"; do
        if $PKG_QUERY "${PKG_CHECK[$pkg]}" &>/dev/null; then
            success "${PKG_CHECK[$pkg]}"
        else
            warn "${PKG_CHECK[$pkg]} not installed"
            missing_pkgs+=("${PKG_CHECK[$pkg]}")
        fi
    done

    local all_missing=()
    for p in "${missing_cmds[@]}" "${missing_pkgs[@]}"; do
        [[ " ${all_missing[*]} " == *" $p "* ]] || all_missing+=("$p")
    done

    if [ ${#all_missing[@]} -gt 0 ]; then
        echo ""
        warn "Missing packages: ${all_missing[*]}"
        local ret=0
        confirm "Install missing packages with $PKG_MGR?" "y" || ret=$?
        if [ $ret -eq 0 ]; then
            local install_opts=( "${PKG_INSTALL_OPTS[@]:-}" )
            [ "$AUTO_YES" = "1" ] && install_opts+=("-y")
            sudo $PKG_INSTALL "${install_opts[@]}" "${all_missing[@]}"
            success "Packages installed"
            if [[ " ${all_missing[*]} " == *"pipewire"* ]] || [[ " ${all_missing[*]} " == *"wireplumber"* ]]; then
                log "Enabling pipewire services..."
                systemctl --user enable --now pipewire pipewire-pulse wireplumber 2>/dev/null || true
                success "pipewire services enabled"
            fi
        elif [ $ret -eq 2 ]; then
            pop_page; return
        else
            die "Cannot continue without required packages: ${all_missing[*]}"
        fi
    else
        success "All dependencies satisfied"
    fi

    verify_wine_deps

    page_footer
    read_nav || { pop_page; return; }
}

page_groups() {
    draw_header 7
    echo -e "  Checking user group membership...\n"

    local current_groups
    current_groups="$(groups "$USER")"
    local to_add=()
    local relogin_needed=0

    for g in games input realtime audio; do
        if echo "$current_groups" | grep -qw "$g"; then
            success "In group: $g  (${GROUP_DESC[$g]})"
        else
            warn "Not in group: $g  (${GROUP_DESC[$g]})"
            to_add+=("$g")
        fi
    done

    if [ ${#to_add[@]} -eq 0 ]; then
        success "All required groups already set"
    else
        echo ""
        local ret=0
        confirm "Add '$USER' to all missing groups: ${to_add[*]}?" "y" || ret=$?
        if [ $ret -eq 0 ]; then
            sudo usermod -aG "$(IFS=,; echo "${to_add[*]}")" "$USER"
            success "Added to: ${to_add[*]}"
            relogin_needed=1
        elif [ $ret -eq 2 ]; then
            pop_page; return
        else
            echo ""
            local selected=()
            for g in "${to_add[@]}"; do
                confirm "  Add to group '$g' (${GROUP_DESC[$g]})?" "y"
                local r=$?
                if [ $r -eq 0 ]; then
                    selected+=("$g")
                elif [ $r -eq 2 ]; then
                    pop_page; return
                else
                    warn "Skipping '$g' - related features may not work"
                fi
            done
            if [ ${#selected[@]} -gt 0 ]; then
                sudo usermod -aG "$(IFS=,; echo "${selected[*]}")" "$USER"
                success "Added to: ${selected[*]}"
                relogin_needed=1
            fi
        fi
    fi

    if [ "$relogin_needed" = "1" ]; then
        echo ""
        warn "A relogin is required for group changes to take effect."
        warn "Controller input and audio may not work until you relogin."
        confirm "Continue installation anyway?" "y" || { echo "Relogin and re-run the script."; exit 0; }
    fi

    page_footer
    read_nav || { pop_page; return; }
}

page_base() {
    draw_header 8
    echo -e "  Setting up base directories and symlinks...\n"

    sudo mkdir -p "$IIDX_BASE"
    sudo chown -R "$USER:games" "$IIDX_BASE"
    success "Base directory ready: $IIDX_BASE"

    if [ ! -d "$AUTOMIZATION_DIR" ]; then
        log "Cloning automatization..."
        git clone https://codeberg.org/nixac/automatization \
            --recurse-submodules "$AUTOMIZATION_DIR"
        success "automatization cloned"
    else
        success "automatization already present, skipping clone"
    fi

    local steam_parent
    steam_parent="$(dirname "$STEAM_HOME")"
    if [ ! -L "$AUTOMIZATION_DIR/.steam" ]; then
        sudo ln -sfnT "$steam_parent" "$AUTOMIZATION_DIR/.steam"
        success ".steam symlink created -> $steam_parent"
    else
        local current_target
        current_target="$(readlink "$AUTOMIZATION_DIR/.steam")"
        if [ "$current_target" != "$steam_parent" ]; then
            warn "Existing .steam symlink points to: $current_target"
            confirm "Update .steam symlink to $steam_parent?" "y" && \
                sudo ln -sfnT "$steam_parent" "$AUTOMIZATION_DIR/.steam" && \
                success ".steam symlink updated"
        else
            success ".steam symlink already correct"
        fi
    fi

    mkdir -p "$STEAM_ROOT/steamapps/common"
    mkdir -p "$STEAM_ROOT/steamapps/compatdata"
    success "steamapps structure ready"

    page_footer
    read_nav || { pop_page; return; }
}

page_proton() {
    draw_header 9
    echo -e "  Downloading and patching Proton-GE $PROTON_VER for IIDX $GAME_STYLE...\n"

    local proton_dest="$STEAM_ROOT/steamapps/common/$PROTON_DIR"
    local proton_tag="GE-Proton${PROTON_VER//./-}"

    check_disk_space "$WORK_DIR" 1000 "temp dir"
    check_disk_space "$STEAM_ROOT" 3000 "Steam root"

    download_file "Proton-GE $proton_tag" \
        "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${proton_tag}/${proton_tag}.tar.gz" \
        "$WORK_DIR/proton-ge.tar.gz"

    log "Extracting..."
    tar -xf "$WORK_DIR/proton-ge.tar.gz" -C "$WORK_DIR"
    mv "$WORK_DIR/$proton_tag" "$WORK_DIR/proton-ge"

    log "Applying patches..."
    (
        cd "$WORK_DIR/proton-ge"
        patch -p1 < "$AUTOMIZATION_DIR/proton-ge/proton.patch" || warn "Some hunks rejected (expected)"
        mkdir -p protonfixes/gamefixes
        cp "$AUTOMIZATION_DIR/proton-ge/000"*.py protonfixes/gamefixes/ 2>/dev/null || true
        cp "$AUTOMIZATION_DIR/proton-ge/000"*.py protonfixes/gamefixes-steam/ 2>/dev/null || true
    )
    mv "$WORK_DIR/proton-ge" "$proton_dest"
    success "Proton-GE installed at $proton_dest"

    page_footer
    read_nav || { pop_page; return; }
}

page_binaries() {
    draw_header 10
    echo -e "  Downloading spicetools and building bmsound_wine...\n"

    check_disk_space "$WORK_DIR" 2000 "temp dir"

    download_file "spicetools $SPICE_VER" \
        "https://codeberg.org/nixac/spicetools/releases/download/${SPICE_VER}/spicetools.tar.gz" \
        "$WORK_DIR/spicetools.tar.gz"
    mkdir -p "$WORK_DIR/spicetools"
    tar -xf "$WORK_DIR/spicetools.tar.gz" -C "$WORK_DIR/spicetools"
    success "spicetools extracted"

    echo ""
    log "Cloning bmsound_wine $BMSOUND_VER..."
    git clone https://codeberg.org/nixac/bmsound_wine "$WORK_DIR/bmsound_wine"
    (
        cd "$WORK_DIR/bmsound_wine"
        git fetch --tags
        git checkout "tags/${BMSOUND_VER}"
        git submodule update --init --recursive
        log "Building bmsound_wine..."
        make -Rs build TARGET_ARCH=x64 TARGET_TYPE=Release
    )

    local bmsw_src=""
    if [ -d "$WORK_DIR/bmsound_wine/build/Release/x64" ]; then
        bmsw_src="$WORK_DIR/bmsound_wine/build/Release/x64"
    elif [ -d "$WORK_DIR/bmsound_wine/bin/Release/x64" ]; then
        bmsw_src="$WORK_DIR/bmsound_wine/bin/Release/x64"
    else
        die "bmsound_wine build output not found"
    fi

    cp -r "$bmsw_src" "$WORK_DIR/bmsw"
    success "bmsound_wine built"

    page_footer
    read_nav || { pop_page; return; }
}

page_game() {
    draw_header 11
    echo -e "  Installing game files for IIDX $GAME_STYLE...\n"

    local contents="$DUMP_PATH/contents"

    if ls "$contents"/*.dll &>/dev/null 2>&1; then
        log "Moving .dll files to contents/modules..."
        mkdir -p "$contents/modules"
        mv "$contents"/*.dll "$contents/modules/" 2>/dev/null || true
        success ".dll files moved to modules/"
    fi

    log "Copying bmsound_wine..."
    find "$WORK_DIR/bmsw" -maxdepth 1 -name "bmsound-*" -type f \
        -exec cp {} "$contents/modules/" \;
    success "bmsound_wine copied to modules/"

    log "Copying spicetools..."
    find "$WORK_DIR/spicetools" -maxdepth 1 -name "spice*" -type f \
        -exec cp {} "$contents/" \;
    success "spicetools copied to contents/"

    if [ ! -L "$GAME_DIR" ] && [ ! -d "$GAME_DIR" ]; then
        ln -sfnT "$DUMP_PATH" "$GAME_DIR"
        success "Symlink: $GAME_DIR -> $DUMP_PATH"
    else
        success "Game symlink already exists"
    fi

    local linux_json="$contents/prop/linux.json"
    if [ -f "$linux_json" ]; then
        log "Merging rt_override into existing linux.json..."
        local tmp
        tmp="$(jq --arg rt "$PROTON_DIR" '. * {"extra": {"rt_override": $rt}}' "$linux_json")" || die "jq merge failed"
        [ -n "$tmp" ] || die "jq produced empty output"
        printf '%s\n' "$tmp" > "$linux_json"
    else
        log "Creating linux.json..."
        mkdir -p "$(dirname "$linux_json")"
        printf '{\n    "extra": {\n        "rt_override": "%s"\n    }\n}' "$PROTON_DIR" > "$linux_json"
    fi
    success "linux.json configured (rt_override: $PROTON_DIR)"

    page_footer
    read_nav || { pop_page; return; }
}

page_network() {
    draw_header 12
    echo -e "  Asphyxia is a local server for score saving, song unlocks and profiles.\n"

    local ret=0
    confirm "Configure asphyxia network in linux.json?" "y" || ret=$?
    if [ $ret -eq 2 ]; then
        pop_page; return
    elif [ $ret -eq 1 ]; then
        log "Skipping network setup - edit linux.json manually later if needed"
        page_footer
        read_nav || { pop_page; return; }
        return
    fi

    prompt_value "Asphyxia server URL" ASPHYXIA_URL "http://127.0.0.1:1108/" "http://127.0.0.1:1108/" || { pop_page; return; }
    prompt_value "PCBID (unique cabinet ID)" ASPHYXIA_PCBID "00010203040506070809" "00010203040506070809" || { pop_page; return; }

    local linux_json="$DUMP_PATH/contents/prop/linux.json"
    local tmp
    tmp="$(jq \
        --arg url "$ASPHYXIA_URL" \
        --arg pcbid "$ASPHYXIA_PCBID" \
        '. * {"network": {"url": $url, "pcbid": $pcbid}}' \
        "$linux_json")" || die "jq merge failed for network config"
    [ -n "$tmp" ] || die "jq produced empty output"
    printf '%s\n' "$tmp" > "$linux_json"
    success "Network configured: $ASPHYXIA_URL (pcbid: $ASPHYXIA_PCBID)"

    echo ""
    warn "Make sure asphyxia is running before launching the game."
    warn "Remember to generate a card in spicecfg > Cards tab."
    warn "And bind 'P1 Keypad Insert Card' in spicecfg > Buttons tab."

    page_footer
    read_nav || { pop_page; return; }
}

page_verify() {
    draw_header 13
    echo -e "  Verifying installation structure...\n"

    local ok=1
    local checks=(
        "$AUTOMIZATION_DIR"
        "$AUTOMIZATION_DIR/.steam"
        "$STEAM_ROOT/steamapps/common/$PROTON_DIR"
        "$GAME_DIR"
        "$DUMP_PATH/contents/spice64.exe"
        "$DUMP_PATH/contents/modules/bmsound-pw.so"
        "$DUMP_PATH/contents/modules/bmsound-wine.dll"
        "$DUMP_PATH/contents/prop/linux.json"
    )

    for path in "${checks[@]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            success "$path"
        else
            warn "Missing: $path"
            ok=0
        fi
    done

    echo ""
    if [ "$ok" = "0" ]; then
        warn "Some paths are missing - installation may be incomplete"
        confirm "Continue anyway?" "n" || die "Aborting due to incomplete installation"
    else
        success "All paths verified"
    fi

    page_footer
    read_nav || { pop_page; return; }
}

page_launchers() {
    draw_header 14
    echo -e "  Creating .desktop launcher entries...\n"

    mkdir -p "$HOME/.local/share/applications"

    local q_auto="$(printf '%q' "$AUTOMIZATION_DIR")"
    local q_style="$(printf '%q' "$GAME_STYLE")"
    local q_root="$(printf '%q' "$STEAM_ROOT")"
    local q_mon="$(printf '%q' "$MONITOR")"
    local exec_base="$q_auto/helper/ep_bm2dxnix $q_style --root $q_root"

    local exec_game
    local q_res="$(printf '%q' "$GAME_RES")"
    local q_rate="$(printf '%q' "$GAME_RATE")"
    local helper="$AUTOMIZATION_DIR/helper/iidx-mon-state.sh"
    case "$SESSION_TYPE" in
        hyprland)
            cat > "$helper" <<'HELPER'
#!/bin/bash
case "$1" in
    save)
        f="$2"
        : > "$f"
        hyprctl monitors all 2>/dev/null | grep '^Monitor ' | while IFS= read -r line; do
            m="${line#Monitor }"
            m="${m%% *}"
            blk="$(hyprctl monitors all 2>/dev/null | sed -n "/^Monitor $m /,/^\$/p")"
            res="$(printf '%s' "$blk" | grep -oP '^\s*\K\d+x\d+(?=@)' | head -1)"
            rate="$(printf '%s' "$blk" | grep -oP '@\K[\d.]+' | head -1)"
            pos="$(printf '%s' "$blk" | grep -oP 'at \K-?\d+x-?\d+')"
            trans="$(printf '%s' "$blk" | grep -oP 'transform:\s*\K\d+' || echo 0)"
            full="${res:-preferred}"
            [ -n "$rate" ] && full="${full}@${rate}"
            printf '%s\n' "hyprctl keyword monitor '$m,$full,${pos:-auto},1'"
            [ "$trans" != "0" ] && printf '%s\n' "hyprctl keyword monitor '$m,transform,$trans'"
        done > "$f"
        ;;
    restore)
        [ -f "$2" ] && bash "$2"
        ;;
esac
HELPER
            chmod +x "$helper"

            if [ -n "$SECONDARY_MONITOR" ]; then
                local q_sec="$(printf '%q' "$SECONDARY_MONITOR")"
                exec_game='bash -c "f=$(mktemp /tmp/iidx-XXXXXX.sh); '"$helper"' save \"$f\" && hyprctl keyword monitor '"$q_sec"',disable && hyprctl keyword monitor '"$q_mon"','"$q_res"'@'"$q_rate"',auto,1 && '"$exec_base"'; source \"$f\" 2>/dev/null || true; rm -f \"$f\""'
            else
                exec_game='bash -c "f=$(mktemp /tmp/iidx-XXXXXX.sh); '"$helper"' save \"$f\" && hyprctl keyword monitor '"$q_mon"','"$q_res"'@'"$q_rate"',auto,1 && '"$exec_base"'; source \"$f\" 2>/dev/null || true; rm -f \"$f\""'
            fi
            ;;
        *)
            cat > "$helper" <<'HELPER'
#!/bin/bash
case "$1" in
    save)
        f="$2"
        : > "$f"
        xrandr 2>/dev/null | grep ' connected ' | while IFS= read -r line; do
            m="$(printf '%s' "$line" | awk '{print $1}')"
            mode="$(printf '%s' "$line" | grep -oP '\d+x\d+(?=[-+])' || true)"
            pos_raw="$(printf '%s' "$line" | grep -oP '[-+]\d+[-+]\d+' || echo '+0+0')"
            rot="$(printf '%s' "$line" | grep -oP '\(\K(normal|left|inverted|right)' || echo 'normal')"
            if [[ "$pos_raw" =~ ^([-+]?)([0-9]+)([-+])([0-9]+)$ ]]; then
                x="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
                y="${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
                x="${x#+}"
                y="${y#+}"
                pos="${x}x${y}"
            fi
            if [ -n "$mode" ]; then
                printf '%s\n' "xrandr --output '$m' --mode '$mode' --pos '$pos' --rotate '$rot'"
            else
                printf '%s\n' "xrandr --output '$m' --auto --pos '$pos' --rotate '$rot'"
            fi
        done > "$f"
        ;;
    restore)
        [ -f "$2" ] && bash "$2"
        ;;
esac
HELPER
            chmod +x "$helper"

            if [ -n "$SECONDARY_MONITOR" ]; then
                local q_sec="$(printf '%q' "$SECONDARY_MONITOR")"
                exec_game='bash -c "f=$(mktemp /tmp/iidx-XXXXXX.sh); '"$helper"' save \"$f\" && xrandr --output '"$q_sec"' --off && xrandr --output '"$q_mon"' --mode '"$q_res"' --rate '"$q_rate"' && __GL_SYNC_DISPLAY_DEVICE='"$q_mon"' '"$exec_base"'; source \"$f\" 2>/dev/null || true; rm -f \"$f\""'
            else
                exec_game='bash -c "f=$(mktemp /tmp/iidx-XXXXXX.sh); '"$helper"' save \"$f\" && xrandr --output '"$q_mon"' --mode '"$q_res"' --rate '"$q_rate"' && __GL_SYNC_DISPLAY_DEVICE='"$q_mon"' '"$exec_base"'; source \"$f\" 2>/dev/null || true; rm -f \"$f\""'
            fi
            ;;
    esac

    cat > "$HOME/.local/share/applications/iidx${GAME_STYLE}.desktop" <<EOF
[Desktop Entry]
Name=Beatmania IIDX $GAME_STYLE
Exec=$exec_game
Type=Application
Categories=Game;
EOF
    success "iidx${GAME_STYLE}.desktop created"

    cat > "$HOME/.local/share/applications/iidx${GAME_STYLE}-cfg.desktop" <<EOF
[Desktop Entry]
Name=Beatmania IIDX $GAME_STYLE (Config)
Exec=bash -c "__GL_SYNC_DISPLAY_DEVICE=$q_mon $exec_base --cfg"
Type=Application
Categories=Game;
EOF
    success "iidx${GAME_STYLE}-cfg.desktop created"

    page_footer
    read_nav || { pop_page; return; }
}

page_patches() {
    draw_header 15
    echo -e "  After installation, open spicecfg and go to the ${BLD}Patches${RST} tab.\n"
    echo -e "  ${BLD}Recommended patches for IIDX $GAME_STYLE:${RST}\n"
    echo -e "    ${GRN}✓${RST}  ${BLD}Wine fixes${RST}"
    echo -e "         Apply always.\n"
    echo -e "    ${GRN}✓${RST}  ${BLD}Bypass camera device error${RST}"
    echo -e "         Apply if the game crashes on startup with a camera error.\n"
    echo -e "    ${GRN}✓${RST}  ${BLD}Bypass lightning monitor error${RST}"
    echo -e "         Apply if you don't have a Lightning Model cabinet.\n"
    echo -e "    ${RED}✗${RST}  ${BLD}WASAPI shared${RST}"
    echo -e "         Do ${BLD}NOT${RST} enable this.\n"
    echo ""
    warn "Try launching the game without patches first."
    warn "Only enable a patch if the game fails to start without it."

    page_footer
    read_nav || { pop_page; return; }
}

page_done() {
    draw_header 16
    # WORK_DIR cleaned up by trap on EXIT

    echo -e "  ${GRN}${BLD}Installation complete!${RST}\n"
    echo -e "  ${BLD}Next steps:${RST}\n"
    echo -e "    ${CYN}1.${RST} Run spicecfg to configure controls:"
    echo -e "       ${BLD}$AUTOMIZATION_DIR/helper/ep_bm2dxnix $GAME_STYLE --root $STEAM_ROOT --cfg${RST}"
    echo ""
    echo -e "    ${CYN}2.${RST} In spicecfg:"
    echo -e "       • ${BLD}Cards${RST} tab → press ${BLD}Generate${RST} for Player 1"
    echo -e "       • ${BLD}Buttons${RST} tab → bind ${BLD}P1 Keypad Insert Card${RST}"
    echo -e "       • ${BLD}Patches${RST} tab → apply patches as shown in previous step"
    echo ""
    echo -e "    ${CYN}3.${RST} Launch the game:"
    echo -e "       • Search ${CYN}Beatmania IIDX $GAME_STYLE${RST} in your app launcher"
    echo -e "       • Or run from terminal:"
    echo -e "         ${BLD}$AUTOMIZATION_DIR/helper/ep_bm2dxnix $GAME_STYLE --root $STEAM_ROOT${RST}"
    echo ""

    page_footer
    echo -en "\n  Press Enter to exit."
    read -r
}

##
## Uninstaller
##
run_uninstaller() {
    clear
    echo -e "${RED}${BLD}"
    echo "▄█ ▄█ ██▄      ▄      █    ▄█    ▄     ▄       ▄      ▄█    ▄      ▄▄▄▄▄      ▄▄▄▄▀ ██   █     ▄███▄   █▄▄▄▄ "
    echo "██ ██ █  █ ▀▄   █     █    ██     █     █  ▀▄   █     ██     █    █     ▀▄ ▀▀▀ █    █ █  █     █▀   ▀  █  ▄▀ "
    echo "██ ██ █   █  █ ▀      █    ██ ██   █ █   █   █ ▀      ██ ██   █ ▄  ▀▀▀▀▄       █    █▄▄█ █     ██▄▄    █▀▀▌  "
    echo "▐█ ▐█ █  █  ▄ █       ███▄ ▐█ █ █  █ █   █  ▄ █       ▐█ █ █  █  ▀▄▄▄▄▀       █     █  █ ███▄  █▄   ▄▀ █  █  "
    echo " ▐  ▐ ███▀ █   ▀▄         ▀ ▐ █  █ █ █▄ ▄█ █   ▀▄      ▐ █  █ █              ▀         █     ▀ ▀███▀     █   "
    echo "            ▀                 █   ██  ▀▀▀   ▀            █   ██                       █                 ▀    "
    echo "                                                                                     ▀ "
    echo -e "${RST}"
    echo ""


    local steam_root=""
    local iidx_base="${IIDX_BASE:-/var/games/iidx}"
    local auto_dir="${AUTOMIZATION_DIR:-$iidx_base/automatization}"

    # Try to resolve STEAM_ROOT from the installation
    if [ -L "$auto_dir/.steam/root" ]; then
        steam_root="$(realpath "$auto_dir/.steam/root" 2>/dev/null || true)"
    fi
    if [ -z "$steam_root" ] && [ -n "$STEAM_HOME" ]; then
        steam_root="$STEAM_HOME"
    fi
    if [ -z "$steam_root" ]; then
        local detected
        detected="$(detect_steam_home 2>/dev/null | head -1 || true)"
        [ -n "$detected" ] && steam_root="$detected"
    fi

    # Detect installed styles from .desktop files and dump dirs
    local -A styles_seen
    local detected_styles=()
    local remove_styles=()
    local remove_all=0
    local remove_base_only=0

    for f in "$HOME/.local/share/applications/iidx"*.desktop; do
        [ -f "$f" ] || continue
        local base="${f##*/iidx}"
        base="${base%.desktop}"
        [[ "$base" == *-cfg ]] && continue
        [ -z "${styles_seen[$base]+x}" ] || continue
        styles_seen["$base"]=1
        detected_styles+=("$base")
    done

    for d in "$iidx_base"/dump-*; do
        [ -d "$d" ] || continue
        local s="${d##*/dump-}"
        [ -z "${styles_seen[$s]+x}" ] || continue
        styles_seen["$s"]=1
        detected_styles+=("$s")
    done

    if [ ${#detected_styles[@]} -eq 0 ]; then
        echo -e "  ${YLW}No installed styles found.${RST}"
        echo ""
        echo -e "  The following will be removed:"
        [ -d "$iidx_base" ]          && echo -e "    • ${RED}$iidx_base${RST}"
        [ -L "$auto_dir/.steam" ]    && echo -e "    • ${RED}$auto_dir/.steam${RST}"
        for f in "$HOME/.local/share/applications/iidx"*.desktop; do
            [ -f "$f" ] && echo -e "    • ${RED}$f${RST}"
        done
        echo ""

        if ! confirm "Remove all IIDX installation files?" "n"; then
            echo -e "\n  ${YLW}Uninstall cancelled.${RST}"
            return
        fi
        remove_all=1
    else
        echo -e "  ${BLD}Found installed styles:${RST}"
        local i=1
        for s in "${detected_styles[@]}"; do
            echo -e "    ${CYN}$i.${RST} $s"
            ((i++))
        done
        echo ""
        echo -e "  ${BLD}For each style, the following will be removed:${RST}"
        echo -e "    • Desktop entries (app launcher + config)"
        echo -e "    • Dump directory: ${BLD}$iidx_base/dump-{style}${RST}"
        echo -e "    • Game symlink: ${BLD}Beatmania IIDX {style}${RST}"
        echo ""

        if confirm "Uninstall all styles?" "n"; then
            remove_styles=("${detected_styles[@]}")
        else
            remove_styles=()
            for s in "${detected_styles[@]}"; do
                confirm "  Uninstall style '$s'?" "n" && remove_styles+=("$s")
            done
        fi

        if [ ${#remove_styles[@]} -eq 0 ]; then
            echo -e "\n  ${YLW}No styles selected.${RST}"
            if confirm "Remove base installation without removing any style?" "n"; then
                remove_base_only=1
            else
                echo -e "\n  ${YLW}Uninstall cancelled.${RST}"
                return
            fi
        fi
    fi

    echo ""

    # --- Removal phase ---
    local removed_any=0

    # Remove selected styles
    if [ ${#remove_styles[@]} -gt 0 ]; then
        echo -e "  ${BLD}Removing selected styles...${RST}"
        for s in "${remove_styles[@]}"; do
            # Desktop files
            rm -f "$HOME/.local/share/applications/iidx${s}.desktop"
            rm -f "$HOME/.local/share/applications/iidx${s}-cfg.desktop"
            # Dump dir
            [ -d "$iidx_base/dump-${s}" ] && sudo rm -rf "$iidx_base/dump-${s}"
            # Game symlink
            if [ -n "$steam_root" ]; then
                local gdir="$steam_root/steamapps/common/Beatmania IIDX $s"
                [ -L "$gdir" ] && rm -f "$gdir"
            fi
            echo -e "    ${GRN}✓${RST} Style $s removed"
            removed_any=1
        done
    fi

    # Remove remaining desktop files (orphans)
    for f in "$HOME/.local/share/applications/iidx"*.desktop; do
        [ -f "$f" ] && rm -f "$f" && removed_any=1
    done

    # Remove installation base
    if [ -d "$iidx_base" ]; then
        echo ""
        if [ "${remove_all:-0}" = "1" ] || [ "${remove_base_only:-0}" = "1" ] || confirm "Remove base directory ($iidx_base)?" "n"; then
            # Remove symlink first
            [ -L "$auto_dir/.steam" ] && sudo rm -f "$auto_dir/.steam"
            # Remove helper script
            [ -f "$auto_dir/helper/iidx-mon-state.sh" ] && rm -f "$auto_dir/helper/iidx-mon-state.sh"
            sudo rm -rf "$iidx_base"
            echo -e "  ${GRN}✓${RST} $iidx_base removed"
            removed_any=1
        fi
    fi

    # Remove Proton dir
    if [ -n "$steam_root" ]; then
        local proton_dir="${PROTON_DIR:-8.32}"
        local proton_path="$steam_root/steamapps/common/$proton_dir"
        # Try to find the actual Proton dir by scanning for GE-Proton
        if [ ! -d "$proton_path" ]; then
            for d in "$steam_root/steamapps/common/"GE-Proton*; do
                [ -d "$d" ] && proton_path="$d" && break
            done
        fi
        if [ -d "$proton_path" ]; then
            echo ""
            if confirm "Remove custom Proton ($(basename "$proton_path"))?" "n"; then
                rm -rf "$proton_path"
                echo -e "  ${GRN}✓${RST} $(basename "$proton_path") removed"
                removed_any=1
            fi
        fi
    fi

    if [ "$removed_any" -eq 0 ]; then
        echo -e "  ${YLW}Nothing to remove.${RST}"
    fi

    # --- System changes (optional) ---
    echo ""
    if confirm "Revert system changes (packages, groups, services)?" "n"; then
        echo ""
        echo -e "  ${YLW}This will remove packages installed by the installer.${RST}"
        echo -e "  ${YLW}Only packages that are not required by other applications will be suggested.${RST}"
        echo ""

        # Packages to consider removing
        local system_pkgs=()
        if type pacman &>/dev/null; then
            system_pkgs=(git wget pipewire pipewire-pulse wireplumber ffmpeg)
            # 32-bit wine deps
            system_pkgs+=(alsa-lib expat fontconfig freetype2 glu gsm gst-plugins-base-libs gtk2 gtk3)
            system_pkgs+=(libgpg-error libjpeg-turbo libldap libpcap libpng libpulse libsm libusb)
            system_pkgs+=(libx11 libxau libxcb libxcomposite libxcursor libxdamage libxext libxfixes)
            system_pkgs+=(libxft libxi libxinerama libxml2 libxrandr libxrender libxscrnsaver libxxf86vm)
            system_pkgs+=(mpg123 ncurses openal ocl-icd pcre2 sdl2 sdl2_image v4l-utils vulkan-icd-loader)
            system_pkgs+=(xcb-util-keysyms xdg-desktop-portal-gtk)
        fi

        if confirm "  Remove installed packages?" "n"; then
            if [ ${#system_pkgs[@]} -gt 0 ]; then
                echo -e "    Running: sudo pacman -Rns --recursive ${system_pkgs[*]}"
                echo -e "    ${YLW}Note: packages needed by other software will be skipped by pacman.${RST}"
                if confirm "    Proceed?" "n"; then
                    sudo pacman -Rns --recursive "${system_pkgs[@]}" 2>/dev/null || true
                fi
            fi
        fi

        if confirm "  Remove user from groups (games, input, realtime, audio)?" "n"; then
            for g in games input realtime audio; do
                sudo gpasswd -d "$USER" "$g" 2>/dev/null || true
            done
            echo -e "  ${GRN}✓${RST} User removed from groups"
        fi

        if confirm "  Disable pipewire services?" "n"; then
            systemctl --user disable --now pipewire pipewire-pulse wireplumber 2>/dev/null || true
            echo -e "  ${GRN}✓${RST} Pipewire services disabled"
        fi

        if type pacman &>/dev/null; then
            if confirm "  Revert multilib (/etc/pacman.conf)?" "n"; then
                sudo sed -i '/^\[multilib\]/,/^Include/s/^/#/' /etc/pacman.conf
                echo -e "  ${GRN}✓${RST} Multilib reverted"
            fi
        fi
        if type dpkg &>/dev/null; then
            if confirm "  Remove i386 architecture?" "n"; then
                sudo dpkg --remove-architecture i386 2>/dev/null || true
                echo -e "  ${GRN}✓${RST} i386 architecture removed"
            fi
        fi
    fi

    echo ""
    success "Uninstall complete."
    echo ""
}

## Early exit: uninstall mode
if [ "$UNINSTALL" = "1" ]; then
    run_uninstaller
    exit 0
fi

##
## Main - pagination loop
##
main() {
    local pages=(
        page_intro
        page_configuration
        page_steam
        page_monitor
        page_versions
        page_summary
        page_deps
        page_groups
        page_base
        page_proton
        page_binaries
        page_game
        page_network
        page_verify
        page_launchers
        page_patches
        page_done
    )

    SESSION_TYPE="$(detect_compositor)"
    log "Session type: $SESSION_TYPE"
    preflight_check

    local idx=0
    while [ $idx -lt ${#pages[@]} ]; do
        local prev_len=${#PAGE_HISTORY[@]}
        PAGE_HISTORY+=("$idx")
        "${pages[$idx]}"
        # If pop_page was called inside the page, the array is shorter → go back
        if [ ${#PAGE_HISTORY[@]} -gt $prev_len ]; then
            unset 'PAGE_HISTORY[-1]'
            idx=$((idx + 1))
        else
            [ $idx -gt 0 ] && idx=$((idx - 1))
        fi
    done
}

main
