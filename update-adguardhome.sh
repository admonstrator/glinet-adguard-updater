#!/bin/sh
# shellcheck shell=ash
# shellcheck disable=SC3036
# NOTE: 'echo $SHELL' reports '/bin/ash' on the routers, see:
# - https://en.wikipedia.org/wiki/Almquist_shell#Embedded_Linux
# - https://github.com/koalaman/shellcheck/issues/1841
#
# Description: This script updates AdGuardHome to the latest version.
# Thread: https://forum.gl-inet.com/t/how-to-update-adguard-home-testing/39398
# Author: Admon
SCRIPT_VERSION="2026.10.08.01"
SCRIPT_NAME="update-adguardhome.sh"
UPDATE_URL="https://app.gl-i.net/adguard-update"
#
# Usage: ./update-adguardhome.sh [--ignore-free-space] [--select-release] [--testing]
#                                [--restore] [--force] [--force-upgrade] [--log] [--help]
# Warning: This script might potentially harm your router. Use it at your own risk.
#

# ==============================================================================
# Variables & Constants
# ==============================================================================

# User Preferences (Defaults)
IGNORE_FREE_SPACE=0
SELECT_RELEASE=0
TESTING=0
RESTORE=0
FORCE=0
FORCE_UPGRADE=0
SHOW_LOG=0

# Runtime Variables
ARCH=""
MODEL=""
AGH_ARCH=""
FIRMWARE_VERSION=0
CHANNEL_NAME="stable"
AGH_VERSION_NEW=""
AGH_VERSION_OLD=""
BACKUP_PATH=""
AGH_WAS_RUNNING=0
DNS_WAN_ONLY=0
DNS_ROUTING_ACTION="none"
USER_WANTS_QUERYLOG="n"
USER_WANTS_PERSISTENCE="n"

# Constants - Paths
AGH_BIN="/usr/bin/AdGuardHome"
AGH_BIN_OLD="/usr/bin/AdGuardHome.old"
AGH_CONFIG_DIR="/etc/AdGuardHome"
AGH_INIT_SCRIPT="/etc/init.d/adguardhome"
AGH_UPDATE_CHECK_SCRIPT="/usr/bin/enable-adguardhome-update-check"
BACKUP_DIR="/root/AdGuardHome_config_backup"
LEGACY_BACKUP_FILE="/root/AdGuardHome_backup.tar.gz"
RC_LOCAL="/etc/rc.local"
SYSUPGRADE_CONF="/etc/sysupgrade.conf"
TEMP_FILE="/tmp/AdGuardHomeNew"
TEMP_CHECKSUMS="/tmp/AdGuardHomeNew.sha256"
# Seconds to wait for AdGuard Home to come up after a restart. A fixed sleep
# is not enough on slow devices like the GL-MT1300.
AGH_RESTART_TIMEOUT="${AGH_RESTART_TIMEOUT:-15}"

# Constants - Detection sources, overridable so the detection can be tested
# without a router
GL_VERSION_FILE="${GL_VERSION_FILE:-/etc/glversion}"
GL_MODEL_FILE="${GL_MODEL_FILE:-/proc/gl-hw-info/model}"
CPUINFO_FILE="${CPUINFO_FILE:-/proc/cpuinfo}"

# Constants - Release channels
# The stable channel resolves to the newest GitHub release. GitHub excludes
# prereleases from /releases/latest, so the testing builds are invisible here.
AGH_REPO="Admonstrator/glinet-adguard-updater"
AGH_STABLE_URL="https://github.com/$AGH_REPO/releases/latest/download"
AGH_TESTING_URL="https://github.com/$AGH_REPO/releases/download/prerelease"
# The active channel. --testing and --select-release replace it.
AGH_TINY_URL="$AGH_STABLE_URL"

# Constants - Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
INFO='\033[0m' # No Color

# ==============================================================================
# Helper Functions
# ==============================================================================

log() {
    local level="$1"
    local message="$2"
    local color="$INFO"
    local symbol=""
    local prefix=""

    # Assign color and symbol based on level
    case "$level" in
    ERROR)
        color="$RED"
        symbol="[X] "
        ;;
    WARNING)
        color="$YELLOW"
        symbol="[!] "
        ;;
    SUCCESS)
        color="$GREEN"
        symbol="[OK] "
        ;;
    INFO)
        symbol="[->] "
        ;;
    esac

    if [ "$SHOW_LOG" -eq 1 ]; then
        prefix="[$(date +"%Y-%m-%d %H:%M:%S")] "
    fi

    # %s for the message so a percent sign in it is never a format directive
    printf '%b%s%s%s%b\n' "$color" "$prefix" "$symbol" "$message" "$INFO"
}

agh_version() {
    # Prints the version of an AdGuard Home binary, e.g. v0.107.79 or v1.0.0-b.1
    "$1" --version 2>/dev/null | awk '{print $NF}'
}

agh_is_running() {
    pgrep AdGuardHome >/dev/null 2>&1
}

is_testing_version() {
    # $1 = version string. Upstream marks prereleases with a -b.N suffix.
    case "$1" in
    *-b.*) return 0 ;;
    *) return 1 ;;
    esac
}

confirm_or_exit() {
    local answer
    if [ "$FORCE" -eq 1 ]; then
        log "WARNING" "--force is used, continuing without asking: $1"
        return 0
    fi
    log "WARNING" "$1 (y/N)"
    read -r answer
    if [ "$answer" = "${answer#[Yy]}" ]; then
        log "ERROR" "Ok, see you next time!"
        exit 0
    fi
}

