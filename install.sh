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

# Respect the de-facto NO_COLOR convention and keep redirected output clean.
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    RED='' GRN='' YLW='' BLU='' CYN='' MAG='' BLD='' RST=''
fi

## The installer manages privileged operations with sudo itself. Running the
## whole wizard as root changes HOME/USER and can make it use root's Steam and
## desktop directories instead of the invoking user's installation.
if [[ "${BASH_SOURCE[0]}" == "$0" ]] && [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo -e "  ${RED}✗${RST} Do not run this installer as root or with sudo." >&2
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        echo "Run it again as '$SUDO_USER' without sudo: ./install.sh" >&2
    else
        echo "Run it again from your regular desktop user: ./install.sh" >&2
    fi
    echo "The script will request sudo only for the individual system operations that need it." >&2
    exit 1
fi

## Distro / package manager - populated by detect_distro()
DISTRO_ID=""
DISTRO_NAME=""
PKG_MGR=""
PKG_QUERY=()
PKG_INSTALL=()
PKG_INSTALL_OPTS=()
VOID_LIBC=""

## Pagination state
PAGE_NAMES=(
    "Welcome"
    "Setup"
    "Summary"
    "Install"
    "Patches"
    "Done"
)
TOTAL_PAGES=${#PAGE_NAMES[@]}

## Page history stack for back navigation
PAGE_HISTORY=()
UI_AUTONEXT=0
UI_LOCK_BACK=0
UI_MAIN_PAGE_OVERRIDE=""
UI_ACTIVE_SUB_LABEL=""
INSTALL_TASK_NAMES=(
    "Dependencies"
    "User groups"
    "Base setup"
    "Proton-GE"
    "Audio and launcher binaries"
    "Game files"
    "Network configuration"
    "Installation verification"
    "Desktop launchers"
)
INSTALL_TASK_STATES=(pending pending pending pending pending pending pending pending pending)

## Cleanup on exit / interrupt
cleanup() {
    local rc=$?
    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
    exit "$rc"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap cleanup EXIT
fi

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
  --rate           <HZ>    Game refresh rate (default: 120; use 60 for some dumps/cabinets)
  --proton-ver     <VER>   Proton-GE version (default: 8.32)
  --bmsound-ver    <VER>   bmsound_wine version (default: latest)
  --spice-date     <DATE>  spicetools date (default: latest)
  --steam-home     <PATH>  Steam root path (auto-detected)
  --icon           <PATH|URL> Optional desktop icon image (local file or HTTP(S) URL)
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

preflight_check() {
    detect_distro
    [ "$DISTRO_ID" = "void" ] && validate_void_platform
    init_pkg_maps

    log "Distro: ${DISTRO_NAME} (${DISTRO_ID}) - package manager: ${PKG_MGR:-none}"
    if [ "$PKG_MGR" = "unknown" ] || [ -z "$PKG_MGR" ]; then
        warn "Distro '$DISTRO_ID' is not officially supported."
        warn "Automatic package installation will be skipped."
        local ok=0
        confirm "Continue anyway?" "n" || die "Aborting - unsupported distro"
    fi

    # curl is needed before the dependency page to discover release versions.
    # The remaining build/runtime commands are installed by page_deps().
    local required=(curl)
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

    local unavailable_hosts=()
    for host in codeberg.org github.com; do
        curl -sf --max-time 10 "https://$host" >/dev/null 2>&1 || unavailable_hosts+=("$host")
    done
    if [ ${#unavailable_hosts[@]} -gt 0 ]; then
        warn "Cannot reach: ${unavailable_hosts[*]} - network may be unavailable."
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
    local os_release="${IIDX_OS_RELEASE_FILE:-/etc/os-release}"
    # Testable path; defaults to /etc/os-release.
    # shellcheck disable=SC1090
    [ -f "$os_release" ] && . "$os_release"
    DISTRO_ID="${ID:-unknown}"
    DISTRO_NAME="${NAME:-$DISTRO_ID}"

    case "$DISTRO_ID" in
        arch)
            PKG_MGR="pacman"
            PKG_QUERY=(pacman -Q)
            PKG_INSTALL=(pacman -S)
            PKG_INSTALL_OPTS=(--needed)
            ;;
        debian|ubuntu)
            PKG_MGR="apt"
            PKG_QUERY=(dpkg -l)
            PKG_INSTALL=(apt install)
            PKG_INSTALL_OPTS=( )
            ;;
        fedora)
            PKG_MGR="dnf"
            PKG_QUERY=(rpm -q)
            PKG_INSTALL=(dnf install)
            PKG_INSTALL_OPTS=( )
            ;;
        void)
            PKG_MGR="xbps"
            PKG_QUERY=(xbps-query -p pkgver)
            PKG_INSTALL=(xbps-install -S)
            PKG_INSTALL_OPTS=( )
            ;;
        *)
            # Fallback: detect by package manager binary
            if command -v pacman &>/dev/null; then
                PKG_MGR="pacman"
                PKG_QUERY=(pacman -Q)
                PKG_INSTALL=(pacman -S)
                PKG_INSTALL_OPTS=(--needed)
            elif command -v apt &>/dev/null; then
                PKG_MGR="apt"
                PKG_QUERY=(dpkg -l)
                PKG_INSTALL=(apt install)
                PKG_INSTALL_OPTS=( )
            elif command -v dnf &>/dev/null; then
                PKG_MGR="dnf"
                PKG_QUERY=(rpm -q)
                PKG_INSTALL=(dnf install)
                PKG_INSTALL_OPTS=( )
            elif command -v xbps-install &>/dev/null && command -v xbps-query &>/dev/null; then
                PKG_MGR="xbps"
                PKG_QUERY=(xbps-query -p pkgver)
                PKG_INSTALL=(xbps-install -S)
                PKG_INSTALL_OPTS=( )
            else
                PKG_MGR="unknown"
                PKG_QUERY=()
                PKG_INSTALL=()
            fi
            ;;
    esac
}

validate_void_platform() {
    local machine="${IIDX_MACHINE:-$(uname -m)}"
    if [ "$machine" != "x86_64" ]; then
        die "Void Linux support requires x86_64, detected: $machine"
    fi

    if [ -n "${IIDX_LIBC:-}" ]; then
        VOID_LIBC="$IIDX_LIBC"
    elif compgen -G '/lib/ld-musl-*.so.1' >/dev/null 2>&1; then
        VOID_LIBC="musl"
    elif getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
        VOID_LIBC="glibc"
    else
        VOID_LIBC="unknown"
    fi

    case "$VOID_LIBC" in
        glibc) success "Void platform: x86_64 glibc" ;;
        musl)
            die "Void musl is not supported: Steam/Proton and Void multilib require x86_64 glibc."
            ;;
        *)
            die "Could not verify glibc on Void Linux; refusing to configure Steam/Proton multilib."
            ;;
    esac
}

init_pkg_maps() {
    # Must be called after detect_distro()
    case "$PKG_MGR" in
        apt)
            CMD_PKG=(
                [git]="git" [wget]="wget" [tar]="tar" [make]="make" [gcc]="gcc"
                [jq]="jq" [patch]="patch" [curl]="curl" [sha512sum]="coreutils"
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
                [jq]="jq" [patch]="patch" [curl]="curl" [sha512sum]="coreutils"
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
        xbps)
            CMD_PKG=(
                [git]="git" [wget]="wget" [tar]="tar" [make]="make" [gcc]="gcc"
                [jq]="jq" [patch]="patch" [curl]="curl" [sha512sum]="coreutils" [cmake]="cmake"
                [pkg-config]="pkg-config" [winebuild]="wine-tools" [winegcc]="wine-tools"
                [xrandr]="xrandr" [pipewire]="pipewire" [ffmpeg]="ffmpeg"
                [pw-metadata]="pipewire" [wpctl]="wireplumber"
                [kscreen-doctor]="libkf6screen"
            )
            PKG_CHECK=(
                [wireplumber]="wireplumber"
                [alsa-pipewire]="alsa-pipewire"
                [gstreamer1-pipewire]="gstreamer1-pipewire"
                [pipewire-devel]="pipewire-devel"
                [ffmpeg6-devel]="ffmpeg6-devel"
                [wine-devel]="wine-devel"
            )
            WINE_DEPS=(
                [gnutls-32bit]="gnutls-32bit"
                [libldap-32bit]="libldap-32bit"
                [sqlite-32bit]="sqlite-32bit"
                [libpulseaudio-32bit]="libpulseaudio-32bit"
                [alsa-plugins-32bit]="alsa-plugins-32bit"
                [libmpg123-32bit]="libmpg123-32bit"
                [lcms2-32bit]="lcms2-32bit"
                [libjpeg-turbo-32bit]="libjpeg-turbo-32bit"
                [freetype-32bit]="freetype-32bit"
                [dbus-libs-32bit]="dbus-libs-32bit"
                [vulkan-loader-32bit]="vulkan-loader-32bit"
            )
            ;;
        pacman|*)
            CMD_PKG=(
                [git]="git" [wget]="wget" [tar]="tar" [make]="make" [gcc]="gcc"
                [jq]="jq" [patch]="patch" [curl]="curl" [sha512sum]="coreutils" [cmake]="cmake"
                [pkg-config]="pkgconf" [winebuild]="wine" [winegcc]="wine"
                [xrandr]="xorg-xrandr"
                [pipewire]="pipewire" [ffmpeg]="ffmpeg"
                [pw-metadata]="pipewire" [kscreen-doctor]="libkscreen"
            )
            PKG_CHECK=(
                [pipewire-pulse]="pipewire-pulse"
                [pipewire-jack]="pipewire-jack"
                [pipewire-alsa]="pipewire-alsa"
                [wireplumber]="wireplumber"
                [gst-plugin-pipewire]="gst-plugin-pipewire"
                [libpipewire]="libpipewire"
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
    if [ "$SESSION_TYPE" != "x11" ]; then
        unset 'CMD_PKG[xrandr]'
    fi
    if [ "$SESSION_TYPE" != "plasma-wayland" ]; then
        unset 'CMD_PKG[kscreen-doctor]'
    fi
}

