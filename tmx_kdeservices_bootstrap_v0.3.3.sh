from pathlib import Path

script = r'''#!/usr/bin/env bash
# ==================================================================================================
# TMX Mint RustDesk + Dropbear Interactive Bootstrap
# ==================================================================================================
# Purpose        : Near one-and-done interactive setup for RustDesk unattended access on Mint/Ubuntu
#                  plus optional Dropbear-initramfs scaffolding for LUKS remote unlock.
# Last Updated   : 2026-04-24 EST
# Requirements   : Debian/Ubuntu/Mint, systemd, apt, curl or wget, root
# Tested On      : Linux Mint / Ubuntu-family logic
# Author         : T. Dylan Maher
# Description    : Installs RustDesk from the latest GitHub release API, removes Flatpak copy
#                  optionally, enables unattended access, optionally enables headless mode, and
#                  can scaffold Dropbear-initramfs for encrypted-root remote unlock.
# Features       :
#                  - Interactive menu flow
#                  - Secure password prompt
#                  - Latest RustDesk .deb lookup via GitHub API
#                  - Optional Flatpak removal
#                  - Optional headless flag
#                  - Optional autostart/service enable
#                  - Optional Dropbear-initramfs install and key/config scaffolding
#                  - Main log + error log
# Caveats        :
#                  - Headless RustDesk is still distro/session-sensitive
#                  - Dropbear networking in initramfs is environment-specific
#                  - Review /etc/crypttab before enabling remote unlock
# Inputs         : Prompts
# Outputs        : Installed software, config files, logs
# Revision       : v0.2.0
# ==================================================================================================

set -u
set -o pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="v0.2.0"
RUN_TS="$(TZ=America/New_York date '+%Y-%m-%d_%H-%M-%S_EST')"

PREFERRED_LOG_DIR="./_logs"
FALLBACK_LOG_DIR="/tmp"
LOG_DIR="$PREFERRED_LOG_DIR"

if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    LOG_DIR="$FALLBACK_LOG_DIR"
    mkdir -p "$LOG_DIR"
fi

MAIN_LOG="${LOG_DIR}/tmx_rustdesk_dropbear_${SCRIPT_VERSION}_${RUN_TS}.log"
ERROR_LOG="${LOG_DIR}/tmx_rustdesk_dropbear_${SCRIPT_VERSION}_${RUN_TS}_errors.log"

touch "$MAIN_LOG" "$ERROR_LOG" || {
    echo "FATAL: couldn't create log files."
    exit 1
}

exec > >(tee -a "$MAIN_LOG") 2>&1

TMP_DIR="$(mktemp -d /tmp/tmx-rustdesk.XXXXXX)"
DEB_PATH="${TMP_DIR}/rustdesk.deb"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# -----------------------------
# IN: message text
# DO: print timestamped log line
# OUT: console + log transcript
# WHY: easier audit trail
# -----------------------------
log() {
    printf '[%s] %s\n' "$(TZ=America/New_York date '+%Y-%m-%d %H:%M:%S EST')" "$1"
}

# -----------------------------
# IN: error text
# DO: write to dedicated error log too
# OUT: visible + separated failure trail
# WHY: faster troubleshooting
# -----------------------------
log_error() {
    printf '[%s] %s\n' "$(TZ=America/New_York date '+%Y-%m-%d %H:%M:%S EST')" "$1" | tee -a "$ERROR_LOG"
}

# -----------------------------
# IN: none
# DO: enforce root
# OUT: stop if not root
# WHY: package install + system config need it
# -----------------------------
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Run with sudo or as root."
        echo "Example: sudo bash $SCRIPT_NAME"
        exit 1
    fi
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
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
            N|n|no|NO) return 1 ;;
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

ask_secret_confirm() {
    local prompt="$1"
    local first second
    while true; do
        read -r -s -p "$prompt: " first
        echo
        read -r -s -p "Confirm password: " second
        echo

        if [[ -z "$first" ]]; then
            echo "Password cannot be blank."
            continue
        fi

        if [[ "$first" != "$second" ]]; then
            echo "Passwords do not match."
            continue
        fi

        printf '%s' "$first"
        return 0
    done
}

get_latest_rustdesk_deb_url() {
    local api_url="https://api.github.com/repos/rustdesk/rustdesk/releases/latest"
    local json

    if have_cmd curl; then
        json="$(curl -fsSL "$api_url")" || return 1
    elif have_cmd wget; then
        json="$(wget -qO- "$api_url")" || return 1
    else
        return 1
    fi

    printf '%s\n' "$json" | grep -Eo 'https://[^"]+x86_64\.deb' | head -n 1
}

download_file() {
    local url="$1"
    local out="$2"

    if have_cmd curl; then
        curl -fL "$url" -o "$out"
    elif have_cmd wget; then
        wget -O "$out" "$url"
    else
        return 1
    fi
}

remove_flatpak_if_requested() {
    if [[ "$REMOVE_FLATPAK" != "yes" ]]; then
        log "Keeping any Flatpak RustDesk install."
        return 0
    fi

    if have_cmd flatpak; then
        log "Removing Flatpak RustDesk if present."
        flatpak uninstall -y com.rustdesk.RustDesk || true
    else
        log "Flatpak not installed; nothing to remove."
    fi
}

install_rustdesk() {
    local url
    log "Looking up latest RustDesk .deb."
    url="$(get_latest_rustdesk_deb_url)" || {
        log_error "Could not query latest RustDesk release."
        return 1
    }

    if [[ -z "$url" ]]; then
        log_error "Could not find x86_64 .deb asset."
        return 1
    fi

    log "Downloading $url"
    if ! download_file "$url" "$DEB_PATH"; then
        log_error "RustDesk download failed."
        return 1
    fi

    log "Running apt-get update."
    apt-get update || {
        log_error "apt-get update failed."
        return 1
    }

    log "Installing RustDesk .deb."
    apt-get install -fy "$DEB_PATH" || {
        log_error "RustDesk install failed."
        return 1
    }

    return 0
}

enable_rustdesk_service_if_present() {
    if [[ "$ENABLE_RUSTDESK_SERVICE" != "yes" ]]; then
        log "Skipping RustDesk service enable."
        return 0
    fi

    if systemctl list-unit-files | grep -q '^rustdesk\.service'; then
        log "Enabling rustdesk.service."
        systemctl enable --now rustdesk.service || log_error "Failed to enable rustdesk.service."
    else
        log "rustdesk.service not found; skipping service enable."
    fi
}

configure_rustdesk_password() {
    if [[ "$SET_RUSTDESK_PASSWORD" != "yes" ]]; then
        log "Skipping RustDesk unattended password."
        return 0
    fi

    local pw
    pw="$(ask_secret_confirm "Enter RustDesk unattended password")"

    if rustdesk --password "$pw"; then
        log "RustDesk unattended password set."
    else
        log_error "Failed to set RustDesk password."
    fi
}

configure_rustdesk_headless() {
    if [[ "$ENABLE_HEADLESS" != "yes" ]]; then
        log "Skipping headless mode."
        return 0
    fi

    if rustdesk --option allow-linux-headless Y; then
        log "Enabled RustDesk Linux headless option."
    else
        log_error "Failed to enable headless option."
    fi
}

show_rustdesk_id() {
    if have_cmd rustdesk; then
        if rustdesk --get-id >/dev/null 2>&1; then
            log "RustDesk ID: $(rustdesk --get-id)"
        else
            log_error "Could not retrieve RustDesk ID."
        fi
    fi
}

maybe_write_user_autostart_file() {
    if [[ "$CREATE_USER_AUTOSTART" != "yes" ]]; then
        log "Skipping user autostart desktop file."
        return 0
    fi

    local target_user target_home autostart_dir desktop_file
    target_user="${SUDO_USER:-}"
    if [[ -z "$target_user" ]]; then
        log "No SUDO_USER found; skipping per-user autostart file."
        return 0
    fi

    target_home="$(getent passwd "$target_user" | cut -d: -f6)"
    if [[ -z "$target_home" || ! -d "$target_home" ]]; then
        log_error "Could not resolve target home for $target_user."
        return 1
    fi

    autostart_dir="${target_home}/.config/autostart"
    desktop_file="${autostart_dir}/rustdesk.desktop"

    mkdir -p "$autostart_dir"

    cat > "$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=RustDesk
Exec=/usr/bin/rustdesk
X-GNOME-Autostart-enabled=true
NoDisplay=true
Terminal=false
Hidden=false
EOF

    chown -R "$target_user":"$target_user" "$autostart_dir"
    log "Created user autostart entry at $desktop_file"
}

detect_cryptroot_line() {
    grep -E '^[^#].+\s+/.+\s' /etc/crypttab 2>/dev/null | head -n 1 || true
}

install_dropbear_initramfs() {
    log "Installing Dropbear initramfs packages."
    apt-get update || log_error "apt-get update failed before dropbear install."
    apt-get install -y dropbear-initramfs cryptsetup-initramfs || {
        log_error "Failed to install dropbear-initramfs and/or cryptsetup-initramfs."
        return 1
    }
    return 0
}

configure_dropbear_authorized_keys() {
    local key_path="$1"
    local key_text

    mkdir -p /etc/dropbear/initramfs

    if [[ -f "$key_path" ]]; then
        cat "$key_path" > /etc/dropbear/initramfs/authorized_keys
        chmod 600 /etc/dropbear/initramfs/authorized_keys
        log "Installed Dropbear authorized_keys from $key_path"
        return 0
    fi

    echo "Paste ONE public key line for Dropbear initramfs access."
    read -r key_text
    printf '%s\n' "$key_text" > /etc/dropbear/initramfs/authorized_keys
    chmod 600 /etc/dropbear/initramfs/authorized_keys
    log "Installed Dropbear authorized_keys from pasted key."
}

write_dropbear_config() {
    local port="$1"

    mkdir -p /etc/dropbear/initramfs
    cat > /etc/dropbear/initramfs/dropbear.conf <<EOF
# TMX-generated dropbear-initramfs config
# Quiet default, no password auth, keys only
DROPBEAR_OPTIONS="-p ${port} -s -j -k -I 60"
EOF
    log "Wrote /etc/dropbear/initramfs/dropbear.conf"
}

maybe_update_crypttab_initramfs() {
    local line updated
    line="$(detect_cryptroot_line)"

    if [[ -z "$line" ]]; then
        log_error "Could not find a non-comment crypttab entry to patch. Review /etc/crypttab manually."
        return 1
    fi

    if grep -Eq '^[^#].+\binitramfs\b' /etc/crypttab; then
        log "crypttab already includes initramfs option on an active line."
        return 0
    fi

    if ask_yes_no "Append initramfs option to first active /etc/crypttab entry?" "Y"; then
        cp /etc/crypttab "/etc/crypttab.bak.${RUN_TS}"
        updated="$(awk '
            BEGIN{done=0}
            /^[[:space:]]*#/ {print; next}
            NF && done==0 {
                if ($4 == "" ) {$4="initramfs"}
                else {$4=$4",initramfs"}
                done=1
            }
            {print}
        ' /etc/crypttab)"
        printf '%s\n' "$updated" > /etc/crypttab
        log "Patched /etc/crypttab and saved backup /etc/crypttab.bak.${RUN_TS}"
    else
        log "Skipped /etc/crypttab patch. Review manually."
    fi
}

maybe_write_dropbear_ip_config() {
    if [[ "$DROPBEAR_NET_MODE" == "dhcp" ]]; then
        log "Leaving Dropbear initramfs networking on DHCP/default behavior."
        return 0
    fi

    local ip_line
    ip_line="$(ask_input "Enter full ip= kernel line for initramfs networking (for example ip=192.168.1.10::192.168.1.1:255.255.255.0:mintrepo:eth0:none)")"

    mkdir -p /etc/initramfs-tools/conf.d
    printf 'IP=%s\n' "$ip_line" > /etc/initramfs-tools/conf.d/dropbear-network.conf
    log "Wrote static initramfs network config to /etc/initramfs-tools/conf.d/dropbear-network.conf"
}

rebuild_initramfs() {
    log "Rebuilding initramfs."
    update-initramfs -u || {
        log_error "update-initramfs failed."
        return 1
    }
    return 0
}

print_menu() {
    echo
    echo "========================================================"
    echo " TMX Mint RustDesk + Dropbear Bootstrap ${SCRIPT_VERSION}"
    echo "========================================================"
    echo " 1) Toggle Flatpak removal                : $REMOVE_FLATPAK"
    echo " 2) Toggle RustDesk install               : $INSTALL_RUSTDESK"
    echo " 3) Toggle RustDesk service enable        : $ENABLE_RUSTDESK_SERVICE"
    echo " 4) Toggle RustDesk password set          : $SET_RUSTDESK_PASSWORD"
    echo " 5) Toggle RustDesk headless              : $ENABLE_HEADLESS"
    echo " 6) Toggle user autostart desktop entry   : $CREATE_USER_AUTOSTART"
    echo " 7) Toggle Dropbear-initramfs scaffold    : $INSTALL_DROPBEAR"
    echo " 8) Set Dropbear port                     : $DROPBEAR_PORT"
    echo " 9) Set Dropbear network mode             : $DROPBEAR_NET_MODE"
    echo "10) Set Dropbear public key path          : ${DROPBEAR_PUBKEY_PATH:-<paste manually>}"
    echo "11) Review selections"
    echo "12) Run"
    echo "13) Quit"
    echo
}

review_screen() {
    echo
    echo "=========================== REVIEW ==========================="
    echo " Flatpak removal              : $REMOVE_FLATPAK"
    echo " RustDesk install             : $INSTALL_RUSTDESK"
    echo " RustDesk service enable      : $ENABLE_RUSTDESK_SERVICE"
    echo " RustDesk password set        : $SET_RUSTDESK_PASSWORD"
    echo " RustDesk headless            : $ENABLE_HEADLESS"
    echo " User autostart entry         : $CREATE_USER_AUTOSTART"
    echo " Dropbear scaffold            : $INSTALL_DROPBEAR"
    echo " Dropbear port                : $DROPBEAR_PORT"
    echo " Dropbear network mode        : $DROPBEAR_NET_MODE"
    echo " Dropbear public key path     : ${DROPBEAR_PUBKEY_PATH:-<paste manually>}"
    echo
    echo " Main log                     : $MAIN_LOG"
    echo " Error log                    : $ERROR_LOG"
    echo "=============================================================="
    echo
}

main() {
    require_root

    REMOVE_FLATPAK="yes"
    INSTALL_RUSTDESK="yes"
    ENABLE_RUSTDESK_SERVICE="yes"
    SET_RUSTDESK_PASSWORD="yes"
    ENABLE_HEADLESS="no"
    CREATE_USER_AUTOSTART="no"
    INSTALL_DROPBEAR="no"
    DROPBEAR_PORT="4748"
    DROPBEAR_NET_MODE="dhcp"
    DROPBEAR_PUBKEY_PATH=""

    log "Starting $SCRIPT_NAME $SCRIPT_VERSION"
    log "Main log  : $MAIN_LOG"
    log "Error log : $ERROR_LOG"

    local choice
    while true; do
        print_menu
        choice="$(ask_input "Choose option" "11")"

        case "$choice" in
            1) [[ "$REMOVE_FLATPAK" == "yes" ]] && REMOVE_FLATPAK="no" || REMOVE_FLATPAK="yes" ;;
            2) [[ "$INSTALL_RUSTDESK" == "yes" ]] && INSTALL_RUSTDESK="no" || INSTALL_RUSTDESK="yes" ;;
            3) [[ "$ENABLE_RUSTDESK_SERVICE" == "yes" ]] && ENABLE_RUSTDESK_SERVICE="no" || ENABLE_RUSTDESK_SERVICE="yes" ;;
            4) [[ "$SET_RUSTDESK_PASSWORD" == "yes" ]] && SET_RUSTDESK_PASSWORD="no" || SET_RUSTDESK_PASSWORD="yes" ;;
            5) [[ "$ENABLE_HEADLESS" == "yes" ]] && ENABLE_HEADLESS="no" || ENABLE_HEADLESS="yes" ;;
            6) [[ "$CREATE_USER_AUTOSTART" == "yes" ]] && CREATE_USER_AUTOSTART="no" || CREATE_USER_AUTOSTART="yes" ;;
            7) [[ "$INSTALL_DROPBEAR" == "yes" ]] && INSTALL_DROPBEAR="no" || INSTALL_DROPBEAR="yes" ;;
            8) DROPBEAR_PORT="$(ask_input "Dropbear SSH port for initramfs" "$DROPBEAR_PORT")" ;;
            9)
                echo
                echo " 1) dhcp"
                echo " 2) static"
                while true; do
                    local net_choice
                    net_choice="$(ask_input "Choose Dropbear initramfs network mode" "1")"
                    case "$net_choice" in
                        1) DROPBEAR_NET_MODE="dhcp"; break ;;
                        2) DROPBEAR_NET_MODE="static"; break ;;
                        *) echo "Choose 1 or 2." ;;
                    esac
                done
                ;;
            10) DROPBEAR_PUBKEY_PATH="$(ask_input "Path to SSH public key for Dropbear (blank to paste manually)" "$DROPBEAR_PUBKEY_PATH")" ;;
            11) review_screen ;;
            12)
                review_screen
                if ask_yes_no "Proceed with these selections?" "Y"; then
                    break
                fi
                ;;
            13) echo "Exiting."; exit 0 ;;
            *) echo "Choose 1-13." ;;
        esac
    done

    if [[ "$INSTALL_RUSTDESK" == "yes" ]]; then
        remove_flatpak_if_requested
        install_rustdesk || true
        enable_rustdesk_service_if_present
        configure_rustdesk_password
        configure_rustdesk_headless
        maybe_write_user_autostart_file
        show_rustdesk_id
    fi

    if [[ "$INSTALL_DROPBEAR" == "yes" ]]; then
        install_dropbear_initramfs || true
        write_dropbear_config "$DROPBEAR_PORT"
        configure_dropbear_authorized_keys "$DROPBEAR_PUBKEY_PATH"
        maybe_update_crypttab_initramfs
        maybe_write_dropbear_ip_config
        rebuild_initramfs
        log "Dropbear initramfs scaffold complete. Test carefully before relying on it."
    fi

    log "Done."
    log "Main log  : $MAIN_LOG"
    log "Error log : $ERROR_LOG"
}

main "$@"

# 📜 REVISION HISTORY
#  File: tmx_mint_rustdesk_dropbear_bootstrap_v0.2.0.sh
#  ──────────────────────────────────────────────
#  v0.2.0  2026-04-24  T. Dylan Maher
#      • Added interactive RustDesk + Dropbear initramfs bootstrap flow
#      • Added latest GitHub release API lookup for RustDesk .deb
#      • Added secure password prompt and logging
#  ──────────────────────────────────────────────
'''
path = Path('/mnt/data/tmx_mint_rustdesk_dropbear_bootstrap_v0.2.0.sh')
path.write_text(script)
print(f"Wrote {path}")