remove_lines() {
    # $1 = file, $2 = fixed string. Rewrites the file without the matching lines
    # and keeps its permissions. Used instead of sed so paths need no escaping.
    local tmp
    local rc
    [ -f "$1" ] || return 0
    tmp="/tmp/.agh-lines.$$"
    grep -vF "$2" "$1" >"$tmp" 2>/dev/null
    rc=$?
    # grep exits 1 when nothing is left, which is a valid result here
    if [ "$rc" -le 1 ]; then
        cat "$tmp" >"$1"
    fi
    rm -f "$tmp"
}

verify_sha256() {
    # $1 = local file, $2 = name as listed in the checksum file, $3 = checksum file
    # Our releases list "<sha256>  AdGuardHome-linux_arm64", upstream prefixes
    # the name with "./" - both are accepted.
    local expected
    local actual
    expected=$(awk -v name="$2" '{ sub(/^\.\//, "", $2); if ($2 == name) print $1 }' "$3")
    if [ -z "$expected" ]; then
        log "ERROR" "No checksum entry for $2"
        return 1
    fi
    actual=$(sha256sum "$1" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        log "ERROR" "Checksum mismatch for $2"
        log "ERROR" "Expected: $expected"
        log "ERROR" "Got:      $actual"
        return 1
    fi
    log "SUCCESS" "Checksum verified: $2"
    return 0
}

download_and_verify() {
    # $1 = base url, $2 = asset name, $3 = target path
    log "INFO" "Downloading $2 ..."
    # -f matters: without it a 404 page is happily stored as a "binary"
    if ! curl -fL -s --retry 3 --connect-timeout 20 -o "$3" "$1/$2"; then
        log "ERROR" "Download of $2 failed. Please check your internet connection."
        rm -f "$3"
        return 1
    fi
    if [ ! -s "$3" ]; then
        log "ERROR" "The downloaded file is empty: $3"
        rm -f "$3"
        return 1
    fi
    if ! command -v sha256sum >/dev/null; then
        log "WARNING" "sha256sum is not available, skipping the checksum verification."
        return 0
    fi
    if ! curl -fL -s --retry 3 --connect-timeout 20 -o "$TEMP_CHECKSUMS" "$1/checksums.txt"; then
        log "WARNING" "Could not download checksums.txt, skipping the checksum verification."
        rm -f "$TEMP_CHECKSUMS"
        return 0
    fi
    if ! verify_sha256 "$3" "$2" "$TEMP_CHECKSUMS"; then
        rm -f "$3" "$TEMP_CHECKSUMS"
        return 1
    fi
    rm -f "$TEMP_CHECKSUMS"
    return 0
}

# ==============================================================================
# System Checks & Pre-flight
# ==============================================================================

detect_platform() {
    # Sets ARCH, MODEL, AGH_ARCH and FIRMWARE_VERSION. Every other function reads
    # these variables instead of probing the system itself.
    ARCH=$(uname -m)
    MODEL=""
    AGH_ARCH=""
    FIRMWARE_VERSION=0

    if [ -r "$GL_VERSION_FILE" ]; then
        FIRMWARE_VERSION=$(cut -c1 <"$GL_VERSION_FILE")
    fi
    case "$FIRMWARE_VERSION" in
    '' | *[!0-9]*) FIRMWARE_VERSION=0 ;;
    esac

    # The model decides between mips and mipsle on some devices, so it has to be
    # known before the architecture is evaluated.
    if [ -r "$CPUINFO_FILE" ]; then
        MODEL=$(grep 'machine' "$CPUINFO_FILE" | awk -F ': ' '{print $2}')
    fi
    if [ -z "$MODEL" ] && [ -r "$GL_MODEL_FILE" ]; then
        MODEL=$(cat "$GL_MODEL_FILE")
    fi

    case "$ARCH" in
    aarch64)
        AGH_ARCH="AdGuardHome-linux_arm64"
        ;;
    armv7l)
        AGH_ARCH="AdGuardHome-linux_armv7"
        ;;
    mips | mipsel)
        case "$MODEL" in
        "GL.iNet GL-MT1300" | "GL-MT300N-V2" | "GL-SFT1200")
            AGH_ARCH="AdGuardHome-linux_mipsle_softfloat"
            ;;
        *)
            AGH_ARCH="AdGuardHome-linux_mips_softfloat"
            ;;
        esac
        ;;
    esac
}

preflight_check() {
    local available_space
    local preflight=0

    log "INFO" "Checking if prerequisites are met ..."

    if [ "$FIRMWARE_VERSION" -lt 4 ]; then
        log "ERROR" "This script only works on firmware version 4 or higher."
        preflight=1
    else
        log "SUCCESS" "Firmware version: $FIRMWARE_VERSION"
    fi

    if [ -n "$AGH_ARCH" ]; then
        log "SUCCESS" "Architecture: ${AGH_ARCH#AdGuardHome-linux_}"
    else
        log "ERROR" "Unsupported architecture: $ARCH"
        log "ERROR" "This script works on arm64, armv7, mips and mipsle devices."
        preflight=1
    fi

    if [ -x "$AGH_BIN" ]; then
        log "SUCCESS" "AdGuard Home is installed: $(agh_version "$AGH_BIN")"
    else
        log "ERROR" "AdGuard Home is not installed at $AGH_BIN."
        log "ERROR" "Please enable AdGuard Home in the GL.iNet web interface first."
        preflight=1
    fi

    available_space=$(df -P -k / | tail -n 1 | awk '{print $4/1024}')
    available_space=$(printf "%.0f" "$available_space")
    if [ "$available_space" -lt 15 ]; then
        log "ERROR" "Not enough space available. Please free up some space and try again."
        log "ERROR" "The script needs at least 15 MB of free space. Available space: $available_space MB"
        log "ERROR" "If you want to continue, you can use --ignore-free-space to ignore this check."
        if [ "$IGNORE_FREE_SPACE" -eq 1 ]; then
            log "WARNING" "--ignore-free-space flag is used. Continuing without enough space ..."
            log "INFO" "Current available space: $available_space MB"
        else
            preflight=1
        fi
    else
        log "SUCCESS" "Available space: $available_space MB"
    fi

    if command -v curl >/dev/null; then
        log "SUCCESS" "curl is installed."
    else
        log "ERROR" "curl is not installed."
        preflight=1
    fi

    if [ "$preflight" -eq 1 ]; then
        log "ERROR" "Prerequisites are not met. Exiting ..."
        exit 1
    fi
    log "SUCCESS" "Prerequisites are met."
}