##
## UI helpers
##

ui_rule() {
    local width="${_CURRENT_UI_WIDTH:-80}"
    local rule
    printf -v rule '%*s' "$width" ''
    rule="${rule// /─}"
    echo -e "${BLU}${rule}${RST}"
}

ui_center() {
    local text="$1"
    local visible_length="$2"
    local width="${_CURRENT_UI_WIDTH:-80}"
    local padding=$(( (width - visible_length) / 2 ))
    [ "$padding" -lt 0 ] && padding=0
    printf '%*s%b\n' "$padding" '' "$text"
}

ui_phase() {
    local page_idx="$1"
    case "$page_idx" in
        0|1|2) echo "SETUP" ;;
        3) echo "INSTALL" ;;
        *) echo "FINISH" ;;
    esac
}

ui_install_dashboard() {
    [ "${UI_MAIN_PAGE_OVERRIDE:-}" = "3" ] || return 0
    local i state icon color
    for i in "${!INSTALL_TASK_NAMES[@]}"; do
        state="${INSTALL_TASK_STATES[$i]:-pending}"
        case "$state" in
            done) icon='✓'; color="$GRN" ;;
            running) icon='●'; color="$CYN" ;;
            failed) icon='✗'; color="$RED" ;;
            *) icon='·'; color="$BLU" ;;
        esac
        printf '  %b%s%b %s\n' "$color" "$icon" "$RST" "${INSTALL_TASK_NAMES[$i]}"
    done
    echo ""
}

ui_section() {
    echo -e "  ${BLD}$1${RST}"
    echo ""
}

ui_kv() {
    printf '  %-20s %b\n' "$1" "$2"
}

draw_header() {
    local page_idx="${UI_MAIN_PAGE_OVERRIDE:-$1}"
    local page_name="${PAGE_NAMES[$page_idx]}"
    if [ -n "${UI_ACTIVE_SUB_LABEL:-}" ]; then
        page_name="$page_name · $UI_ACTIVE_SUB_LABEL"
    fi
    local term_width
    local i
    term_width="$(tput cols 2>/dev/null || echo 80)"

    [[ "$term_width" =~ ^[0-9]+$ ]] || term_width=80
    [ "$term_width" -lt 20 ] && term_width=20

    local ui_width="$term_width"
    [ "$ui_width" -gt 100 ] && ui_width=100

    [ -t 1 ] && clear

    _CURRENT_TERM_WIDTH="$term_width"
    _CURRENT_UI_WIDTH="$ui_width"

    local phase
    phase="$(ui_phase "$page_idx")"
    local title="IIDX Linux Installer"
    if [ "$ui_width" -ge 32 ]; then
        local gap=$((ui_width - ${#title} - ${#phase} - 4))
        [ "$gap" -lt 1 ] && gap=1
        printf '  %b%s%b%*s%b%s%b\n' "$MAG$BLD" "$title" "$RST" "$gap" '' "$CYN$BLD" "$phase" "$RST"
    else
        printf '  %bIIDX Installer%b\n' "$MAG$BLD" "$RST"
    fi

    ui_rule

    local page_label="Step $((page_idx + 1))/$TOTAL_PAGES · $page_name"
    ui_center "${CYN}${BLD}${page_label}${RST}" "${#page_label}"

    local bar_width=$((ui_width - 8))
    [ "$bar_width" -gt 48 ] && bar_width=48
    [ "$bar_width" -lt 12 ] && bar_width=12
    local filled=$(( ((page_idx + 1) * bar_width) / TOTAL_PAGES ))
    local bar="${GRN}"
    for ((i=0; i<filled; i++)); do bar="${bar}█"; done
    bar="${bar}${YLW}"
    for ((i=filled; i<bar_width; i++)); do bar="${bar}░"; done
    bar="${bar}${RST}"
    ui_center "$bar" "$bar_width"

    ui_install_dashboard
    ui_rule
    echo ""
}

page_footer() {
    echo ""
    ui_rule
}

read_nav() {
    [ "${UI_AUTONEXT:-0}" = "1" ] && return 0
    if [ "$AUTO_YES" = "1" ]; then return 0; fi
    local input
    while true; do
        if [ "$UI_LOCK_BACK" = "1" ]; then
            echo -e "\n  ${BLD}Enter${RST} Continue   ${BLD}q${RST} Quit"
        else
            echo -e "\n  ${BLD}Enter${RST} Continue   ${BLD}b${RST} Back   ${BLD}q${RST} Quit"
        fi
        echo -en "  ${CYN}›${RST} "
        read -r input
        case "${input,,}" in
            "") return 0 ;;
            b)
                if [ "$UI_LOCK_BACK" = "1" ]; then
                    warn "Back navigation is unavailable after installation has started."
                else
                    return 1
                fi
                ;;
            q)  echo "Aborted."; exit 0 ;;
            *)  warn "Use Enter to continue, b to go back, or q to quit." ;;
        esac
    done
}

pop_page() {
    if [ ${#PAGE_HISTORY[@]} -gt 0 ]; then
        unset 'PAGE_HISTORY[-1]'
    fi
}

log()     { echo -e "  ${BLU}●${RST} $*"; }
warn()    { echo -e "  ${YLW}△${RST} $*"; }
die()     { echo -e "  ${RED}✗${RST} $*"; exit 1; }
success() { echo -e "  ${GRN}✓${RST} $*"; }

download_file() {
    # download_file "label" "url" "dest"
    local label="$1"
    local url="$2"
    local dest="$3"

    if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
        ui_run_with_spinner "Downloading $label" wget -q "$url" -O "$dest"
    else
        echo -e "  ${BLU}↓${RST} ${BLD}${label}${RST}"
        wget -q --show-progress "$url" -O "$dest"
    fi
    success "$label downloaded"
}

ui_spinner_start() {
    local label="$1"
    [ -t 1 ] || return 0
    [ "${TERM:-dumb}" != "dumb" ] || return 0
    [ -z "${UI_SPINNER_PID:-}" ] || return 0

    (
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local frame=0
        while :; do
            printf '\r\033[K  %b%s%b %s' "$CYN" "${frames[$frame]}" "$RST" "$label"
            frame=$(((frame + 1) % ${#frames[@]}))
            sleep 0.12
        done
    ) &
    UI_SPINNER_PID=$!
}

ui_spinner_stop() {
    local spinner_pid="${UI_SPINNER_PID:-}"
    [ -n "$spinner_pid" ] || return 0
    kill "$spinner_pid" 2>/dev/null || true
    wait "$spinner_pid" 2>/dev/null || true
    printf '\r\033[K'
    UI_SPINNER_PID=""
}

ui_run_with_spinner() {
    local label="$1"
    shift

    # Preserve normal command output in scripts, pipes, and basic terminals.
    if [ ! -t 1 ] || [ "${TERM:-dumb}" = "dumb" ]; then
        "$@"
        return $?
    fi

    local log_dir="${WORK_DIR:-${TMPDIR:-/tmp}}"
    local output_log
    output_log="$(mktemp "$log_dir/iidx-ui-XXXXXX")"
    "$@" >"$output_log" 2>&1 &
    local command_pid=$!
    ui_spinner_start "$label"

    local rc=0
    if wait "$command_pid"; then
        :
    else
        rc=$?
    fi
    ui_spinner_stop

    if [ "$rc" -ne 0 ]; then
        warn "$label failed (exit $rc); recent output:"
        tail -n 40 "$output_log"
    fi
    rm -f "$output_log"
    return "$rc"
}

confirm() {
    local msg="$1"
    local default="${2:-y}"
    if [ "$AUTO_YES" = "1" ]; then
        [ "$default" = "y" ] && return 0 || return 1
    fi
    local prompt
    [ "$default" = "y" ] && prompt="[Y/n]" || prompt="[y/N]"
    while true; do
        echo -en "  ${YLW}?${RST} $msg ${BLD}$prompt${RST} "
        read -r answer
        answer="${answer:-$default}"
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            b)
                if [ "$UI_LOCK_BACK" = "1" ]; then
                    warn "Back navigation is unavailable after installation has started."
                    continue
                fi
                return 2
                ;;
            q) echo "Aborted."; exit 0 ;;
            *) warn "Answer y/n, b to go back, or q to quit." ;;
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
    if [ "$AUTO_YES" = "1" ]; then
        if [ -n "$default" ]; then
            printf -v "$varname" '%s' "$default"
            return 0
        fi
        die "--yes requires --$varname to be set via CLI"
    fi
    local hint=""
    [ -n "$default" ] && hint=" ${BLU}(default: $default)${RST}"
    [ -n "$example" ] && hint="$hint ${BLU}e.g. $example${RST}"
    while true; do
        echo -en "  ${CYN}?${RST} $msg$hint: "
        read -r value
        case "${value,,}" in
            b)
                if [ "$UI_LOCK_BACK" = "1" ]; then
                    warn "Back navigation is unavailable after installation has started."
                    continue
                fi
                return 1
                ;;
            q) echo "Aborted."; exit 0 ;;
        esac
        value="${value:-$default}"
        value="$(expand_path "$value")"
        if [ -n "$value" ]; then
            printf -v "$varname" '%s' "$value"
            return 0
        fi
        warn "A value is required. Use b to go back or q to quit."
    done
}

