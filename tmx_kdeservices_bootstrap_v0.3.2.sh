#!/usr/bin/env bash
# ==================================================================================================
# TMX KDE-Services Interactive Bootstrap
# ==================================================================================================
# Purpose        : Interactive Kubuntu / Plasma 6 dependency bootstrapper and KDE-Services
#                  downloader / installer / uninstaller with logging and non-fatal package handling.
# Last Updated   : 2026-04-23 EST
# Requirements   : bash, apt-get, dpkg-query, cp, tar, wget or curl, xdg-utils,
#                  update-mime-database, KDE Plasma 6 target
# Tested On      : Kubuntu / Ubuntu family (APT-based, Plasma 6 target)
# Author         : T. Dylan Maher
# Description    : Prompts up front, shows a review screen, can download KDE-Services source,
#                  bootstrap dependencies, and install/uninstall KDE-Services using Plasma 6-style
#                  service menu paths. Script keeps going even when individual packages fail.
# Features       :
#                  - Numbered interactive menus
#                  - Package-group toggles
#                  - Final review / confirm screen
#                  - Dependency bootstrap
#                  - KDE-Services download
#                  - KDE-Services source auto-detection
#                  - KDE-Services install
#                  - KDE-Services uninstall
#                  - User-local or system-wide install target
#                  - Main log + error log
#                  - Failed package retry file
#                  - Non-fatal package installation failures
# Caveats        :
#                  - KDE-Services upstream tree must contain expected folders
#                  - Some packages may not exist on all Ubuntu releases
#                  - Uninstall removes files by filename from destination dirs
#                  - System-wide install may mix /usr and /usr/local paths for MIME/doc pieces
# Inputs         : Optional source path / download URL / download method
# Outputs        : Installed packages, downloaded source tree, copied service menus, logs
# Revision History:
#                  - v0.3.2 : Added KDE-Services download, source auto-detect, retry file
# ==================================================================================================

set -u
set -o pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="v0.3.2"
RUN_TS="$(TZ=America/New_York date '+%Y-%m-%d_%H-%M-%S_EST')"
START_EPOCH="$(date +%s)"

PREFERRED_LOG_DIR="./_logs"
FALLBACK_LOG_DIR="/tmp"
LOG_DIR="$PREFERRED_LOG_DIR"

if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    LOG_DIR="$FALLBACK_LOG_DIR"
    mkdir -p "$LOG_DIR"
fi

MAIN_LOG="${LOG_DIR}/tmx_kdeservices_bootstrap_${SCRIPT_VERSION}_${RUN_TS}.log"
ERROR_LOG="${LOG_DIR}/tmx_kdeservices_bootstrap_${SCRIPT_VERSION}_${RUN_TS}_errors.log"
RETRY_FILE="${LOG_DIR}/tmx_kdeservices_bootstrap_${SCRIPT_VERSION}_${RUN_TS}_failed_packages.txt"

touch "$MAIN_LOG" "$ERROR_LOG" "$RETRY_FILE" || {
    echo "FATAL: Could not create log files."
    exit 1
}

exec > >(tee -a "$MAIN_LOG") 2>&1

log() {
    local msg="$1"
    printf '[%s] %s\n' "$(TZ=America/New_York date '+%Y-%m-%d %H:%M:%S EST')" "$msg"
}

log_error() {
    local msg="$1"
    printf '[%s] %s\n' "$(TZ=America/New_York date '+%Y-%m-%d %H:%M:%S EST')" "$msg" | tee -a "$ERROR_LOG"
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local reply

    while true; do
        if [[ "$default" == "Y" ]]; then
            read -r -p "$prompt [Y/n]: " reply
            reply="${reply:-Y}"
        else
            read -r -p "$prompt [y/N]: " reply
            reply="${reply:-N}"
        fi

        case "$reply" in
            Y|y|yes|YES) return 0 ;;
            N|n|no|NO)   return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

ask_input() {
    local prompt="$1"
    local default="${2:-}"
    local reply

    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " reply
        reply="${reply:-$default}"
    else
        read -r -p "$prompt: " reply
    fi

    printf '%s' "$reply"
}