# ==============================================================================
# Backup
# ==============================================================================

backup() {
    local timestamp

    BACKUP_PATH=""
    if [ ! -d "$AGH_CONFIG_DIR" ]; then
        log "WARNING" "$AGH_CONFIG_DIR not found. Skipping backup."
        return 0
    fi

    log "INFO" "Creating backup of AdGuard Home config ..."
    timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    if ! mkdir -p "$BACKUP_DIR"; then
        log "ERROR" "Could not create the backup directory: $BACKUP_DIR"
        return 1
    fi
    BACKUP_PATH="$BACKUP_DIR/$timestamp.tar.gz"
    if ! tar czf "$BACKUP_PATH" -C /etc AdGuardHome; then
        log "ERROR" "Could not create the config backup. Aborting the update."
        rm -f "$BACKUP_PATH"
        BACKUP_PATH=""
        return 1
    fi

    log "SUCCESS" "Backup created: $BACKUP_PATH"
    log "INFO" "The binary is not backed up: a normal run always installs the"
    log "INFO" "latest stable version, and --restore brings back the firmware version."
    return 0
}

# ==============================================================================
# Update Logic
# ==============================================================================

get_target_version() {
    log "INFO" "Detecting the available AdGuard Home version ($CHANNEL_NAME) ..."
    AGH_VERSION_NEW=$(curl -fL -s --retry 3 --connect-timeout 20 "$AGH_TINY_URL/version.txt" | tr -d '[:space:]')
    if [ -z "$AGH_VERSION_NEW" ]; then
        log "ERROR" "Could not get the AdGuard Home version of the $CHANNEL_NAME channel."
        log "ERROR" "Please check your internet connection."
        exit 1
    fi
    AGH_VERSION_OLD=$(agh_version "$AGH_BIN")

    log "INFO" "Available version: $AGH_VERSION_NEW"
    log "INFO" "Installed version: ${AGH_VERSION_OLD:-unknown}"

    # Full version strings are compared, so a beta update (v1.0.0-b.1 to
    # v1.0.0-b.2) is not mistaken for "already up to date".
    if [ "$AGH_VERSION_NEW" = "$AGH_VERSION_OLD" ]; then
        if [ "$FORCE_UPGRADE" -eq 0 ]; then
            log "SUCCESS" "You already have this version."
            log "INFO" "You can reinstall it with the --force-upgrade flag."
            exit 0
        fi
        log "WARNING" "--force-upgrade flag is used. Reinstalling $AGH_VERSION_NEW ..."
    fi
}

warn_about_downgrade() {
    # Going from a testing version back to stable, or picking an older release
    if [ "$TESTING" -eq 1 ]; then
        return 0
    fi
    if ! is_testing_version "$AGH_VERSION_OLD"; then
        return 0
    fi
    log "WARNING" "A testing version is currently installed: $AGH_VERSION_OLD"
    log "WARNING" "Installing $AGH_VERSION_NEW is a downgrade."
    log "WARNING" "Downgrading is not officially supported by AdGuard Home."
    log "WARNING" "If AdGuard Home does not start afterwards, remove its config:"
    log "WARNING" "  rm -rf $AGH_CONFIG_DIR && $AGH_INIT_SCRIPT restart"
    log "INFO" "Your current config is backed up to $BACKUP_DIR before anything changes."
    confirm_or_exit "Do you want to continue?"
}

download_agh() {
    rm -f "$TEMP_FILE"
    if ! download_and_verify "$AGH_TINY_URL" "$AGH_ARCH" "$TEMP_FILE"; then
        log "ERROR" "Could not download a verified AdGuard Home binary."
        log "ERROR" "Nothing has been changed on your router."
        log "ERROR" "Please report this issue on the GL.iNet forum."
        exit 1
    fi
    log "SUCCESS" "AdGuard Home $AGH_VERSION_NEW has been downloaded."
}

stop_adguardhome() {
    log "INFO" "Stopping AdGuard Home ..."
    "$AGH_INIT_SCRIPT" stop >/dev/null 2>&1
    sleep 4
    # Stop it by killing the process if it is still running
    if pgrep AdGuardHome >/dev/null; then
        killall AdGuardHome 2>/dev/null
    fi
}

restart_and_verify() {
    # Restarts AdGuard Home and waits for it to come up. A fixed sleep is too
    # short on slow devices, and a process that dies right after starting does
    # not count as a success.
    local waited=0
    log "INFO" "Restarting AdGuard Home ..."
    "$AGH_INIT_SCRIPT" restart >/dev/null 2>&1
    while [ "$waited" -lt "$AGH_RESTART_TIMEOUT" ]; do
        sleep 1
        waited=$((waited + 1))
        if agh_is_running; then
            sleep 2
            if agh_is_running; then
                return 0
            fi
            return 1
        fi
    done
    return 1
}