##
## Arguments
##
GAME_STYLE=""
DUMP_PATH=""
MONITOR=""
SECONDARY_MONITOR=""
MONITOR_MGMT=""
BMSOUND_VER=""
SPICE_DATE=""
PROTON_VER="8.32"
GAME_RATE=""
GAME_RES=""
GAME_MODE_ID=""
ICON_SOURCE=""
DESKTOP_ICON=""
ASPHYXIA_URL=""
ASPHYXIA_PCBID=""
AUTO_YES=0
SESSION_TYPE=""
KSCREEN_OUTPUT_CACHE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --style)              GAME_STYLE="$2";           shift 2 ;;
        --dump)               DUMP_PATH="${2%/}";         shift 2 ;;
        --monitor)            MONITOR="$2"; MONITOR_MGMT=1; shift 2 ;;
        --secondary-monitor)  SECONDARY_MONITOR="$2"; MONITOR_MGMT=1; shift 2 ;;
        --bmsound-ver)        BMSOUND_VER="$2";           shift 2 ;;
        --spice-date)         SPICE_DATE="$2";            shift 2 ;;
        --proton-ver)         PROTON_VER="$2";            shift 2 ;;
        --rate)               GAME_RATE="$2"; MONITOR_MGMT=1; shift 2 ;;
        --icon)               ICON_SOURCE="$2";            shift 2 ;;
        --steam-home)         STEAM_HOME="$2";             shift 2 ;;
        --asphyxia-url)       ASPHYXIA_URL="$2";          shift 2 ;;
        --asphyxia-pcbid)     ASPHYXIA_PCBID="$2";         shift 2 ;;
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
if [ "$AUTO_YES" = "1" ] && ( [ -z "$GAME_STYLE" ] || [ -z "$DUMP_PATH" ] ); then
    die "--yes requires --style <NUM> and --dump <PATH>"
fi
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
    local monitor="${1:-$MONITOR}"
    xrandr 2>/dev/null | grep "^$monitor " -A1 | grep -oP '\d+x\d+(?=\+0\+0)' | head -1 || true
}

detect_rate() {
    local monitor="${1:-$MONITOR}"
    xrandr 2>/dev/null | grep "^$monitor " | grep -oP '\d+\.\d+(?=\*)' | head -1 || true
}

detect_compositor() {
    local stype="${XDG_SESSION_TYPE:-}"
    local desktop="${XDG_CURRENT_DESKTOP:-}:${DESKTOP_SESSION:-}"

    if [ -z "$stype" ]; then
        if [ -n "${WAYLAND_DISPLAY:-}" ]; then
            stype="wayland"
        elif [ -n "${DISPLAY:-}" ]; then
            stype="x11"
        else
            stype="unknown"
        fi
    fi

    case "$stype" in
        wayland)
            if [[ "${desktop,,}" == *kde* ]] || [[ "${desktop,,}" == *plasma* ]] || \
               [ "${KDE_FULL_SESSION:-}" = "true" ]; then
                echo "plasma-wayland"
                return
            fi
            if command -v hyprctl &>/dev/null && hyprctl monitors &>/dev/null 2>&1; then
                echo "hyprland"
                return
            fi
            # future: swaymsg, niri msg
            echo "wayland-unknown" ;;
        x11) echo "x11" ;;
        *) echo "session-unsupported" ;;
    esac
}

monitor_backend_supported() {
    case "$SESSION_TYPE" in
        x11|hyprland|plasma-wayland) return 0 ;;
        *) return 1 ;;
    esac
}

monitor_backend_ready() {
    case "$SESSION_TYPE" in
        x11)
            command -v xrandr &>/dev/null && xrandr --query &>/dev/null
            ;;
        hyprland)
            command -v hyprctl &>/dev/null && hyprctl monitors &>/dev/null
            ;;
        plasma-wayland)
            command -v kscreen-doctor &>/dev/null && refresh_kscreen_output
            ;;
        *) return 1 ;;
    esac
}

disable_monitor_management() {
    MONITOR_MGMT=0
    MONITOR=""
    SECONDARY_MONITOR=""
    GAME_RATE=""
    GAME_RES=""
    GAME_MODE_ID=""
}

## Hyprland-specific monitor helpers
list_monitors_hyprland() {
    hyprctl monitors all 2>/dev/null | grep "^Monitor " | awk '{print $2}'
}
hyprland_monitor_resolution() {
    hyprctl monitors all 2>/dev/null | grep -A1 "^Monitor $1 " | tail -1 | grep -oP '\d+x\d+(?=@)' || true
}
hyprland_monitor_rate() {
    hyprctl monitors all 2>/dev/null | grep -A1 "^Monitor $1 " | tail -1 | grep -oP '@\K[\d.]+' || true
}
monitor_list_hyprland() {
    list_monitors_hyprland
}
monitor_description_hyprland() {
    printf '%s\n' "$1"
}
monitor_exists_hyprland() {
    hyprctl monitors all 2>/dev/null | awk -v name="$1" '$1 == "Monitor" && $2 == name { found=1 } END { exit !found }'
}
monitor_resolution_hyprland() {
    hyprland_monitor_resolution "$1"
}
monitor_rate_hyprland() {
    hyprland_monitor_rate "$1"
}
## KDE Plasma Wayland monitor helpers (KScreen/KWin). The human-readable
## output is used here because jq is installed later on the dependency page.
refresh_kscreen_output() {
    KSCREEN_OUTPUT_CACHE="$(kscreen-doctor -o 2>/dev/null | sed $'s/\033\[[0-9;]*m//g')"
    grep -q '^Output:' <<< "$KSCREEN_OUTPUT_CACHE"
}
kscreen_output_text() {
    if [ -n "$KSCREEN_OUTPUT_CACHE" ]; then
        printf '%s\n' "$KSCREEN_OUTPUT_CACHE"
    else
        kscreen-doctor -o 2>/dev/null | sed $'s/\033\[[0-9;]*m//g'
    fi
}
list_monitors_plasma() {
    kscreen_output_text | awk '
        function print_connected() {
            if (name != "" && connected) print name
        }
        $1 == "Output:" {
            print_connected()
            name=$3
            connected=0
            next
        }
        $1 == "connected" { connected=1 }
        END { print_connected() }
    '
}
monitor_exists_plasma() {
    list_monitors_plasma | grep -Fxq -- "$1"
}
monitor_mode_plasma() {
    kscreen_output_text | awk -v name="$1" '
        $1 == "Output:" { selected=($3 == name) }
        selected && /Modes:/ && match($0, /[0-9]+x[0-9]+@[0-9.]+\*/) {
            mode=substr($0, RSTART, RLENGTH - 1)
            print mode
            exit
        }
    '
}
plasma_monitor_resolution() {
    local mode
    mode="$(monitor_mode_plasma "$1")"
    printf '%s\n' "${mode%@*}"
}
plasma_monitor_rate() {
    local mode
    mode="$(monitor_mode_plasma "$1")"
    printf '%s\n' "${mode##*@}"
}
monitor_mode_id_plasma() {
    local name="$1"
    local resolution="$2"
    local target_rate="$3"
    kscreen_output_text | awk -v name="$name" -v resolution="$resolution" -v target="$target_rate" '
        $1 == "Output:" { selected=($3 == name) }
        selected && /Modes:/ {
            best_diff=999999
            best_id=""
            for (i=1; i<=NF; i++) {
                token=$i
                sub(/[*!]+$/, "", token)
                parts=split(token, pair, ":")
                if (parts != 2) continue
                split(pair[2], spec, "@")
                if (spec[1] != resolution) continue
                diff=spec[2] - target
                if (diff < 0) diff=-diff
                if (diff < best_diff) {
                    best_diff=diff
                    best_id=pair[1]
                }
            }
            if (best_id != "" && best_diff <= 0.51) print best_id
            exit
        }
    '
}