pause_enter() {
    read -r -p "Press Enter to continue..."
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Run this with sudo."
        echo "Example: sudo bash $SCRIPT_NAME"
        exit 1
    fi
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

is_installed() {
    local pkg="$1"
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"
}

install_pkg() {
    local pkg="$1"

    ((REQUESTED_COUNT++))

    if is_installed "$pkg"; then
        log "SKIP    : $pkg already installed"
        ((SKIPPED_COUNT++))
        return 0
    fi

    log "INSTALL : $pkg"
    if apt-get install -y "$pkg"; then
        log "OK      : $pkg"
        ((INSTALLED_COUNT++))
        SUCCESS_PKGS+=("$pkg")
    else
        log_error "FAILED  : $pkg"
        ((FAILED_COUNT++))
        FAILED_PKGS+=("$pkg")
        printf '%s\n' "$pkg" >> "$RETRY_FILE"
        return 1
    fi
}

install_fallback_choice() {
    local logical_name="$1"
    shift
    local options=("$@")

    ((REQUESTED_COUNT++))
    log "INSTALL : logical package [$logical_name] via fallback"

    local opt
    for opt in "${options[@]}"; do
        if is_installed "$opt"; then
            log "SKIP    : $opt already installed (logical: $logical_name)"
            ((SKIPPED_COUNT++))
            return 0
        fi
    done

    for opt in "${options[@]}"; do
        log "TRY     : $logical_name -> $opt"
        if apt-get install -y "$opt"; then
            log "OK      : $logical_name satisfied by $opt"
            ((INSTALLED_COUNT++))
            SUCCESS_PKGS+=("$opt")
            return 0
        fi
    done

    log_error "FAILED  : logical package [$logical_name] options tried: ${options[*]}"
    ((FAILED_COUNT++))
    FAILED_PKGS+=("$logical_name")
    printf '%s\n' "$logical_name" >> "$RETRY_FILE"
    return 1
}

install_group() {
    local group_name="$1"
    shift
    local pkgs=("$@")
    local pkg

    log "--------------------------------------------------------------------------------"
    log "GROUP   : $group_name"
    log "COUNT   : ${#pkgs[@]}"
    log "--------------------------------------------------------------------------------"

    for pkg in "${pkgs[@]}"; do
        install_pkg "$pkg" || true
    done
}

set_kdeservices_prefixes() {
    local scope="$1"

    if [[ "$scope" == "system" ]]; then
        PREFIXmenu6="/usr/share/kio/servicemenus"
        PREFIXservicetypes5="/usr/share/kservicetypes5"
        PREFIXapp="/usr/share/applications"
        PREFIXSVGicons="/usr/share/icons/hicolor/scalable/apps"
        PREFIXmime="/usr/local/share/mime/packages"
        PREFIXappmerge="/etc/xdg/menus/applications-merged"
        PREFIXdeskdir="/usr/share/desktop-directories"
        PREFIXdoc="/usr/local/share/doc/kde-services"
        MIME_DB_ROOT="/usr/local/share/mime"
        TARGET_HOME_NOTE="system-wide"
    else
        local target_home="$2"
        PREFIXmenu6="${target_home}/.local/share/kio/servicemenus"
        PREFIXservicetypes5="${target_home}/.local/share/kservicetypes5"
        PREFIXapp="${target_home}/.local/share/applications"
        PREFIXSVGicons="${target_home}/.local/share/icons/hicolor/scalable/apps"
        PREFIXmime="${target_home}/.local/share/mime/packages"
        PREFIXappmerge="${target_home}/.config/kdedefaults/menus/applications-merged"
        PREFIXdeskdir="${target_home}/.local/share/desktop-directories"
        PREFIXdoc="${target_home}/.local/share/doc/kde-services"
        MIME_DB_ROOT="${target_home}/.local/share/mime"
        TARGET_HOME_NOTE="$target_home"
    fi
}

create_prefix_dirs() {
    mkdir -p "$PREFIXmenu6" "$PREFIXservicetypes5" "$PREFIXapp" "$PREFIXSVGicons" \
             "$PREFIXmime" "$PREFIXappmerge" "$PREFIXdeskdir" "$PREFIXdoc"
}

copy_dir_contents() {
    local src="$1"
    local dst="$2"
    local label="$3"

    if [[ -d "$src" ]]; then
        mkdir -p "$dst"
        if compgen -G "$src/*" >/dev/null 2>&1; then
            cp -a "$src"/. "$dst"/
            log "OK      : copied $label -> $dst"
        else
            log "SKIP    : $label exists but empty"
        fi
    else
        log "SKIP    : missing source dir $src"
    fi
}

remove_dir_contents_by_source() {
    local src="$1"
    local dst="$2"
    local label="$3"

    if [[ ! -d "$src" ]]; then
        log "SKIP    : missing source dir for uninstall $src"
        return 0
    fi

    if [[ ! -d "$dst" ]]; then
        log "SKIP    : target dir absent $dst"
        return 0
    fi

    local f base removed_any=0
    shopt -s nullglob dotglob
    for f in "$src"/*; do
        base="$(basename "$f")"
        if [[ -e "$dst/$base" ]]; then
            rm -rf -- "$dst/$base"
            log "REMOVE  : $dst/$base"
            removed_any=1
        fi
    done
    shopt -u nullglob dotglob

    if [[ "$removed_any" -eq 0 ]]; then
        log "SKIP    : no matching files to remove for $label"
    fi
}

validate_kdeservices_tree() {
    local src_root="$1"
    local required_dirs=(
        "ServiceMenus"
        "applications"
        "desktop-directories"
        "doc"
    )

    local d
    for d in "${required_dirs[@]}"; do
        if [[ ! -d "$src_root/$d" ]]; then
            log_error "KDE-Services source dir missing required folder: $src_root/$d"
            return 1
        fi
    done

    return 0
}

auto_detect_kdeservices_tree() {
    local base="$1"

    if [[ -z "$base" ]]; then
        return 1
    fi

    if validate_kdeservices_tree "$base" >/dev/null 2>&1; then
        printf '%s\n' "$base"
        return 0
    fi

    local candidate
    while IFS= read -r -d '' candidate; do
        if validate_kdeservices_tree "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(find "$base" -maxdepth 3 -type d -print0 2>/dev/null)

    return 1
}

refresh_kde_caches() {
    log "Refreshing MIME / icon / desktop caches ..."

    if have_cmd xdg-mime && [[ -f "$PREFIXmime/kde-services.xml" ]]; then
        xdg-mime install --novendor "$PREFIXmime/kde-services.xml" \
            && log "OK      : xdg-mime install" \
            || log_error "FAILED  : xdg-mime install for kde-services.xml"
    else
        log "SKIP    : xdg-mime or kde-services.xml missing"
    fi

    if have_cmd update-mime-database && [[ -d "$MIME_DB_ROOT" ]]; then
        update-mime-database "$MIME_DB_ROOT" >/dev/null 2>&1 \
            && log "OK      : update-mime-database $MIME_DB_ROOT" \
            || log_error "FAILED  : update-mime-database $MIME_DB_ROOT"
    else
        log "SKIP    : update-mime-database missing"
    fi

    if have_cmd xdg-icon-resource; then
        xdg-icon-resource forceupdate --theme hicolor \
            && log "OK      : xdg-icon-resource forceupdate" \
            || log_error "FAILED  : xdg-icon-resource forceupdate"
    else
        log "SKIP    : xdg-icon-resource missing"
    fi

    if have_cmd xdg-desktop-menu; then
        xdg-desktop-menu forceupdate \
            && log "OK      : xdg-desktop-menu forceupdate" \
            || log_error "FAILED  : xdg-desktop-menu forceupdate"
    else
        log "SKIP    : xdg-desktop-menu missing"
    fi

    if have_cmd kbuildsycoca6; then
        kbuildsycoca6 \
            && log "OK      : kbuildsycoca6" \
            || log_error "FAILED  : kbuildsycoca6"
    elif have_cmd kbuildsycoca5; then
        kbuildsycoca5 \
            && log "OK      : kbuildsycoca5" \
            || log_error "FAILED  : kbuildsycoca5"
    else
        log "SKIP    : kbuildsycoca not found"
    fi
}

install_kdeservices() {
    local src_root="$1"
    local scope="$2"
    local target_home="$3"

    log "Starting KDE-Services install"
    log "Source   : $src_root"
    log "Scope    : $scope"

    validate_kdeservices_tree "$src_root" || return 1
    set_kdeservices_prefixes "$scope" "$target_home"
    create_prefix_dirs

    copy_dir_contents "$src_root/ServiceMenus"        "$PREFIXmenu6"         "ServiceMenus"
    copy_dir_contents "$src_root/servicetypes"        "$PREFIXservicetypes5" "servicetypes"
    copy_dir_contents "$src_root/applications"        "$PREFIXapp"           "applications"
    copy_dir_contents "$src_root/scalable/apps"       "$PREFIXSVGicons"      "scalable/apps"
    copy_dir_contents "$src_root/mime/text"           "$PREFIXmime"          "mime/text"
    copy_dir_contents "$src_root/applications-merged" "$PREFIXappmerge"      "applications-merged"
    copy_dir_contents "$src_root/desktop-directories" "$PREFIXdeskdir"       "desktop-directories"
    copy_dir_contents "$src_root/doc"                 "$PREFIXdoc"           "doc"

    refresh_kde_caches
    log "KDE-Services install finished -> $TARGET_HOME_NOTE"
    return 0
}

uninstall_kdeservices() {
    local src_root="$1"
    local scope="$2"
    local target_home="$3"

    log "Starting KDE-Services uninstall"
    log "Source   : $src_root"
    log "Scope    : $scope"

    validate_kdeservices_tree "$src_root" || return 1
    set_kdeservices_prefixes "$scope" "$target_home"

    remove_dir_contents_by_source "$src_root/ServiceMenus"        "$PREFIXmenu6"         "ServiceMenus"
    remove_dir_contents_by_source "$src_root/servicetypes"        "$PREFIXservicetypes5" "servicetypes"
    remove_dir_contents_by_source "$src_root/applications"        "$PREFIXapp"           "applications"
    remove_dir_contents_by_source "$src_root/scalable/apps"       "$PREFIXSVGicons"      "scalable/apps"
    remove_dir_contents_by_source "$src_root/mime/text"           "$PREFIXmime"          "mime/text"
    remove_dir_contents_by_source "$src_root/applications-merged" "$PREFIXappmerge"      "applications-merged"
    remove_dir_contents_by_source "$src_root/desktop-directories" "$PREFIXdeskdir"       "desktop-directories"
    remove_dir_contents_by_source "$src_root/doc"                 "$PREFIXdoc"           "doc"

    refresh_kde_caches
    log "KDE-Services uninstall finished -> $TARGET_HOME_NOTE"
    return 0
}

download_kdeservices() {
    local method="$1"
    local url="$2"
    local dest_dir="$3"

    mkdir -p "$dest_dir"

    log "Starting KDE-Services download"
    log "Method   : $method"
    log "URL      : $url"
    log "Dest dir : $dest_dir"

    case "$method" in
        git)
            if ! have_cmd git; then
                log_error "git not found"
                return 1
            fi

            local clone_dir="${dest_dir}/KDE-Services"
            if [[ -d "$clone_dir/.git" ]]; then
                log "Existing git repo found, pulling latest ..."
                if git -C "$clone_dir" pull --ff-only; then
                    KDE_SRC_ROOT="$clone_dir"
                    log "OK      : updated existing KDE-Services git repo"
                    return 0
                else
                    log_error "FAILED  : git pull in $clone_dir"
                    return 1
                fi
            else
                if git clone "$url" "$clone_dir"; then
                    KDE_SRC_ROOT="$clone_dir"
                    log "OK      : cloned KDE-Services repo"
                    return 0
                else
                    log_error "FAILED  : git clone $url"
                    return 1
                fi
            fi
            ;;

        tarball)
            local archive_path="${dest_dir}/kde-services_download_${RUN_TS}.tar.gz"
            local extract_dir="${dest_dir}/kde-services_extract_${RUN_TS}"

            mkdir -p "$extract_dir"

            if have_cmd wget; then
                wget -O "$archive_path" "$url" || {
                    log_error "FAILED  : wget download $url"
                    return 1
                }
            elif have_cmd curl; then
                curl -L "$url" -o "$archive_path" || {
                    log_error "FAILED  : curl download $url"
                    return 1
                }
            else
                log_error "Neither wget nor curl found"
                return 1
            fi

            if tar -xzf "$archive_path" -C "$extract_dir"; then
                log "OK      : extracted tarball -> $extract_dir"
            else
                log_error "FAILED  : extracting $archive_path"
                return 1
            fi

            local detected
            if detected="$(auto_detect_kdeservices_tree "$extract_dir")"; then
                KDE_SRC_ROOT="$detected"
                log "OK      : auto-detected KDE-Services source -> $KDE_SRC_ROOT"
                return 0
            else
                log_error "FAILED  : could not auto-detect KDE-Services tree in $extract_dir"
                return 1
            fi
            ;;

        *)
            log_error "Unknown download method: $method"
            return 1
            ;;
    esac
}

print_summary() {
    local end_epoch elapsed
    end_epoch="$(date +%s)"
    elapsed=$(( end_epoch - START_EPOCH ))

    log ""
    log "==================================== SUMMARY ===================================="
    log "Requested packages : $REQUESTED_COUNT"
    log "Installed now      : $INSTALLED_COUNT"
    log "Already present    : $SKIPPED_COUNT"
    log "Failed             : $FAILED_COUNT"
    log "Elapsed seconds    : $elapsed"
    log "Main log           : $MAIN_LOG"
    log "Error log          : $ERROR_LOG"
    log "Retry file         : $RETRY_FILE"
    log "================================================================================"

    if (( FAILED_COUNT > 0 )); then
        log ""
        log "Failed package list:"
        local pkg
        for pkg in "${FAILED_PKGS[@]}"; do
            log "  - $pkg"
        done
    fi
}

PKGS_CORE=(
    bash bc bzip2 cifs-utils coreutils diffutils dmidecode dvdauthor ffmpeg file findutils
    gawk genisoimage ghostscript gnupg htop iproute2 isomd5sum lynx mc mkvtoolnix net-tools
    perl procps psmisc pv recode sed shared-mime-info sox tar transcode unar util-linux
    wget wodim xdg-utils xterm yt-dlp zip curl tar
)

PKGS_SYSTEM=(
    android-sdk-platform-tools ovmf qemu-system-x86 qemu-utils fuse3 fuseiso encfs sshfs
    smbclient ssh-askpass git
)

PKGS_KDE=(
    konsole dolphin kde-runtime kde-baseapps-bin
)

PKGS_MEDIA=(
    imagemagick libcdio-utils fonts-liberation mailutils megatools mp3gain pdftk-java
    libimage-exiftool-perl poppler-utils vlc festival
)

PKGS_X11=(
    x11-xserver-utils xserver-xorg
)

run_dependency_bootstrap() {
    local run_any="no"

    log "Running apt-get update ..."
    if apt-get update; then
        log "apt-get update completed"
    else
        log_error "apt-get update failed - continuing anyway"
    fi

    if [[ "$ENABLE_GROUP_CORE" == "yes" ]]; then
        install_group "Core utilities" "${PKGS_CORE[@]}"
        run_any="yes"
    fi

    if [[ "$ENABLE_GROUP_SYSTEM" == "yes" ]]; then
        install_group "System / virtualization / fuse" "${PKGS_SYSTEM[@]}"
        run_any="yes"
    fi

    if [[ "$ENABLE_GROUP_KDE" == "yes" ]]; then
        install_group "KDE / Kubuntu desktop tools" "${PKGS_KDE[@]}"
        run_any="yes"
    fi

    if [[ "$ENABLE_GROUP_MEDIA" == "yes" ]]; then
        install_group "Media / imaging / document tools" "${PKGS_MEDIA[@]}"
        run_any="yes"
    fi

    if [[ "$ENABLE_GROUP_X11" == "yes" ]]; then
        install_group "X11 components" "${PKGS_X11[@]}"
        run_any="yes"
    fi

    if [[ "$ENABLE_GROUP_FALLBACKS" == "yes" ]]; then
        log "--------------------------------------------------------------------------------"
        log "GROUP   : Fallback-mapped packages"
        log "--------------------------------------------------------------------------------"

        install_fallback_choice "mlocate" "plocate" "mlocate" || true
        install_fallback_choice "poppler" "poppler-utils" "poppler-data" || true
        install_fallback_choice "kde-baseapps" "kde-baseapps-bin" "dolphin" || true
        install_fallback_choice "kde-runtime" "kde-runtime" "kio" || true
        install_fallback_choice "mailx" "bsd-mailx" "mailutils" || true
        install_fallback_choice "liberation-sans-fonts" "fonts-liberation" "fonts-liberation2" || true
        install_fallback_choice "kernel-tools" "linux-tools-generic" "linux-tools-common" || true
        install_fallback_choice "pdftk" "pdftk-java" || true
        install_fallback_choice "android-tools" "android-sdk-platform-tools" "adb" "fastboot" || true
        install_fallback_choice "ImageMagick" "imagemagick" || true
        install_fallback_choice "perl-Image-ExifTool" "libimage-exiftool-perl" || true
        install_fallback_choice "xorg-x11-server-utils" "x11-xserver-utils" || true
        install_fallback_choice "xorg-x11-server-Xorg" "xserver-xorg" || true
        install_fallback_choice "samba-client" "smbclient" || true
        install_fallback_choice "fuse-encfs" "encfs" || true
        install_fallback_choice "fuse-sshfs" "sshfs" || true
        install_fallback_choice "edk2-*" "ovmf" "ovmf-ia32" || true
        run_any="yes"
    fi

    if [[ "$run_any" == "no" ]]; then
        log "No dependency groups selected. Skipping dependency install."
    fi
}

print_main_menu() {
    echo
    echo "==============================================="
    echo " TMX KDE-Services Interactive Bootstrap v0.3.2"
    echo "==============================================="
    echo " 1) Toggle dependency bootstrap         : $DO_DEPS"
    echo " 2) Toggle KDE-Services download        : $DO_DOWNLOAD"
    echo " 3) Toggle KDE-Services install         : $DO_INSTALL"
    echo " 4) Toggle KDE-Services uninstall       : $DO_UNINSTALL"
    echo " 5) Set KDE-Services target scope       : $KDE_SCOPE"
    echo " 6) Set target user home                : ${KDE_USER_HOME:-<not set>}"
    echo " 7) Set KDE-Services source path        : ${KDE_SRC_ROOT:-<not set>}"
    echo " 8) Configure download options"
    echo " 9) Configure dependency groups"
    echo "10) Auto-detect source path now"
    echo "11) Review selections"
    echo "12) Run"
    echo "13) Quit"
    echo
}

configure_groups_menu() {
    local choice
    while true; do
        echo
        echo "-----------------------------------------------"
        echo " Dependency Group Toggles"
        echo "-----------------------------------------------"
        echo " 1) Core utilities                  : $ENABLE_GROUP_CORE"
        echo " 2) System / virtualization / fuse  : $ENABLE_GROUP_SYSTEM"
        echo " 3) KDE / Kubuntu desktop tools     : $ENABLE_GROUP_KDE"
        echo " 4) Media / imaging / docs          : $ENABLE_GROUP_MEDIA"
        echo " 5) X11 components                  : $ENABLE_GROUP_X11"
        echo " 6) Fallback mapped packages        : $ENABLE_GROUP_FALLBACKS"
        echo " 7) Enable all groups"
        echo " 8) Disable all groups"
        echo " 9) Back"
        echo

        choice="$(ask_input "Choose option" "9")"
        case "$choice" in
            1) [[ "$ENABLE_GROUP_CORE" == "yes" ]] && ENABLE_GROUP_CORE="no" || ENABLE_GROUP_CORE="yes" ;;
            2) [[ "$ENABLE_GROUP_SYSTEM" == "yes" ]] && ENABLE_GROUP_SYSTEM="no" || ENABLE_GROUP_SYSTEM="yes" ;;
            3) [[ "$ENABLE_GROUP_KDE" == "yes" ]] && ENABLE_GROUP_KDE="no" || ENABLE_GROUP_KDE="yes" ;;
            4) [[ "$ENABLE_GROUP_MEDIA" == "yes" ]] && ENABLE_GROUP_MEDIA="no" || ENABLE_GROUP_MEDIA="yes" ;;
            5) [[ "$ENABLE_GROUP_X11" == "yes" ]] && ENABLE_GROUP_X11="no" || ENABLE_GROUP_X11="yes" ;;
            6) [[ "$ENABLE_GROUP_FALLBACKS" == "yes" ]] && ENABLE_GROUP_FALLBACKS="no" || ENABLE_GROUP_FALLBACKS="yes" ;;
            7)
                ENABLE_GROUP_CORE="yes"
                ENABLE_GROUP_SYSTEM="yes"
                ENABLE_GROUP_KDE="yes"
                ENABLE_GROUP_MEDIA="yes"
                ENABLE_GROUP_X11="yes"
                ENABLE_GROUP_FALLBACKS="yes"
                ;;
            8)
                ENABLE_GROUP_CORE="no"
                ENABLE_GROUP_SYSTEM="no"
                ENABLE_GROUP_KDE="no"
                ENABLE_GROUP_MEDIA="no"
                ENABLE_GROUP_X11="no"
                ENABLE_GROUP_FALLBACKS="no"
                ;;
            9) break ;;
            *) echo "Choose 1-9." ;;
        esac
    done
}

configure_download_menu() {
    local choice
    while true; do
        echo
        echo "-----------------------------------------------"
        echo " KDE-Services Download Options"
        echo "-----------------------------------------------"
        echo " 1) Download method                 : $DOWNLOAD_METHOD"
        echo " 2) Download URL                    : $DOWNLOAD_URL"
        echo " 3) Download destination directory  : $DOWNLOAD_DEST"
        echo " 4) Back"
        echo

        choice="$(ask_input "Choose option" "4")"
        case "$choice" in
            1)
                echo
                echo " 1) git"
                echo " 2) tarball"
                local method_choice
                while true; do
                    method_choice="$(ask_input "Choose download method" "1")"
                    case "$method_choice" in
                        1) DOWNLOAD_METHOD="git"; break ;;
                        2) DOWNLOAD_METHOD="tarball"; break ;;
                        *) echo "Choose 1 or 2." ;;
                    esac
                done
                ;;
            2)
                DOWNLOAD_URL="$(ask_input "Set download URL" "$DOWNLOAD_URL")"
                ;;
            3)
                DOWNLOAD_DEST="$(ask_input "Set download destination directory" "$DOWNLOAD_DEST")"
                ;;
            4)
                break
                ;;
            *)
                echo "Choose 1-4."
                ;;
        esac
    done
}

review_screen() {
    echo
    echo "================================ REVIEW ================================="
    echo " Dependency bootstrap : $DO_DEPS"
    echo " KDE download         : $DO_DOWNLOAD"
    echo " KDE install          : $DO_INSTALL"
    echo " KDE uninstall        : $DO_UNINSTALL"
    echo " KDE scope            : $KDE_SCOPE"
    echo " Target home          : ${KDE_USER_HOME:-<not set>}"
    echo " Source path          : ${KDE_SRC_ROOT:-<not set>}"
    echo
    echo " Download options:"
    echo "   Method             : $DOWNLOAD_METHOD"
    echo "   URL                : $DOWNLOAD_URL"
    echo "   Destination        : $DOWNLOAD_DEST"
    echo
    echo " Dependency groups:"
    echo "   Core               : $ENABLE_GROUP_CORE"
    echo "   System             : $ENABLE_GROUP_SYSTEM"
    echo "   KDE                : $ENABLE_GROUP_KDE"
    echo "   Media              : $ENABLE_GROUP_MEDIA"
    echo "   X11                : $ENABLE_GROUP_X11"
    echo "   Fallbacks          : $ENABLE_GROUP_FALLBACKS"
    echo
    echo " Main log             : $MAIN_LOG"
    echo " Error log            : $ERROR_LOG"
    echo " Retry file           : $RETRY_FILE"
    echo "========================================================================="
    echo
}

main() {
    require_root

    REQUESTED_COUNT=0
    INSTALLED_COUNT=0
    SKIPPED_COUNT=0
    FAILED_COUNT=0
    SUCCESS_PKGS=()
    FAILED_PKGS=()

    DO_DEPS="yes"
    DO_DOWNLOAD="yes"
    DO_INSTALL="yes"
    DO_UNINSTALL="no"

    KDE_SCOPE="user"
    KDE_USER_HOME="${SUDO_HOME:-${HOME}}"
    KDE_SRC_ROOT="$PWD"

    DOWNLOAD_METHOD="git"
    DOWNLOAD_URL="https://github.com/geobarrod/KDE-Services.git"
    DOWNLOAD_DEST="${PWD}/_downloads"

    ENABLE_GROUP_CORE="yes"
    ENABLE_GROUP_SYSTEM="yes"
    ENABLE_GROUP_KDE="yes"
    ENABLE_GROUP_MEDIA="yes"
    ENABLE_GROUP_X11="yes"
    ENABLE_GROUP_FALLBACKS="yes"

    log "Starting $SCRIPT_NAME $SCRIPT_VERSION"
    log "Main log  : $MAIN_LOG"
    log "Error log : $ERROR_LOG"
    log "Retry file: $RETRY_FILE"

    local choice detected
    while true; do
        print_main_menu
        choice="$(ask_input "Choose option" "11")"

        case "$choice" in
            1) [[ "$DO_DEPS" == "yes" ]] && DO_DEPS="no" || DO_DEPS="yes" ;;
            2) [[ "$DO_DOWNLOAD" == "yes" ]] && DO_DOWNLOAD="no" || DO_DOWNLOAD="yes" ;;
            3) [[ "$DO_INSTALL" == "yes" ]] && DO_INSTALL="no" || DO_INSTALL="yes" ;;
            4) [[ "$DO_UNINSTALL" == "yes" ]] && DO_UNINSTALL="no" || DO_UNINSTALL="yes" ;;
            5)
                echo
                echo " 1) user-local"
                echo " 2) system-wide"
                local scope_choice
                while true; do
                    scope_choice="$(ask_input "Choose target scope" "1")"
                    case "$scope_choice" in
                        1) KDE_SCOPE="user"; break ;;
                        2) KDE_SCOPE="system"; break ;;
                        *) echo "Choose 1 or 2." ;;
                    esac
                done
                ;;
            6)
                KDE_USER_HOME="$(ask_input "Target user's home for local install" "$KDE_USER_HOME")"
                ;;
            7)
                KDE_SRC_ROOT="$(ask_input "Path to KDE-Services source tree or parent directory" "$KDE_SRC_ROOT")"
                ;;
            8)
                configure_download_menu
                ;;
            9)
                configure_groups_menu
                ;;
            10)
                if detected="$(auto_detect_kdeservices_tree "$KDE_SRC_ROOT")"; then
                    KDE_SRC_ROOT="$detected"
                    echo "Detected KDE-Services source tree: $KDE_SRC_ROOT"
                    log "Auto-detected KDE-Services source tree -> $KDE_SRC_ROOT"
                else
                    echo "Could not auto-detect a valid KDE-Services source tree under: $KDE_SRC_ROOT"
                    log_error "Auto-detect failed under $KDE_SRC_ROOT"
                fi
                pause_enter
                ;;
            11)
                review_screen
                pause_enter
                ;;
            12)
                review_screen
                if ask_yes_no "Proceed with these selections?" "Y"; then
                    break
                fi
                ;;
            13)
                echo "Exiting."
                exit 0
                ;;
            *)
                echo "Choose 1-13."
                ;;
        esac
    done

    log "Selections confirmed"
    log "  Dependency bootstrap : $DO_DEPS"
    log "  KDE download         : $DO_DOWNLOAD"
    log "  KDE-Services install : $DO_INSTALL"
    log "  KDE-Services remove  : $DO_UNINSTALL"
    log "  KDE scope            : $KDE_SCOPE"
    log "  KDE home             : $KDE_USER_HOME"
    log "  KDE source           : $KDE_SRC_ROOT"
    log "  Download method      : $DOWNLOAD_METHOD"
    log "  Download URL         : $DOWNLOAD_URL"
    log "  Download dest        : $DOWNLOAD_DEST"

    if [[ "$DO_DEPS" == "yes" ]]; then
        run_dependency_bootstrap
    fi

    if [[ "$DO_DOWNLOAD" == "yes" ]]; then
        download_kdeservices "$DOWNLOAD_METHOD" "$DOWNLOAD_URL" "$DOWNLOAD_DEST" || true
    fi

    if detected="$(auto_detect_kdeservices_tree "$KDE_SRC_ROOT")"; then
        KDE_SRC_ROOT="$detected"
        log "Using auto-detected source tree -> $KDE_SRC_ROOT"
    elif [[ "$DO_INSTALL" == "yes" || "$DO_UNINSTALL" == "yes" ]]; then
        log_error "No valid KDE-Services source tree detected. Install/uninstall may fail."
    fi

    if [[ "$DO_UNINSTALL" == "yes" ]]; then
        uninstall_kdeservices "$KDE_SRC_ROOT" "$KDE_SCOPE" "${KDE_USER_HOME:-}"
    fi

    if [[ "$DO_INSTALL" == "yes" ]]; then
        install_kdeservices "$KDE_SRC_ROOT" "$KDE_SCOPE" "${KDE_USER_HOME:-}"
    fi

    print_summary
}

main "$@"

# ==================================================================================================
# REVISION HISTORY
# ==================================================================================================
# File     : tmx_kdeservices_bootstrap_v0.3.2.sh
# Version  : v0.3.2
# Date     : 2026-04-23 EST
# Author   : T. Dylan Maher
# Changes  :
#   - Added KDE-Services download support via git or tarball
#   - Added source auto-detection
#   - Added failed package retry file
#   - Kept Plasma 6-style service menu paths as primary target
# ==================================================================================================