rollback_binary() {
    # Puts the previous binary back. It is only restarted when AdGuard Home was
    # running before, so a switched off AdGuard Home stays switched off.
    if [ ! -f "$AGH_BIN_OLD" ]; then
        log "ERROR" "There is no previous binary to roll back to."
        return 1
    fi
    log "INFO" "Rolling back to the previous binary ..."
    if ! mv "$AGH_BIN_OLD" "$AGH_BIN"; then
        log "ERROR" "Could not restore the previous binary from $AGH_BIN_OLD."
        return 1
    fi
    chmod +x "$AGH_BIN"
    if [ "$AGH_WAS_RUNNING" -eq 0 ]; then
        log "SUCCESS" "Rolled back to AdGuard Home $(agh_version "$AGH_BIN")"
        return 0
    fi
    if restart_and_verify; then
        log "SUCCESS" "Rolled back to AdGuard Home $(agh_version "$AGH_BIN")"
        return 0
    fi
    log "ERROR" "The rollback did not bring AdGuard Home up either."
    return 1
}

enable_querylog() {
    if [ "$USER_WANTS_QUERYLOG" != "y" ]; then
        log "INFO" "Ok, skipping query log ..."
        return 0
    fi
    if [ ! -f "$AGH_CONFIG_DIR/config.yaml" ]; then
        log "WARNING" "$AGH_CONFIG_DIR/config.yaml not found, skipping query log ..."
        return 0
    fi
    log "INFO" "Enabling query log ..."
    sed -i '/^querylog:/,/^[^ ]/ s/^  file_enabled: .*/  file_enabled: true/' "$AGH_CONFIG_DIR/config.yaml"
    log "SUCCESS" "Query log is now enabled."
}

apply_dns_routing() {
    # NOTE: 'explict_vpn' is the (misspelled) keyword used by the GL.iNet firmware
    case "$DNS_ROUTING_ACTION" in
    to_wan)
        log "INFO" "Switching upstream DNS to WAN only ..."
        sed -i 's/explict_vpn/nonevpn/g' "$AGH_INIT_SCRIPT"
        DNS_WAN_ONLY=1
        log "SUCCESS" "AdGuard Home now sends upstream DNS queries via WAN only."
        ;;
    to_default)
        log "INFO" "Restoring default DNS routing ..."
        cp "/rom$AGH_INIT_SCRIPT" "$AGH_INIT_SCRIPT"
        if [ -f "$AGH_UPDATE_CHECK_SCRIPT" ]; then
            remove_lines "$AGH_UPDATE_CHECK_SCRIPT" "nonevpn"
        fi
        log "SUCCESS" "Default DNS routing restored."
        ;;
    *)
        log "INFO" "Keeping the current DNS routing ..."
        ;;
    esac
}

disable_multipath_tcp() {
    log "INFO" "Disabling multipath TCP ..."
    if grep -q 'procd_set_param env GODEBUG=multipathtcp=0' "$AGH_INIT_SCRIPT"; then
        log "INFO" "Multipath TCP is already disabled in $AGH_INIT_SCRIPT"
        return 0
    fi
    sed -i '/procd_set_param stderr 1/a\    procd_set_param env GODEBUG=multipathtcp=0' "$AGH_INIT_SCRIPT"
    log "SUCCESS" "Multipath TCP is now disabled."
    log "INFO" "This is to prevent issues with AdGuard Home on GL.iNet routers."
    log "INFO" "If you want to re-enable multipath TCP, please remove the line"
    log "INFO" "'procd_set_param env GODEBUG=multipathtcp=0' from $AGH_INIT_SCRIPT"
}

install_agh() {
    local installed_version

    # Whether AdGuard Home runs is a different question from whether its binary
    # can be updated: it can be switched off in the GL.iNet web interface. The
    # state found here decides what counts as a failure further down.
    AGH_WAS_RUNNING=0
    if agh_is_running; then
        AGH_WAS_RUNNING=1
    else
        log "INFO" "AdGuard Home is not running at the moment."
    fi

    stop_adguardhome

    log "INFO" "Installing the new binary in $AGH_BIN ..."
    rm -f "$AGH_BIN_OLD"
    if [ -f "$AGH_BIN" ] && ! mv "$AGH_BIN" "$AGH_BIN_OLD"; then
        log "ERROR" "Could not move the current binary out of the way."
        log "ERROR" "Nothing has been changed on your router."
        exit 1
    fi
    if ! mv "$TEMP_FILE" "$AGH_BIN"; then
        log "ERROR" "Could not install the new binary."
        rollback_binary
        exit 1
    fi
    chmod +x "$AGH_BIN"

    enable_querylog
    # Must run before disable_multipath_tcp, as restoring copies the stock init script
    apply_dns_routing
    disable_multipath_tcp

    # Does the new binary work? That is a question about the binary, so it is
    # answered without the service and holds while AdGuard Home is switched off.
    installed_version=$(agh_version "$AGH_BIN")
    if [ -z "$installed_version" ]; then
        log "ERROR" "The new binary does not work: it does not report a version."
        rollback_binary
        if [ -n "$BACKUP_PATH" ]; then
            log "INFO" "Your config backup is here: $BACKUP_PATH"
        fi
        log "ERROR" "Please report this issue on the GL.iNet forum."
        exit 1
    fi

    if restart_and_verify; then
        rm -f "$AGH_BIN_OLD"
        log "SUCCESS" "AdGuard Home has been updated to version $installed_version"
        return 0
    fi

    if [ "$AGH_WAS_RUNNING" -eq 0 ]; then
        # It was not running before the update either, so there is nothing that
        # a rollback could improve: the binary is updated, which is the job.
        rm -f "$AGH_BIN_OLD"
        log "SUCCESS" "AdGuard Home has been updated to version $installed_version"
        log "INFO" "AdGuard Home is not running, just as before the update."
        log "INFO" "That is expected while it is switched off; enable it in the"
        log "INFO" "GL.iNet web interface whenever you want to use it."
        return 0
    fi

    log "ERROR" "AdGuard Home was running before the update, but does not run now."
    rollback_binary
    if [ -n "$BACKUP_PATH" ]; then
        log "INFO" "Your config backup is here: $BACKUP_PATH"
    fi
    log "ERROR" "Please report this issue on the GL.iNet forum."
    exit 1
}