monitor_list_plasma() {
    list_monitors_plasma
}
monitor_description_plasma() {
    printf '%s\n' "$1"
}
monitor_resolution_plasma() {
    plasma_monitor_resolution "$1"
}
monitor_rate_plasma() {
    plasma_monitor_rate "$1"
}
monitor_list_x11() {
    xrandr 2>/dev/null | awk '$2 == "connected" { print $1 }'
}
monitor_description_x11() {
    xrandr 2>/dev/null | awk -v name="$1" '$1 == name && $2 == "connected" { print $1 " - " $3; exit }'
}
monitor_exists_x11() {
    xrandr 2>/dev/null | awk -v name="$1" '$1 == name && $2 == "connected" { found=1 } END { exit !found }'
}
monitor_resolution_x11() {
    detect_resolution "$1"
}
monitor_rate_x11() {
    detect_rate "$1"
}
monitor_launcher_exec_hyprland() {
    local helper="$1" exec_base="$2" monitor="$3" resolution="$4"
    local refresh_rate="$5" secondary_monitor="$6" q_sec=""
    local q_mon="$(printf '%q' "$monitor")"
    local q_res="$(printf '%q' "$resolution")"
    local q_rate="$(printf '%q' "$refresh_rate")"
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
    if [ -n "$secondary_monitor" ]; then
        q_sec="$(printf '%q' "$secondary_monitor")"
        printf 'bash -c "f=$(mktemp /tmp/iidx-XXXXXX.sh); %s save \\"$f\\" && hyprctl keyword monitor %s,disable && hyprctl keyword monitor %s,%s@%s,auto,1 && %s; source \\"$f\\" 2>/dev/null || true; rm -f \\"$f\\""' "$helper" "$q_sec" "$q_mon" "$q_res" "$q_rate" "$exec_base"
    else
        printf 'bash -c "f=$(mktemp /tmp/iidx-XXXXXX.sh); %s save \\"$f\\" && hyprctl keyword monitor %s,%s@%s,auto,1 && %s; source \\"$f\\" 2>/dev/null || true; rm -f \\"$f\\""' "$helper" "$q_mon" "$q_res" "$q_rate" "$exec_base"
    fi
}

monitor_launcher_exec_plasma() {
    local helper="$1" exec_base="$2" monitor="$3" secondary_monitor="$6"
    local mode_id="$7" q_sec=""
    local q_mon="$(printf '%q' "$monitor")"
    local q_mode_id="$(printf '%q' "$mode_id")"
    cat > "$helper" <<'HELPER'
#!/bin/bash
set -u

case "${1:-}" in
    save)
        state_file="$2"
        kscreen-doctor --json > "$state_file"
        jq -e '.outputs | type == "array"' "$state_file" >/dev/null
        ;;
    restore)
        state_file="$2"
        [ -s "$state_file" ] || exit 1
        jq -e '.outputs | type == "array"' "$state_file" >/dev/null || exit 1
        mapfile -t args < <(jq -r '
            def rotation_name:
                if . == 1 then "none"
                elif . == 2 then "left"
                elif . == 4 then "inverted"
                elif . == 8 then "right"
                elif . == 16 then "flipped"
                elif . == 32 then "flipped90"
                elif . == 64 then "flipped180"
                elif . == 128 then "flipped270"
                else "none"
                end;
            .outputs[] | select(.connected == true) |
            .id as $id |
            if (if has("enabled") then .enabled else true end) then
                "output.\($id).enable",
                (if (.currentModeId | tostring | length) > 0 then
                    "output.\($id).mode.\(.currentModeId)"
                 else empty end),
                "output.\($id).position.\(.pos.x),\(.pos.y)",
                "output.\($id).scale.\(.scale // 1)",
                "output.\($id).rotation.\(.rotation | rotation_name)",
                (if (.priority // 0) > 0 then
                    "output.\($id).priority.\(.priority)"
                 else empty end)
            else
                "output.\($id).disable"
            end
        ' "$state_file")
        [ "${#args[@]}" -gt 0 ] && kscreen-doctor "${args[@]}"
        ;;
    *)
        echo "Usage: $0 {save|restore} STATE_FILE" >&2
        exit 2
        ;;
esac
HELPER
    chmod +x "$helper"
    if [ -n "$secondary_monitor" ]; then
        q_sec="$(printf '%q' "$secondary_monitor")"
        printf 'bash -c "f=$(mktemp /tmp/iidx-XXXXXX.json); %s save \\"$f\\" && kscreen-doctor output.%s.disable output.%s.enable output.%s.mode.%s output.%s.priority.1 && %s; %s restore \\"$f\\" 2>/dev/null || true; rm -f \\"$f\\""' "$helper" "$q_sec" "$q_mon" "$q_mon" "$q_mode_id" "$q_mon" "$exec_base" "$helper"
    else
        printf 'bash -c "f=$(mktemp /tmp/iidx-XXXXXX.json); %s save \\"$f\\" && kscreen-doctor output.%s.enable output.%s.mode.%s output.%s.priority.1 && %s; %s restore \\"$f\\" 2>/dev/null || true; rm -f \\"$f\\""' "$helper" "$q_mon" "$q_mon" "$q_mode_id" "$q_mon" "$exec_base" "$helper"
    fi
}

monitor_launcher_exec_x11() {
    local helper="$1" exec_base="$2" monitor="$3" resolution="$4"
    local refresh_rate="$5" secondary_monitor="$6" q_sec=""
    local q_mon="$(printf '%q' "$monitor")"
    local q_res="$(printf '%q' "$resolution")"
    local q_rate="$(printf '%q' "$refresh_rate")"
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
    if [ -n "$secondary_monitor" ]; then
        q_sec="$(printf '%q' "$secondary_monitor")"
        printf 'bash -c "f=$(mktemp /tmp/iidx-XXXXXX.sh); %s save \\"$f\\" && xrandr --output %s --off && xrandr --output %s --mode %s --rate %s && __GL_SYNC_DISPLAY_DEVICE=%s %s; source \\"$f\\" 2>/dev/null || true; rm -f \\"$f\\""' "$helper" "$q_sec" "$q_mon" "$q_res" "$q_rate" "$q_mon" "$exec_base"
    else
        printf 'bash -c "f=$(mktemp /tmp/iidx-XXXXXX.sh); %s save \\"$f\\" && xrandr --output %s --mode %s --rate %s && __GL_SYNC_DISPLAY_DEVICE=%s %s; source \\"$f\\" 2>/dev/null || true; rm -f \\"$f\\""' "$helper" "$q_mon" "$q_res" "$q_rate" "$q_mon" "$exec_base"
    fi
}