create_persistance_script() {
    log "INFO" "Creating persistance script in $AGH_UPDATE_CHECK_SCRIPT ..."
    cat <<'EOF' >"$AGH_UPDATE_CHECK_SCRIPT"
#!/bin/sh
# This script enables the update check for AdGuard Home and disables multipath TCP.
# It should be executed after every reboot
# Author: Admon
if [ -f /etc/init.d/adguardhome ]; then
    if ! grep -q 'procd_set_param env GODEBUG=multipathtcp=0' /etc/init.d/adguardhome; then
        sed -i '/procd_set_param stderr 1/a\    procd_set_param env GODEBUG=multipathtcp=0' /etc/init.d/adguardhome
    fi
    sed -i '/procd_set_param command \/usr\/bin\/AdGuardHome/ s/--no-check-update //' "/etc/init.d/adguardhome"
else
    echo "Startup script not found. Exiting ..."
    echo "Please report this issue on the GL.iNET forum."
    exit 1
fi
EOF
    # Keep upstream DNS via WAN only after a firmware upgrade
    if [ "$DNS_WAN_ONLY" -eq 1 ]; then
        echo "sed -i 's/explict_vpn/nonevpn/g' /etc/init.d/adguardhome" >>"$AGH_UPDATE_CHECK_SCRIPT"
    fi
    chmod +x "$AGH_UPDATE_CHECK_SCRIPT"

    log "INFO" "Creating entry in rc.local ..."
    if ! grep -q "$AGH_UPDATE_CHECK_SCRIPT" "$RC_LOCAL"; then
        sed -i "/exit 0/i . $AGH_UPDATE_CHECK_SCRIPT" "$RC_LOCAL"
    fi
}

upgrade_persistance() {
    log "INFO" "Modifying $SYSUPGRADE_CONF ..."
    # Removing the old entry because it is not needed anymore
    remove_lines "$SYSUPGRADE_CONF" "$LEGACY_BACKUP_FILE"
    for entry in "$AGH_CONFIG_DIR" "$AGH_BIN" "$AGH_UPDATE_CHECK_SCRIPT" "$RC_LOCAL"; do
        if ! grep -qxF "$entry" "$SYSUPGRADE_CONF"; then
            echo "$entry" >>"$SYSUPGRADE_CONF"
        fi
    done
}

make_persistent() {
    if [ "$USER_WANTS_PERSISTENCE" != "y" ]; then
        return 0
    fi
    log "INFO" "Making installation permanent ..."
    create_persistance_script
    upgrade_persistance
    "$AGH_UPDATE_CHECK_SCRIPT"
}

show_firmware_upgrade_warning() {
    log "WARNING" "Please keep in mind:"
    log "WARNING" "Upgrading the firmware will downgrade AdGuard Home!"
    log "WARNING" "This will lead to non-working AdGuard Home."
    log "WARNING" "Please disable AdGuard Home before upgrading the firmware."
    log "WARNING" "After the firmware upgrade, you need to update AdGuard Home again."
    log "WARNING" "It won't work otherwise."
}

# ==============================================================================
# Restore
# ==============================================================================