monitor_backend_call() {
    local operation="$1"
    shift
    local backend
    case "$SESSION_TYPE" in
        hyprland) backend="hyprland" ;;
        plasma-wayland) backend="plasma" ;;
        x11) backend="x11" ;;
        *) return 1 ;;
    esac
    case "$operation" in
        list|description|exists|resolution|rate|mode_id|launcher_exec) ;;
        *) return 2 ;;
    esac
    local handler="monitor_${operation}_${backend}"
    declare -F "$handler" >/dev/null || return 2
    "$handler" "$@"
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
    if [ "$PKG_MGR" != "pacman" ] && [ "$PKG_MGR" != "xbps" ]; then
        echo -e "    ${YLW}!${RST}  ${BLD}Arch and Void glibc are supported${RST} - other distros may need manual steps"
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
            echo -en "  ${CYN}?${RST} Select installation [1-${#found_list[@]}], or type a custom path: "
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

    if ! monitor_backend_supported; then
        warn "Session '$SESSION_TYPE' does not support automatic monitor management."
        warn "Monitor configuration will be skipped and the launcher will not change displays."
        disable_monitor_management
        page_footer
        read_nav || { pop_page; return; }
        return
    fi

    if [ -z "$MONITOR_MGMT" ]; then
        local ret=0
        confirm "Manage monitors automatically (resolution/rate switching, secondary disable)?" "n" || ret=$?
        if [ $ret -eq 0 ]; then
            MONITOR_MGMT=1
        elif [ $ret -eq 2 ]; then
            pop_page; return
        else
            MONITOR_MGMT=0
        fi
    fi

    if [ "$MONITOR_MGMT" = "0" ]; then
        disable_monitor_management
        page_footer
        read_nav || { pop_page; return; }
        return
    fi

    if ! monitor_backend_ready; then
        warn "The monitor backend for '$SESSION_TYPE' is not available in this session."
        case "$SESSION_TYPE" in
            plasma-wayland)
                warn "KDE Plasma Wayland requires a working kscreen-doctor (${CMD_PKG[kscreen-doctor]:-libkscreen})."
                ;;
            hyprland) warn "Hyprland monitor management requires a working hyprctl connection." ;;
            x11) warn "X11 monitor management requires a working xrandr connection." ;;
        esac
        warn "Monitor configuration will be skipped. Install/fix the backend and re-run the installer to enable it."
        disable_monitor_management
        page_footer
        read_nav || { pop_page; return; }
        return
    fi

    if [ -z "$MONITOR" ]; then
        echo -e "  ${BLD}Connected monitors:${RST}"
        local monitor_index=1
        local listed_monitor
        while IFS= read -r listed_monitor; do
            printf '    %s) %s\n' "$monitor_index" "$(monitor_backend_call description "$listed_monitor")"
            ((monitor_index++))
        done < <(monitor_backend_call list)
        echo ""
        while true; do
            prompt_value "Primary monitor name" MONITOR "" "DP-1" || { MONITOR=""; pop_page; return; }
            if monitor_backend_call exists "$MONITOR"; then
                break
            fi
            warn "Monitor '$MONITOR' not found. Use a name from the list above."
            MONITOR=""
        done
    else
        if ! monitor_backend_call exists "$MONITOR"; then
            die "Primary monitor '$MONITOR' is not connected in the current $SESSION_TYPE session."
        fi
        success "Primary monitor: $MONITOR"
    fi

    if [ -z "$SECONDARY_MONITOR" ]; then
        local others="$(monitor_backend_call list | grep -Fxv -- "$MONITOR" || true)"
        if [ -n "$others" ]; then
            echo ""
            echo -e "  Other connected monitors: ${BLD}$(echo "$others" | tr '\n' ' ')${RST}"
            warn "Multi-monitor setups can cause incorrect framerate in IIDX."
            case "$SESSION_TYPE" in
                hyprland|plasma-wayland|x11)
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
    fi

    if [ -n "$SECONDARY_MONITOR" ]; then
        if [ "$SECONDARY_MONITOR" = "$MONITOR" ]; then
            die "Primary and secondary monitor cannot both be '$MONITOR'."
        fi
        if ! monitor_backend_call exists "$SECONDARY_MONITOR"; then
            die "Secondary monitor '$SECONDARY_MONITOR' is not connected in the current $SESSION_TYPE session."
        fi
        success "Secondary monitor: $SECONDARY_MONITOR (will be disabled)"
    fi

    if [ -z "$GAME_RATE" ]; then
        echo ""
        local detected_rate="$(monitor_backend_call rate "$MONITOR")"
        log "Current refresh rate on $MONITOR: ${detected_rate:-unknown}hz"
        log "IIDX typically requires 120hz (60hz for some dumps/cabinets). The launcher will switch the primary monitor rate on every launch."
        echo ""
        prompt_value "Target game refresh rate (60 or 120 depending on dump)" GAME_RATE "120" "120" || { GAME_RATE=""; pop_page; return; }
    else
        success "Game refresh rate: ${GAME_RATE}hz"
    fi

    if [ -z "$GAME_RES" ]; then
        local detected_res="$(monitor_backend_call resolution "$MONITOR")"
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

    if [ "$SESSION_TYPE" = "plasma-wayland" ]; then
        GAME_MODE_ID="$(monitor_backend_call mode_id "$MONITOR" "$GAME_RES" "$GAME_RATE")"
        [ -n "$GAME_MODE_ID" ] || \
            die "KScreen has no ${GAME_RES}@${GAME_RATE}Hz mode for '$MONITOR'. Choose a supported resolution/rate."
        success "KScreen mode: $GAME_MODE_ID (${GAME_RES}@${GAME_RATE}hz)"
    fi

    page_footer
    read_nav || { MONITOR=""; SECONDARY_MONITOR=""; GAME_RATE=""; GAME_RES=""; pop_page; return; }
}

page_versions() {
    draw_header 4
    echo ""

    if [ -z "$BMSOUND_VER" ]; then
        ui_spinner_start "Checking bmsound_wine releases"
        BMSOUND_VER="$(fetch_latest_bmsound)"
        ui_spinner_stop
        [ -n "$BMSOUND_VER" ] || die "Could not fetch bmsound_wine version"
        success "bmsound_wine: $BMSOUND_VER"
    else
        success "bmsound_wine: $BMSOUND_VER (from argument)"
    fi

    if [ -z "$SPICE_DATE" ]; then
        ui_spinner_start "Checking spicetools releases"
        SPICE_DATE="$(fetch_latest_spice_date)"
        ui_spinner_stop
        [ -n "$SPICE_DATE" ] || die "Could not fetch spicetools date"
        success "spicetools date: $SPICE_DATE"
    else
        success "spicetools date: $SPICE_DATE (from argument)"
    fi

    SPICE_VER="${BMSOUND_VER}_${SPICE_DATE}"
    PROTON_DIR="proton-ge-${PROTON_VER//./-}-iidx${GAME_STYLE}"
    GAME_DIR="$STEAM_ROOT/steamapps/common/Beatmania IIDX $GAME_STYLE"
    if [ -z "${WORK_DIR:-}" ] || [ ! -d "$WORK_DIR" ]; then
        WORK_DIR="$(mktemp -d /tmp/iidx-install-XXXXXX)"
    fi

    success "proton-ge: $PROTON_VER (will be installed as $PROTON_DIR)"

    page_footer
    read_nav || { BMSOUND_VER=""; SPICE_DATE=""; pop_page; return; }
}