restore() {
    local rom_binary="/rom$AGH_BIN"
    local rom_version

    if [ ! -f "$rom_binary" ]; then
        log "ERROR" "Cannot restore AdGuard Home to the firmware version!"
        log "ERROR" "$rom_binary not found."
        log "ERROR" "This happens if you are not using GL.iNet firmware or if you are"
        log "ERROR" "running this script on a non-GL.iNet device."
        log "INFO" "You can install a specific version with --select-release instead."
        exit 1
    fi

    rom_version=$(agh_version "$rom_binary")
    log "WARNING" "This restores the AdGuard Home version shipped with your firmware."
    log "WARNING" "That is a downgrade: ${AGH_VERSION_OLD:-unknown} -> ${rom_version:-unknown}"
    log "WARNING" "Downgrading is not officially supported by AdGuard Home."
    log "WARNING" "Your configuration in $AGH_CONFIG_DIR is kept, but if AdGuard Home"
    log "WARNING" "does not start afterwards, remove it:"
    log "WARNING" "  rm -rf $AGH_CONFIG_DIR && $AGH_INIT_SCRIPT restart"
    confirm_or_exit "Do you want to continue?"

    backup || exit 1

    AGH_WAS_RUNNING=0
    if agh_is_running; then
        AGH_WAS_RUNNING=1
    else
        log "INFO" "AdGuard Home is not running at the moment."
    fi
    stop_adguardhome

    log "INFO" "Restoring $AGH_BIN from /rom ..."
    rm -f "$AGH_BIN_OLD"
    if [ -f "$AGH_BIN" ] && ! mv "$AGH_BIN" "$AGH_BIN_OLD"; then
        log "ERROR" "Could not move the current binary out of the way."
        log "ERROR" "Nothing has been changed on your router."
        exit 1
    fi
    if ! cp "$rom_binary" "$AGH_BIN"; then
        log "ERROR" "Could not restore the binary from /rom."
        rollback_binary
        exit 1
    fi
    chmod +x "$AGH_BIN"

    # The stock init script carries the firmware defaults for DNS routing and
    # multipath TCP, so the modifications of this script go away with it.
    if [ -f "/rom$AGH_INIT_SCRIPT" ]; then
        log "INFO" "Restoring $AGH_INIT_SCRIPT from /rom ..."
        cp "/rom$AGH_INIT_SCRIPT" "$AGH_INIT_SCRIPT"
    fi

    log "INFO" "Removing the persistance entries of this script ..."
    rm -f "$AGH_UPDATE_CHECK_SCRIPT" "$AGH_BIN_OLD"
    remove_lines "$RC_LOCAL" "$AGH_UPDATE_CHECK_SCRIPT"
    remove_lines "$SYSUPGRADE_CONF" "$AGH_UPDATE_CHECK_SCRIPT"
    remove_lines "$SYSUPGRADE_CONF" "$AGH_BIN"
    remove_lines "$SYSUPGRADE_CONF" "$AGH_CONFIG_DIR"
    remove_lines "$SYSUPGRADE_CONF" "$LEGACY_BACKUP_FILE"

    if [ -z "$(agh_version "$AGH_BIN")" ]; then
        log "ERROR" "The restored binary does not report a version."
        rollback_binary
        log "ERROR" "Your config backup is here: ${BACKUP_PATH:-$BACKUP_DIR}"
        exit 1
    fi

    if ! restart_and_verify && [ "$AGH_WAS_RUNNING" -eq 1 ]; then
        log "ERROR" "AdGuard Home was running before the restore, but does not run now."
        rollback_binary
        log "ERROR" "Your config backup is here: ${BACKUP_PATH:-$BACKUP_DIR}"
        log "ERROR" "Please report this issue on the GL.iNet forum."
        exit 1
    fi

    rm -f "$AGH_BIN_OLD"
    log "SUCCESS" "AdGuard Home has been restored to version $(agh_version "$AGH_BIN")"
    if ! agh_is_running; then
        log "INFO" "AdGuard Home is not running, just as before the restore."
    fi
    log "INFO" "Re-enable AdGuard Home in the GL.iNet web interface if it is switched off."
}

# ==============================================================================
# User Interface
# ==============================================================================

invoke_help() {
    printf '\033[1mUsage:\033[0m \033[92m./%s\033[0m [\033[93mOPTIONS\033[0m]\n' "$SCRIPT_NAME"
    printf '\033[1mOptions:\033[0m\n'
    printf '  \033[93m--ignore-free-space\033[0m  \033[97mIgnore the free space check (no backup is created)\033[0m\n'
    printf '  \033[93m--select-release\033[0m     \033[97mSelect a specific stable release\033[0m\n'
    printf '  \033[93m--testing\033[0m            \033[97mInstall the latest AdGuard Home prerelease (beta)\033[0m\n'
    printf '  \033[93m--restore\033[0m            \033[97mRestore the AdGuard Home version of your firmware\033[0m\n'
    printf '  \033[93m--force\033[0m              \033[97mDo not ask for confirmation\033[0m\n'
    printf '  \033[93m--force-upgrade\033[0m      \033[97mInstall even if this version is already installed\033[0m\n'
    printf '  \033[93m--log\033[0m                \033[97mShow timestamps in log messages\033[0m\n'
    printf '  \033[93m--help\033[0m               \033[97mShow this help\033[0m\n'
}

invoke_intro() {
    echo "============================================================"
    echo ""
    echo "  GL.iNet AdGuard Home Updater by Admon"
    echo "  Version: $SCRIPT_VERSION"
    echo ""
    echo "============================================================"
    echo ""
    printf ' \033[33mTHIS SCRIPT MIGHT POTENTIALLY HARM YOUR ROUTER!\033[0m\n'
    printf ' \033[33mIt is only recommended to use it if you know what you are doing.\033[0m\n'
    echo ""
    echo "  Support this project:"
    echo "    - GitHub: github.com/sponsors/admonstrator"
    echo "    - Ko-fi: ko-fi.com/admon"
    echo "    - Buy Me a Coffee: buymeacoffee.com/admon"
    echo ""
    echo "============================================================"
    echo ""
}

invoke_outro() {
    # After a restore the firmware version is installed, so a firmware upgrade
    # is not going to downgrade anything.
    if [ "$RESTORE" -eq 0 ] && [ "$USER_WANTS_PERSISTENCE" != "y" ]; then
        show_firmware_upgrade_warning
    fi
    if is_testing_version "$(agh_version "$AGH_BIN")"; then
        log "INFO" "A testing version is installed. To go back, run this script"
        log "INFO" "without any flag (latest stable) or with --restore."
    fi
    echo ""
    echo "If you like this script, please consider supporting the project:"
    echo "  - GitHub: github.com/sponsors/admonstrator"
    echo "  - Ko-fi: ko-fi.com/admon"
    echo "  - Buy Me a Coffee: buymeacoffee.com/admon"
    echo ""
    log "SUCCESS" "Script finished!"
}