page_setup() {
    local baseline=${#PAGE_HISTORY[@]}
    local old_autonext="$UI_AUTONEXT"
    UI_MAIN_PAGE_OVERRIDE=1
    UI_AUTONEXT=1

    local labels=("Game and dump" "Steam library" "Display setup" "Component versions")
    local steps=(page_configuration page_steam page_monitor page_versions)
    local i
    for i in "${!steps[@]}"; do
        UI_ACTIVE_SUB_LABEL="${labels[$i]}"
        "${steps[$i]}"
        if [ ${#PAGE_HISTORY[@]} -lt "$baseline" ]; then
            UI_MAIN_PAGE_OVERRIDE=""
            UI_ACTIVE_SUB_LABEL=""
            UI_AUTONEXT="$old_autonext"
            return 0
        fi
    done

    UI_MAIN_PAGE_OVERRIDE=""
    UI_ACTIVE_SUB_LABEL=""
    UI_AUTONEXT="$old_autonext"
}

page_install() {
    local baseline=${#PAGE_HISTORY[@]}
    local old_autonext="$UI_AUTONEXT"
    UI_MAIN_PAGE_OVERRIDE=3
    UI_AUTONEXT=1
    UI_LOCK_BACK=1
    INSTALL_TASK_STATES=(pending pending pending pending pending pending pending pending pending)

    local steps=(page_deps page_groups page_base page_proton page_binaries page_game page_network page_verify page_launchers)
    local i
    for i in "${!steps[@]}"; do
        INSTALL_TASK_STATES[$i]=running
        UI_ACTIVE_SUB_LABEL="${INSTALL_TASK_NAMES[$i]}"
        "${steps[$i]}"
        if [ ${#PAGE_HISTORY[@]} -lt "$baseline" ]; then
            UI_MAIN_PAGE_OVERRIDE=""
            UI_ACTIVE_SUB_LABEL=""
            UI_AUTONEXT="$old_autonext"
            return 0
        fi
        INSTALL_TASK_STATES[$i]=done
    done

    UI_MAIN_PAGE_OVERRIDE=""
    UI_ACTIVE_SUB_LABEL=""
    UI_AUTONEXT="$old_autonext"
}

page_summary() {
    draw_header 2
    ui_section "Installation summary"
    ui_kv "Game style" "${BLD}${GRN}$GAME_STYLE${RST}"
    ui_kv "Dump path" "${BLD}$DUMP_PATH${RST}"
    if [ "$MONITOR_MGMT" = "1" ]; then
        ui_kv "Primary monitor" "${BLD}$MONITOR${RST}"
        [ -n "$SECONDARY_MONITOR" ] && \
            ui_kv "Secondary monitor" "${BLD}$SECONDARY_MONITOR${RST} ${YLW}(off during game)${RST}"
        ui_kv "Resolution" "${BLD}$GAME_RES @ ${GAME_RATE}hz${RST}"
    else
        ui_kv "Monitor management" "${YLW}disabled${RST}"
    fi
    ui_kv "bmsound_wine" "${BLD}$BMSOUND_VER${RST}"
    ui_kv "spicetools" "${BLD}$SPICE_VER${RST}"
    ui_kv "Proton-GE" "${BLD}$PROTON_VER${RST} → $PROTON_DIR"
    ui_kv "Steam home" "${BLD}$STEAM_HOME${RST}"
    ui_kv "Install base" "${BLD}$IIDX_BASE${RST}"
    ui_kv "Distro / PM" "${BLD}$DISTRO_NAME / ${PKG_MGR:-none}${RST}"
    echo ""
    warn "This will modify your system. Make sure everything above is correct."
    echo ""
    confirm "Proceed with installation?" "y" || { pop_page; return; }
}

ensure_void_multilib() {
    [ "$PKG_MGR" = "xbps" ] || return 0

    if "${PKG_QUERY[@]}" void-repo-multilib &>/dev/null; then
        success "Void multilib repository enabled"
        return 0
    fi

    echo ""
    warn "Void's multilib repository is required for Proton's 32-bit libraries."
    local ret=0
    confirm "Enable void-repo-multilib and refresh package indexes?" "y" || ret=$?
    if [ $ret -eq 0 ]; then
        local opts=(-Sy)
        [ "$AUTO_YES" = "1" ] && opts+=(-y)
        sudo xbps-install "${opts[@]}" void-repo-multilib
        success "Void multilib repository enabled"
    elif [ $ret -eq 2 ]; then
        pop_page
        return 1
    else
        die "Void multilib is required to install Proton's 32-bit libraries."
    fi
}

detect_gpu_vendors() {
    local vendor_file vendor
    local found=()

    if [ -n "${IIDX_GPU_VENDORS:-}" ]; then
        local overridden="${IIDX_GPU_VENDORS//,/ }"
        local override_vendors=()
        read -r -a override_vendors <<< "$overridden"
        printf '%s\n' "${override_vendors[@]}"
        return 0
    fi

    for vendor_file in /sys/class/drm/card*/device/vendor; do
        [ -r "$vendor_file" ] || continue
        read -r vendor < "$vendor_file"
        case "$vendor" in
            0x1002) [[ " ${found[*]} " == *" amd "* ]] || found+=(amd) ;;
            0x8086) [[ " ${found[*]} " == *" intel "* ]] || found+=(intel) ;;
            0x10de) [[ " ${found[*]} " == *" nvidia "* ]] || found+=(nvidia) ;;
        esac
    done

    printf '%s\n' "${found[@]}"
}

vulkan_package_pair_installed() {
    "${PKG_QUERY[@]}" "$1" &>/dev/null && "${PKG_QUERY[@]}" "$2" &>/dev/null
}

validate_vulkan() {
    case "$PKG_MGR" in
        pacman|xbps) ;;
        *) return 0 ;;
    esac

    echo ""
    echo -e "  ${BLD}Checking Vulkan prerequisites for ${DISTRO_NAME}...${RST}"

    local vulkan_missing=0
    local loader64 loader32
    if [ "$PKG_MGR" = "pacman" ]; then
        loader64="vulkan-icd-loader"
        loader32="lib32-vulkan-icd-loader"
    else
        loader64="vulkan-loader"
        loader32="vulkan-loader-32bit"
    fi

    local pkg
    for pkg in "$loader64" "$loader32"; do
        if "${PKG_QUERY[@]}" "$pkg" &>/dev/null; then
            success "$pkg"
        else
            warn "$pkg not installed"
            vulkan_missing=1
        fi
    done

    local vendors=()
    mapfile -t vendors < <(detect_gpu_vendors)
    if [ ${#vendors[@]} -eq 0 ]; then
        warn "Could not detect the GPU vendor from /sys/class/drm."
        warn "Verify that both the 64-bit and 32-bit Vulkan ICD for your GPU are installed."
        vulkan_missing=1
    fi

    local vendor expected64 expected32 alternative64 alternative32
    for vendor in "${vendors[@]}"; do
        alternative64=""
        alternative32=""
        case "$vendor" in
            amd)
                if [ "$PKG_MGR" = "pacman" ]; then
                    expected64="vulkan-radeon"
                    expected32="lib32-vulkan-radeon"
                else
                    expected64="mesa-vulkan-radeon"
                    expected32="mesa-vulkan-radeon-32bit"
                fi
                ;;
            intel)
                if [ "$PKG_MGR" = "pacman" ]; then
                    expected64="vulkan-intel"
                    expected32="lib32-vulkan-intel"
                else
                    expected64="mesa-vulkan-intel"
                    expected32="mesa-vulkan-intel-32bit"
                fi
                ;;
            nvidia)
                if [ "$PKG_MGR" = "pacman" ]; then
                    expected64="nvidia-utils"
                    expected32="lib32-nvidia-utils"
                    alternative64="vulkan-nouveau"
                    alternative32="lib32-vulkan-nouveau"
                else
                    expected64="nvidia-libs"
                    expected32="nvidia-libs-32bit"
                    alternative64="mesa-vulkan-nouveau"
                    alternative32="mesa-vulkan-nouveau-32bit"
                fi
                ;;
        esac

        if vulkan_package_pair_installed "$expected64" "$expected32" || \
           { [ -n "$alternative64" ] && vulkan_package_pair_installed "$alternative64" "$alternative32"; }; then
            success "$vendor Vulkan ICD (64-bit and 32-bit)"
        else
            warn "$vendor Vulkan ICD is incomplete. Suggested packages: $expected64 $expected32"
            [ -n "$alternative64" ] && \
                warn "Open-source alternative: $alternative64 $alternative32"
            [ "$vendor" = "nvidia" ] && [ "$PKG_MGR" = "xbps" ] && \
                warn "NVIDIA packages require void-repo-nonfree and void-repo-multilib-nonfree."
            vulkan_missing=1
        fi
    done

    if [ "$vulkan_missing" = "1" ]; then
        echo ""
        warn "Steam/Proton may fail without working 64-bit and 32-bit Vulkan drivers."
        confirm "Continue despite the incomplete Vulkan prerequisites?" "n" || \
            die "Install the suggested Vulkan packages and re-run the installer."
    else
        success "Vulkan prerequisites satisfied"
    fi
}

validate_void_pipewire() {
    [ "$PKG_MGR" = "xbps" ] || return 0

    echo ""
    echo -e "  ${BLD}Checking the Void PipeWire session...${RST}"
    if wpctl status >/dev/null 2>&1 || pw-metadata -n settings 0 >/dev/null 2>&1; then
        success "PipeWire and WirePlumber are active"
        return 0
    fi

    warn "PipeWire is installed but is not active in this user session."
    echo -e "  Void starts PipeWire through desktop autostart and configuration snippets, not systemd."
    echo -e "  Follow: ${CYN}https://docs.voidlinux.org/config/media/pipewire.html${RST}"
    echo -e "  Ensure WirePlumber and pipewire-pulse are enabled, then log out and back in."
    confirm "Continue despite the inactive PipeWire session?" "n" || \
        die "Configure/start PipeWire and re-run the installer."
}

verify_build_pkgconfig_modules() {
    case "$PKG_MGR" in
        pacman)
            local pipewire_pkg="libpipewire"
            local ffmpeg_pkg="ffmpeg"
            ;;
        xbps)
            local pipewire_pkg="pipewire-devel"
            local ffmpeg_pkg="ffmpeg6-devel"
            ;;
        *) return 0 ;;
    esac

    echo ""
    echo -e "  ${BLD}Checking bmsound_wine build interfaces...${RST}"

    command -v pkg-config &>/dev/null || die "pkg-config is required to validate build interfaces."

    local build_missing=0
    if pkg-config --exists libpipewire-0.3 libspa-0.2; then
        success "PipeWire development interfaces"
    else
        warn "Missing PipeWire development interfaces: libpipewire-0.3, libspa-0.2"
        warn "Required package: $pipewire_pkg"
        build_missing=1
    fi

    if pkg-config --exists libavformat libavcodec libavutil libswresample && \
       pkg-config --atleast-version=57 libavutil; then
        success "FFmpeg development interfaces"
    else
        warn "Missing or outdated FFmpeg development interfaces (libavutil 57+ required)."
        warn "Required modules: libavformat, libavcodec, libavutil, libswresample"
        warn "Required package: $ffmpeg_pkg"
        build_missing=1
    fi

    local wine_header_pkg="wine"
    local wine_header_test
    [ "$PKG_MGR" = "xbps" ] && wine_header_pkg="wine-devel"
    wine_header_test="$(mktemp /tmp/iidx-wine-header-XXXXXX.c)"
    printf '#include <windef.h>\n' > "$wine_header_test"
    if winegcc -E "$wine_header_test" >/dev/null 2>&1; then
        success "Wine development headers"
    else
        warn "Wine development header windef.h is unavailable to winegcc."
        warn "Required package: $wine_header_pkg"
        build_missing=1
    fi
    rm -f "$wine_header_test"

    [ "$build_missing" = "0" ] || die "bmsound_wine build dependencies are incomplete."
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

    ensure_void_multilib || return

    local missing=()
    for pkg in "${!WINE_DEPS[@]}"; do
        local pkgname="${WINE_DEPS[$pkg]}"
        if "${PKG_QUERY[@]}" "$pkgname" &>/dev/null; then
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
            local install_opts=( "${PKG_INSTALL_OPTS[@]}" )
            [ "$AUTO_YES" = "1" ] && install_opts+=("-y")
            sudo "${PKG_INSTALL[@]}" "${install_opts[@]}" "${missing[@]}"
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
        local manual="git, wget, curl, sha512sum, tar, jq, patch, make, gcc, cmake, pkg-config, winebuild"
        [ "$SESSION_TYPE" = "x11" ] && manual+=", xrandr"
        [ "$SESSION_TYPE" = "plasma-wayland" ] && [ "$MONITOR_MGMT" = "1" ] && manual+=", kscreen-doctor"
        warn "No supported package manager detected - skipping package checks."
        warn "Install required packages manually: $manual, pipewire, ffmpeg"
        page_footer
        read_nav || { pop_page; return; }
        return
    fi

    local missing_cmds=()
    local missing_pkgs=()

    local check_cmds=(git wget tar make gcc jq patch curl sha512sum pipewire ffmpeg pw-metadata)
    case "$PKG_MGR" in
        pacman) check_cmds+=(cmake pkg-config winebuild winegcc) ;;
        xbps) check_cmds+=(cmake pkg-config winebuild winegcc wpctl) ;;
    esac
    [ "$SESSION_TYPE" = "x11" ] && check_cmds+=(xrandr)
    [ "$SESSION_TYPE" = "plasma-wayland" ] && [ "$MONITOR_MGMT" = "1" ] && check_cmds+=(kscreen-doctor)
    for cmd in "${check_cmds[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            success "$cmd"
        else
            warn "$cmd not found (package: ${CMD_PKG[$cmd]:-$cmd})"
            missing_cmds+=("${CMD_PKG[$cmd]:-$cmd}")
        fi
    done

    for pkg in "${!PKG_CHECK[@]}"; do
        if "${PKG_QUERY[@]}" "${PKG_CHECK[$pkg]}" &>/dev/null; then
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
            local install_opts=( "${PKG_INSTALL_OPTS[@]}" )
            [ "$AUTO_YES" = "1" ] && install_opts+=("-y")
            sudo "${PKG_INSTALL[@]}" "${install_opts[@]}" "${all_missing[@]}"
            success "Packages installed"
            if [ "$PKG_MGR" != "xbps" ] && \
               { [[ " ${all_missing[*]} " == *"pipewire"* ]] || [[ " ${all_missing[*]} " == *"wireplumber"* ]]; }; then
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

    verify_build_pkgconfig_modules
    verify_wine_deps
    validate_vulkan
    validate_void_pipewire

    page_footer
    read_nav || { pop_page; return; }
}

page_groups() {
    draw_header 7
    echo -e "  Checking user group membership...\n"

    if ! getent group games >/dev/null 2>&1; then
        log "Creating required system group: games"
        sudo groupadd --system games
        success "Created group: games"
    fi

    local current_groups
    current_groups="$(id -nG "$USER")"
    local to_add=()
    local relogin_needed=0
    local groups_to_check=(games input realtime audio)

    if [ "$DISTRO_ID" = "void" ] && [ -d /run/elogind ]; then
        groups_to_check=(games input realtime)
        log "elogind detected; direct membership in 'audio' is not required on Void."
    fi

    local g
    for g in "${groups_to_check[@]}"; do
        if ! getent group "$g" >/dev/null 2>&1; then
            warn "Group not available: $g  (${GROUP_DESC[$g]})"
            [ "$g" = "realtime" ] && \
                warn "Low-latency scheduling requires an RT policy/limits setup; group membership alone is insufficient."
            continue
        fi
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

    if getent group realtime >/dev/null 2>&1; then
        warn "The realtime group only helps when matching PAM limits or another RT policy is configured."
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
        ui_run_with_spinner "Cloning automatization" \
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
    echo ""

    local proton_dest="$STEAM_ROOT/steamapps/common/$PROTON_DIR"
    local proton_tag="GE-Proton${PROTON_VER//./-}"
    local proton_archive="$WORK_DIR/${proton_tag}.tar.gz"
    local proton_checksum="$WORK_DIR/${proton_tag}.sha512sum"

    check_disk_space "$WORK_DIR" 1000 "temp dir"
    check_disk_space "$STEAM_ROOT" 3000 "Steam root"

    download_file "Proton-GE $proton_tag" \
        "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${proton_tag}/${proton_tag}.tar.gz" \
        "$proton_archive"
    download_file "Proton-GE checksum" \
        "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${proton_tag}/${proton_tag}.sha512sum" \
        "$proton_checksum"

    if ! ui_run_with_spinner "Verifying Proton-GE SHA-512 checksum" \
        bash -c 'cd "$1" && sha512sum -c "$2"' _ \
            "$WORK_DIR" "${proton_tag}.sha512sum"; then
        die "Proton-GE checksum verification failed; archive will not be extracted."
    fi
    success "Proton-GE checksum verified"

    ui_run_with_spinner "Extracting Proton-GE" \
        tar -xf "$proton_archive" -C "$WORK_DIR"
    mv "$WORK_DIR/$proton_tag" "$WORK_DIR/proton-ge"

    log "Applying patches..."
    (
        cd "$WORK_DIR/proton-ge"
        patch -p1 < "$AUTOMIZATION_DIR/proton-ge/proton.patch" || warn "Some hunks rejected (expected)"
        mkdir -p protonfixes/gamefixes
        cp "$AUTOMIZATION_DIR/proton-ge/000"*.py protonfixes/gamefixes/ 2>/dev/null || true
        cp "$AUTOMIZATION_DIR/proton-ge/000"*.py protonfixes/gamefixes-steam/ 2>/dev/null || true
    )
    rm -rf "$proton_dest"
    mv "$WORK_DIR/proton-ge" "$proton_dest"
    success "Proton-GE installed at $proton_dest"

    page_footer
    read_nav || { pop_page; return; }
}