collect_user_preferences() {
    local answer
    log "INFO" "Collecting your preferences before anything is changed ..."
    echo ""

    # Query log on flash
    if [ -f "$AGH_CONFIG_DIR/config.yaml" ]; then
        log "INFO" "Due to the GL firmware, the query log is in RAM only."
        log "INFO" "It will be lost after a reboot or restart of AdGuard Home."
        log "INFO" "This is to prevent the router from running out of memory"
        log "INFO" "and wearing out the flash memory too quickly."
        log "INFO" "We can enable storing the query log on flash for you."
        log "WARNING" "Please keep in mind that this will wear out the flash memory faster."
        if [ "$FORCE" -eq 1 ]; then
            USER_WANTS_QUERYLOG="n"
            log "INFO" "--force flag is used. The query log stays in RAM."
        else
            log "WARNING" "Do you want to enable the query log on flash? (y/N)"
            read -r answer
            if [ "$answer" != "${answer#[Yy]}" ]; then
                USER_WANTS_QUERYLOG="y"
            fi
        fi
        echo ""
    fi

    collect_dns_routing_preference

    # Persistence over firmware upgrades
    log "INFO" "The installation can be made permanent."
    log "INFO" "This keeps your AdGuard Home config and binary over a firmware"
    log "INFO" "up- or downgrade. It could lead to issues, even if not likely."
    log "INFO" "In the worst case, you might need to remove the entries from"
    log "INFO" "$SYSUPGRADE_CONF and $RC_LOCAL."
    if [ "$TESTING" -eq 1 ]; then
        log "WARNING" "You are installing a TESTING version. Making it permanent means"
        log "WARNING" "a firmware upgrade will keep the beta instead of the firmware version."
    fi
    if [ "$FORCE" -eq 1 ]; then
        USER_WANTS_PERSISTENCE="y"
        log "INFO" "--force flag is used. The installation will be made permanent."
    else
        log "WARNING" "Do you want to make the installation permanent? (y/N)"
        read -r answer
        if [ "$answer" != "${answer#[Yy]}" ]; then
            USER_WANTS_PERSISTENCE="y"
        fi
    fi
    echo ""
}

collect_dns_routing_preference() {
    local answer
    DNS_ROUTING_ACTION="none"

    # NOTE: 'explict_vpn' is the (misspelled) keyword used by the GL.iNet firmware
    if grep -q 'explict_vpn' "$AGH_INIT_SCRIPT" 2>/dev/null; then
        log "INFO" "By default, AdGuard Home sends its upstream DNS queries through the VPN"
        log "INFO" "when a VPN tunnel is active. If the VPN tunnel cannot reach the upstream"
        log "INFO" "DNS servers configured in AdGuard Home, DNS resolution will fail."
        log "INFO" "We can force AdGuard Home to send its upstream DNS queries via WAN only."
        log "WARNING" "Upstream DNS queries will then bypass the VPN tunnel!"
        if [ "$FORCE" -eq 1 ]; then
            log "INFO" "--force flag is used. The DNS routing is left as it is."
        else
            log "WARNING" "Do you want AdGuard Home to use WAN only for upstream DNS? (y/N)"
            read -r answer
            if [ "$answer" != "${answer#[Yy]}" ]; then
                DNS_ROUTING_ACTION="to_wan"
            fi
        fi
        echo ""
    elif [ -f "/rom$AGH_INIT_SCRIPT" ] && grep -q 'explict_vpn' "/rom$AGH_INIT_SCRIPT"; then
        # The keyword is gone from the active init script, so WAN only is in effect
        DNS_WAN_ONLY=1
        log "INFO" "AdGuard Home currently sends upstream DNS queries via WAN only."
        if [ "$FORCE" -eq 1 ]; then
            log "INFO" "--force flag is used. Upstream DNS keeps using WAN only."
        else
            log "WARNING" "Do you want to restore the default (upstream DNS through VPN)? (y/N)"
            read -r answer
            if [ "$answer" != "${answer#[Yy]}" ]; then
                DNS_ROUTING_ACTION="to_default"
                DNS_WAN_ONLY=0
            fi
        fi
        echo ""
    else
        log "INFO" "DNS routing option not found in $AGH_INIT_SCRIPT, skipping ..."
    fi
}

choose_release_label() {
    local available_labels
    local label_choice
    local selected_label
    local label
    local i=1

    log "INFO" "Fetching available release labels ..."
    # Only plain vX.Y.Z tags: this filters out the rolling "prerelease" tag and
    # every beta tag (vX.Y.Z-b.N), so a testing build can never be installed by
    # accident through this menu.
    available_labels=$(
        curl -fL -s --retry 3 --connect-timeout 20 "https://api.github.com/repos/$AGH_REPO/releases?per_page=30" \
        | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4 \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$'
    )
    if [ -z "$available_labels" ]; then
        log "ERROR" "Could not retrieve release labels. Please check your internet connection."
        exit 1
    fi

    log "INFO" "Available release labels:"
    for label in $available_labels; do
        printf '\033[93m %d) %s\033[0m\n' "$i" "$label"
        i=$((i + 1))
    done

    printf '\033[93m Select a release by entering the corresponding number: \033[0m'
    read -r label_choice
    case "$label_choice" in
    '' | *[!0-9]*)
        log "ERROR" "Invalid choice. Exiting ..."
        exit 1
        ;;
    esac
    selected_label=$(printf '%s\n' "$available_labels" | sed -n "${label_choice}p")
    if [ -z "$selected_label" ]; then
        log "ERROR" "Invalid choice. Exiting ..."
        exit 1
    fi

    log "INFO" "You selected release label: $selected_label"
    AGH_TINY_URL="https://github.com/$AGH_REPO/releases/download/$selected_label"
    CHANNEL_NAME="$selected_label"
    log "WARNING" "Downgrading is not officially supported by AdGuard Home!"
    log "WARNING" "You might need to delete the config folder after downgrading!"
    log "WARNING" "All AdGuard Home settings will be lost in that case:"
    log "WARNING" "  rm -rf $AGH_CONFIG_DIR && $AGH_INIT_SCRIPT restart"
    log "WARNING" "This script will NOT run the above commands for you!"
    confirm_or_exit "Do you want to continue?"
}