page_binaries() {
    draw_header 10
    echo ""

    check_disk_space "$WORK_DIR" 2000 "temp dir"

    download_file "spicetools $SPICE_VER" \
        "https://codeberg.org/nixac/spicetools/releases/download/${SPICE_VER}/spicetools.tar.gz" \
        "$WORK_DIR/spicetools.tar.gz"
    mkdir -p "$WORK_DIR/spicetools"
    ui_run_with_spinner "Extracting spicetools" \
        tar -xf "$WORK_DIR/spicetools.tar.gz" -C "$WORK_DIR/spicetools"
    success "spicetools extracted"

    ui_run_with_spinner "Cloning bmsound_wine $BMSOUND_VER" \
        git clone https://codeberg.org/nixac/bmsound_wine "$WORK_DIR/bmsound_wine"
    (
        cd "$WORK_DIR/bmsound_wine"
        ui_run_with_spinner "Fetching bmsound_wine tags" git fetch --tags
        git checkout "tags/${BMSOUND_VER}"
        ui_run_with_spinner "Fetching bmsound_wine submodules" \
            git submodule update --init --recursive
        # Upstream defaults to x86_64-pc-linux-gnu-pkg-config, which is not
        # provided by Void. Use the validated native pkg-config command so the
        # PipeWire/SPA and FFmpeg include paths are passed to the compiler.
        # Build only the production artifacts: the generic "build" target also
        # compiles test programs that require unrelated development headers.
        ui_run_with_spinner "Compiling bmsound_wine" \
            make -Rs bmsound-pw@post bmsound-wine@post \
                TARGET_ARCH=x64 TARGET_TYPE=Release PKG_CONFIG=pkg-config
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

prepare_desktop_icon() {
    local icon_dir="$HOME/.local/share/icons"
    local png_icon="$icon_dir/iidx${GAME_STYLE}.png"
    local svg_icon="$icon_dir/iidx${GAME_STYLE}.svg"
    local source="${ICON_SOURCE:-}"
    local source_path=""
    local input="$WORK_DIR/iidx-icon-source"
    local converted_icon="$WORK_DIR/iidx-icon.png"
    local previous_icon=""
    local -a convert_cmd=()

    DESKTOP_ICON=""
    if [ -f "$HOME/.local/share/applications/iidx${GAME_STYLE}.desktop" ]; then
        previous_icon="$(sed -n 's/^Icon=//p' \
            "$HOME/.local/share/applications/iidx${GAME_STYLE}.desktop" | head -1)"
        [ -f "$previous_icon" ] && DESKTOP_ICON="$previous_icon"
    fi
    if [ -z "$DESKTOP_ICON" ]; then
        if [ -f "$png_icon" ]; then
            DESKTOP_ICON="$png_icon"
        elif [ -f "$svg_icon" ]; then
            DESKTOP_ICON="$svg_icon"
        fi
    fi

    [ -n "$source" ] || return 0

    if [[ "$source" =~ ^https?:// ]]; then
        if ! ui_run_with_spinner "Downloading desktop icon" \
            curl --fail --location --silent --show-error \
                --max-filesize 26214400 --output "$input" "$source"; then
            warn "Could not download the desktop icon; keeping any existing icon."
            return 0
        fi
        source_path="${source%%\?*}"
        source_path="${source_path%%\#*}"
    else
        source="$(expand_path "$source")"
        if [ ! -f "$source" ]; then
            warn "Icon file not found: $source; keeping any existing icon."
            return 0
        fi
        if ! cp -- "$source" "$input"; then
            warn "Could not read icon file: $source; keeping any existing icon."
            return 0
        fi
        source_path="$source"
    fi

    if ! mkdir -p "$icon_dir"; then
        warn "Could not create icon directory: $icon_dir"
        return 0
    fi

    # SVG is a desktop-entry standard icon format; keep it vector. For other
    # image formats, normalize through FFmpeg (already required by the installer)
    # so KDE/GNOME receive a portable PNG regardless of the source extension.
    if [[ "${source_path,,}" == *.svg ]] || \
        head -c 8192 "$input" | grep -Eiq '<svg([[:space:]>]|/)'; then
        if cp -- "$input" "$svg_icon"; then
            DESKTOP_ICON="$svg_icon"
            success "Desktop icon installed: $DESKTOP_ICON"
        else
            warn "Could not install SVG icon; keeping any existing icon."
        fi
    else
        # Prefer ImageMagick when available (it supports additional image
        # formats); FFmpeg is the guaranteed fallback dependency.
        if command -v magick >/dev/null 2>&1; then
            convert_cmd=(magick "${input}[0]" -auto-orient -resize '512x512>' "$converted_icon")
        elif command -v convert >/dev/null 2>&1; then
            convert_cmd=(convert "${input}[0]" -auto-orient -resize '512x512>' "$converted_icon")
        else
            convert_cmd=(ffmpeg -nostdin -v error -y -i "$input" -frames:v 1
                -vf "scale='min(512,iw)':'min(512,ih)':force_original_aspect_ratio=decrease"
                "$converted_icon")
        fi
    fi

    if [ "${#convert_cmd[@]}" -gt 0 ] && \
        ui_run_with_spinner "Converting desktop icon" "${convert_cmd[@]}"; then
        if mv -f -- "$converted_icon" "$png_icon"; then
            DESKTOP_ICON="$png_icon"
            success "Desktop icon installed: $DESKTOP_ICON"
        else
            warn "Could not install converted icon; keeping any existing icon."
        fi
    elif [ "${#convert_cmd[@]}" -gt 0 ]; then
        if [ -n "$DESKTOP_ICON" ]; then
            warn "Unsupported or invalid image; keeping the existing desktop icon."
        else
            warn "Unsupported or invalid image; the launchers will use the default icon."
        fi
    fi
}

page_launchers() {
    draw_header 14
    echo -e "  Creating .desktop launcher entries...\n"

    mkdir -p "$HOME/.local/share/applications"

    if [ -z "$ICON_SOURCE" ] && [ "$AUTO_YES" != "1" ]; then
        echo -e "  Optional desktop icon: enter a local image path or an HTTP(S) URL."
        echo -en "  ${CYN}?${RST} Icon path/URL (Enter to skip): "
        read -r ICON_SOURCE || ICON_SOURCE=""
        ICON_SOURCE="${ICON_SOURCE:-}"
    fi
    prepare_desktop_icon
    local desktop_icon_entry=""
    [ -n "$DESKTOP_ICON" ] && desktop_icon_entry="Icon=$DESKTOP_ICON"

    local q_auto="$(printf '%q' "$AUTOMIZATION_DIR")"
    local q_style="$(printf '%q' "$GAME_STYLE")"
    local q_root="$(printf '%q' "$STEAM_ROOT")"
    local exec_base="$q_auto/helper/ep_bm2dxnix $q_style --root $q_root"

    if [ "$MONITOR_MGMT" = "0" ]; then
        # Simple desktop entries without monitor switching
        cat > "$HOME/.local/share/applications/iidx${GAME_STYLE}.desktop" <<EOF
[Desktop Entry]
Name=Beatmania IIDX $GAME_STYLE
Exec=$exec_base
Type=Application
Categories=Game;
$desktop_icon_entry
EOF
        success "iidx${GAME_STYLE}.desktop created (no monitor mgmt)"

        cat > "$HOME/.local/share/applications/iidx${GAME_STYLE}-cfg.desktop" <<EOF
[Desktop Entry]
Name=Beatmania IIDX $GAME_STYLE (Config)
Exec=$exec_base --cfg
Type=Application
Categories=Game;
$desktop_icon_entry
EOF
        success "iidx${GAME_STYLE}-cfg.desktop created"

        page_footer
        read_nav || { pop_page; return; }
        return
    fi

    local q_mon="$(printf '%q' "$MONITOR")"
    local exec_game
    local helper="$AUTOMIZATION_DIR/helper/iidx-mon-state.sh"
    local launch_mode="${GAME_MODE_ID:-${GAME_RES}@${GAME_RATE}}"
    # launcher_exec arguments: helper, base command, primary, resolution, rate, secondary, backend mode.
    if ! exec_game="$(monitor_backend_call launcher_exec \
        "$helper" "$exec_base" "$MONITOR" "$GAME_RES" "$GAME_RATE" \
        "$SECONDARY_MONITOR" "$launch_mode")"; then
        warn "No safe monitor backend for '$SESSION_TYPE'; creating a direct launcher."
        disable_monitor_management
        exec_game="$exec_base"
    fi

    cat > "$HOME/.local/share/applications/iidx${GAME_STYLE}.desktop" <<EOF
[Desktop Entry]
Name=Beatmania IIDX $GAME_STYLE
Exec=$exec_game
Type=Application
Categories=Game;
$desktop_icon_entry
EOF
    success "iidx${GAME_STYLE}.desktop created"

    local exec_cfg="$exec_base --cfg"
    if [ "$MONITOR_MGMT" = "1" ]; then
        exec_cfg="bash -c \"__GL_SYNC_DISPLAY_DEVICE=$q_mon $exec_base --cfg\""
    fi
    cat > "$HOME/.local/share/applications/iidx${GAME_STYLE}-cfg.desktop" <<EOF
[Desktop Entry]
Name=Beatmania IIDX $GAME_STYLE (Config)
Exec=$exec_cfg
Type=Application
Categories=Game;
$desktop_icon_entry
EOF
    success "iidx${GAME_STYLE}-cfg.desktop created"

    page_footer
    read_nav || { pop_page; return; }
}

page_patches() {
    UI_MAIN_PAGE_OVERRIDE=4
    draw_header 4
    UI_MAIN_PAGE_OVERRIDE=""
    echo -e "  After installation, open spicecfg and go to the ${BLD}Patches${RST} tab.\n"
    echo -e "  ${BLD}First identify the game mode / DLL variant:${RST}\n"
    echo -e "    ${BLD}LDJ (012)${RST}  Standard/legacy mode, normally 60 Hz"
    echo -e "    ${BLD}TDJ (010)${RST}  Lightning Model mode, normally 120 Hz\n"
    echo -e "  The game code and filenames may still say ${BLD}LDJ${RST} in both cases."
    echo -e "  Use the 010/012 variant or the configured mode to tell them apart.\n"
    echo -e "  ${BLD}Patch guide for IIDX $GAME_STYLE:${RST}\n"
    echo -e "    ${GRN}✓${RST}  ${BLD}Wine fixes${RST}"
    echo -e "         Apply the fixes intended for Wine/Linux.\n"
    echo -e "    ${YLW}△${RST}  ${BLD}Bypass camera device error${RST}"
    echo -e "         Only if startup stops with CAMERA DEVICE ERROR.\n"
    echo -e "    ${YLW}△${RST}  ${BLD}Bypass Lightning Monitor Error${RST}"
    echo -e "         TDJ/Lightning mode (010) only, and only if startup stops"
    echo -e "         at the Lightning monitor check. It is not for LDJ (012).\n"
    echo -e "    ${RED}✗${RST}  ${BLD}WASAPI shared${RST}"
    echo -e "         Leave disabled with this Linux/PipeWire setup.\n"
    echo -e "  ${BLD}Refresh rate:${RST}\n"
    echo -e "    Match the game mode: normally 60 Hz for LDJ, 120 Hz for TDJ."
    echo -e "    You can set the selected mode using ${BLD}--rate${RST} or via the"
    echo -e "    installer's monitor page. When monitor management is enabled,"
    echo -e "    the desktop entry switches to that rate automatically on launch."
    echo -e "    Use a frame-rate patch only when deliberately changing that target.\n"
    echo ""
    warn "Start with the Wine fixes only."
    warn "Enable each bypass only if you encounter the exact error described above."

    page_footer
    read_nav || { pop_page; return; }
}

page_done() {
    UI_MAIN_PAGE_OVERRIDE=5
    draw_header 5
    UI_MAIN_PAGE_OVERRIDE=""
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
    echo -e "    ${CYN}4.${RST} To change server or cabinet ID later, edit:"
    echo -e "       ${BLD}$DUMP_PATH/contents/prop/linux.json${RST}"
    echo "         (look for the \"network\" section)"

    page_footer
    if [ "$AUTO_YES" != "1" ]; then
        echo -en "\n  Press Enter to exit."
        read -r
    fi
}

##
## Uninstaller
##
run_uninstaller() {
    [ -t 1 ] && clear
    echo -e "  ${RED}${BLD}IIDX Linux Installer · Uninstall${RST}"
    ui_rule
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

        if command -v systemctl >/dev/null 2>&1 && confirm "  Disable pipewire services?" "n"; then
            systemctl --user disable --now pipewire pipewire-pulse wireplumber 2>/dev/null || true
            echo -e "  ${GRN}✓${RST} Pipewire services disabled"
        elif command -v xbps-install >/dev/null 2>&1; then
            echo -e "  ${YLW}Void PipeWire autostart/configuration was not modified by this installer.${RST}"
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

##
## Main - pagination loop
##
main() {
    local pages=(
        page_intro
        page_setup
        page_summary
        page_install
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [ "$UNINSTALL" = "1" ]; then
        run_uninstaller
    else
        main
    fi
fi