enable_testing_channel() {
    AGH_TINY_URL="$AGH_TESTING_URL"
    CHANNEL_NAME="testing"
    log "WARNING" "TESTING CHANNEL: this installs an AdGuard Home prerelease."
    log "WARNING" "Beta software can take DNS down for your whole network."
    log "WARNING" "So far it has only been tested on the GL.iNet Flint 4 (GL-BE14000),"
    log "WARNING" "but a build is provided for every supported architecture."
    log "INFO" "Your config is backed up to $BACKUP_DIR before anything is changed."
    log "INFO" "To go back, run this script without any flag (latest stable version)"
    log "INFO" "or use --restore for the version shipped with your firmware."
    confirm_or_exit "Do you want to continue?"
}

# ==============================================================================
# Main Execution Flow
# ==============================================================================

invoke_update() {
    local script_version_new
    local script_path

    log "INFO" "Checking for script updates"
    script_version_new=$(
        curl -fL -s --retry 3 --connect-timeout 20 "$UPDATE_URL" \
        | grep -o 'SCRIPT_VERSION="[0-9]\{4\}\.[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}"' \
        | cut -d '"' -f 2
    )
    if [ -z "$script_version_new" ]; then
        log "WARNING" "Could not retrieve the script version, skipping the update check."
        return 0
    fi
    if [ "$script_version_new" = "$SCRIPT_VERSION" ]; then
        log "SUCCESS" "The script is up to date"
        return 0
    fi

    log "WARNING" "A new version of the script is available: $script_version_new"
    log "INFO" "Updating the script ..."
    if ! curl -fL -s --retry 3 --connect-timeout 20 -o "/tmp/$SCRIPT_NAME" "$UPDATE_URL"; then
        log "WARNING" "Could not download the new version, continuing with $SCRIPT_VERSION."
        rm -f "/tmp/$SCRIPT_NAME"
        return 0
    fi
    script_path=$(readlink -f "$0")
    rm -f "$script_path"
    mv "/tmp/$SCRIPT_NAME" "$script_path"
    chmod +x "$script_path"
    log "INFO" "The script has been updated. It will now restart ..."
    sleep 3
    # "$@" still holds every flag: parse_arguments does not consume them
    exec "$script_path" "$@"
}

parse_arguments() {
    for arg in "$@"; do
        case $arg in
        --help)
            invoke_help
            exit 0
            ;;
        --ignore-free-space)
            IGNORE_FREE_SPACE=1
            ;;
        --select-release)
            SELECT_RELEASE=1
            ;;
        --testing)
            TESTING=1
            ;;
        --restore)
            RESTORE=1
            ;;
        --force)
            FORCE=1
            ;;
        --force-upgrade)
            FORCE_UPGRADE=1
            ;;
        --log)
            SHOW_LOG=1
            ;;
        *)
            echo "Unknown argument: $arg"
            invoke_help
            exit 1
            ;;
        esac
    done

    if [ "$RESTORE" -eq 1 ] && [ $((TESTING + SELECT_RELEASE + IGNORE_FREE_SPACE + FORCE_UPGRADE)) -gt 0 ]; then
        log "ERROR" "--restore cannot be combined with --testing, --select-release,"
        log "ERROR" "--ignore-free-space or --force-upgrade."
        exit 1
    fi
    if [ "$TESTING" -eq 1 ] && [ "$SELECT_RELEASE" -eq 1 ]; then
        log "ERROR" "--testing and --select-release cannot be combined."
        exit 1
    fi
}

main() {
    parse_arguments "$@"
    invoke_intro
    invoke_update "$@"
    detect_platform

    if [ "$RESTORE" -eq 1 ]; then
        AGH_VERSION_OLD=$(agh_version "$AGH_BIN")
        restore
        invoke_outro
        exit 0
    fi

    preflight_check

    if [ "$TESTING" -eq 1 ]; then
        enable_testing_channel
    fi
    if [ "$SELECT_RELEASE" -eq 1 ]; then
        choose_release_label
    fi
    if [ "$IGNORE_FREE_SPACE" -eq 1 ]; then
        log "WARNING" "--ignore-free-space is used."
        log "WARNING" "There will be no backup of your current config of AdGuard Home!"
        log "WARNING" "You might need to reset your router to factory settings if something goes wrong."
        confirm_or_exit "Do you want to continue?"
    fi

    get_target_version
    log "WARNING" "Updating from version ${AGH_VERSION_OLD:-unknown} to $AGH_VERSION_NEW"
    warn_about_downgrade
    collect_user_preferences
    confirm_or_exit "We are going to update AdGuard Home now. Do you want to continue?"

    # Download first: nothing on the router is touched until the binary is here
    # and its checksum matches.
    download_agh
    if [ "$IGNORE_FREE_SPACE" -eq 1 ]; then
        log "WARNING" "Skipping backup, because --ignore-free-space is used"
    else
        backup || exit 1
    fi
    install_agh
    make_persistent
    invoke_outro
    exit 0
}

# Execute Main
main "$@"
