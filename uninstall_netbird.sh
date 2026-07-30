#!/bin/bash

set -uo pipefail
IFS=$'\n\t'

# Complete system-wide NetBird removal for macOS.
#
# Intended execution:
#   - Run as root (for example, a JumpCloud macOS command)
#   - Removes the daemon, UI, CLI, package receipt, profiles, enrollment,
#     managed preference, logs, and every local user's NetBird UI state
#   - Safe to run repeatedly when NetBird is already absent
#
# WARNING:
#   This permanently deletes every NetBird profile and device identity stored
#   on this Mac. Reinstalling NetBird will require a new SSO login or setup key.

readonly APP_PATH="/Applications/NetBird.app"
readonly LEGACY_APP_PATH="/Applications/NetBird UI.app"
readonly CLI_PATH="/usr/local/bin/netbird"
readonly PACKAGE_ID="io.netbird.client"

readonly SERVICE_LABEL="netbird"
readonly LEGACY_SERVICE_LABEL="io.netbird.client"
readonly SERVICE_PLIST="/Library/LaunchDaemons/netbird.plist"
readonly LEGACY_SERVICE_PLIST="/Library/LaunchDaemons/io.netbird.client.plist"

readonly STATE_DIR="/var/lib/netbird"
readonly LEGACY_CONFIG_DIR="/etc/netbird"
readonly LOG_DIR="/var/log/netbird"
readonly RUNTIME_DIR="/var/run/netbird"
readonly RUNTIME_SOCKET="/var/run/netbird.sock"

readonly MANAGED_PREFS="/Library/Managed Preferences/io.netbird.client.plist"
readonly SYSTEM_PREFS="/Library/Preferences/io.netbird.client.plist"

readonly INSTALL_LOG="/var/log/netbird-jumpcloud-install.log"
readonly UNINSTALL_LOG="/var/log/netbird-jumpcloud-uninstall.log"

LOG_READY=0
FAILURE_COUNT=0

timestamp() {
    /bin/date '+%Y-%m-%d %H:%M:%S'
}

emit() {
    local level="$1"
    shift

    local line
    line="[$(timestamp)] $level: $*"

    if [[ "$LOG_READY" -eq 1 ]]; then
        if [[ "$level" == "ERROR" ]]; then
            printf '%s\n' "$line" |
                /usr/bin/tee -a "$UNINSTALL_LOG" >&2
        else
            printf '%s\n' "$line" |
                /usr/bin/tee -a "$UNINSTALL_LOG"
        fi
    else
        printf '%s\n' "$line" >&2
    fi
}

log() {
    emit "INFO" "$@"
}

warn() {
    emit "WARN" "$@"
}

error() {
    emit "ERROR" "$@"
}

die() {
    error "$1"
    exit "${2:-1}"
}

mark_failure() {
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
    error "$1"
}

preflight() {
    if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
        die "This uninstaller supports macOS only."
    fi

    if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
        die "Run this uninstaller as root. In JumpCloud, set Run As to root."
    fi

    local command_path
    for command_path in \
        /bin/chmod \
        /bin/date \
        /bin/launchctl \
        /bin/rm \
        /usr/bin/awk \
        /usr/bin/dscl \
        /usr/bin/id \
        /usr/bin/pgrep \
        /usr/bin/pkill \
        /usr/bin/tee \
        /usr/bin/touch \
        /usr/bin/uname \
        /usr/sbin/pkgutil; do

        [[ -x "$command_path" ]] ||
            die "Required macOS command is unavailable: $command_path"
    done
}

initialize_log() {
    /usr/bin/touch "$UNINSTALL_LOG"
    /bin/chmod 600 "$UNINSTALL_LOG"
    LOG_READY=1
}

try_command() {
    local description="$1"
    shift

    local command_status

    log "$description"
    "$@" 2>&1 | /usr/bin/tee -a "$UNINSTALL_LOG"
    command_status=${PIPESTATUS[0]}

    if [[ "$command_status" -ne 0 ]]; then
        warn "$description returned exit code $command_status; continuing with fallback cleanup."
    fi

    return "$command_status"
}

remove_path() {
    local path="$1"
    local description="$2"

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        log "$description is already absent: $path"
        return 0
    fi

    if /bin/rm -rf "$path"; then
        log "Removed $description: $path"
        return 0
    fi

    mark_failure "Failed to remove $description: $path"
    return 1
}

stop_netbird() {
    local netbird_cli=""

    if /usr/bin/pgrep -x netbird-ui >/dev/null 2>&1; then
        if /usr/bin/pkill -x netbird-ui >/dev/null 2>&1; then
            log "Stopped the NetBird desktop UI."
        else
            warn "Could not stop every NetBird desktop UI process."
        fi
    else
        log "The NetBird desktop UI is not running."
    fi

    if [[ -x "$CLI_PATH" ]]; then
        netbird_cli="$CLI_PATH"
    elif [[ -x "$APP_PATH/Contents/MacOS/netbird" ]]; then
        netbird_cli="$APP_PATH/Contents/MacOS/netbird"
    fi

    if [[ -n "$netbird_cli" ]]; then
        try_command "Disconnecting NetBird" \
            "$netbird_cli" down || true
        try_command "Stopping the NetBird system service" \
            "$netbird_cli" service stop || true
        try_command "Uninstalling the NetBird system service" \
            "$netbird_cli" service uninstall || true
    else
        log "The NetBird CLI is absent; using launchctl fallback cleanup."
    fi

    /bin/launchctl bootout "system/$SERVICE_LABEL" >/dev/null 2>&1 || true
    /bin/launchctl bootout "system/$LEGACY_SERVICE_LABEL" >/dev/null 2>&1 || true

    if /usr/bin/pgrep -x netbird >/dev/null 2>&1; then
        if /usr/bin/pkill -x netbird >/dev/null 2>&1; then
            log "Stopped remaining NetBird daemon processes."
        else
            warn "Could not stop every remaining NetBird daemon process."
        fi
    fi
}

local_human_users() {
    /usr/bin/dscl . -list /Users UniqueID |
        /usr/bin/awk '
            $2 ~ /^[0-9]+$/ &&
            $2 >= 501 &&
            $2 < 60000 &&
            $1 !~ /^_/ &&
            $1 != "Guest" &&
            $1 != "nobody" {
                print $1
            }
        '
}

home_directory_for_user() {
    local username="$1"

    /usr/bin/dscl . -read "/Users/$username" NFSHomeDirectory 2>/dev/null |
        /usr/bin/awk '
            /^NFSHomeDirectory: / {
                sub(/^NFSHomeDirectory: /, "")
                print
                exit
            }
        '
}

remove_user_home_data() {
    local username="$1"
    local user_home="$2"

    case "$user_home" in
        ""|"/")
            warn "No safe home directory was found for user $username; no user UI path was removed."
            return 0
            ;;
    esac

    remove_path \
        "$user_home/Library/Application Support/netbird" \
        "NetBird Application Support for user $username" || true
    remove_path \
        "$user_home/Library/Preferences/io.netbird.client.plist" \
        "NetBird preferences for user $username" || true
    remove_path \
        "$user_home/Library/Caches/io.netbird.client" \
        "NetBird cache for user $username" || true
    remove_path \
        "$user_home/Library/Saved Application State/io.netbird.client.savedState" \
        "NetBird saved application state for user $username" || true
    remove_path \
        "$user_home/Library/Containers/io.netbird.client" \
        "NetBird app container for user $username" || true
}

remove_all_user_data() {
    local user_home
    local user_list
    local username

    if ! user_list="$(local_human_users)"; then
        mark_failure "Could not enumerate local macOS user accounts."
        user_list=""
    fi

    while IFS= read -r username; do
        [[ -n "$username" ]] || continue

        if ! user_home="$(home_directory_for_user "$username")"; then
            warn "Could not resolve the home directory for user $username."
            user_home=""
        fi
        remove_user_home_data "$username" "$user_home"
    done <<<"$user_list"

    remove_user_home_data "root" "/var/root"
}

forget_package_receipt() {
    if ! /usr/sbin/pkgutil --pkg-info "$PACKAGE_ID" >/dev/null 2>&1; then
        log "The NetBird package receipt is already absent: $PACKAGE_ID"
        return 0
    fi

    if /usr/sbin/pkgutil --forget "$PACKAGE_ID" \
        >>"$UNINSTALL_LOG" 2>&1; then

        log "Forgot the NetBird package receipt: $PACKAGE_ID"
        return 0
    fi

    mark_failure "Failed to forget the NetBird package receipt: $PACKAGE_ID"
    return 1
}

remove_netbird_artifacts() {
    remove_path "$SERVICE_PLIST" "NetBird LaunchDaemon plist" || true
    remove_path "$LEGACY_SERVICE_PLIST" "legacy NetBird LaunchDaemon plist" || true

    remove_path "$CLI_PATH" "NetBird CLI" || true
    remove_path "$APP_PATH" "NetBird desktop application" || true
    remove_path "$LEGACY_APP_PATH" "legacy NetBird UI application" || true

    remove_path "$STATE_DIR" "NetBird profiles and device state" || true
    remove_path "$LEGACY_CONFIG_DIR" "legacy NetBird configuration" || true
    remove_all_user_data

    remove_path "$MANAGED_PREFS" "NetBird managed preference" || true
    remove_path "$SYSTEM_PREFS" "NetBird system preference" || true

    remove_path "$RUNTIME_SOCKET" "NetBird runtime socket" || true
    remove_path "$RUNTIME_DIR" "NetBird runtime directory" || true

    remove_path "$LOG_DIR" "NetBird log directory" || true
    remove_path "/var/log/netbird.err.log" "NetBird daemon error log" || true
    remove_path "/var/log/netbird.out.log" "NetBird daemon output log" || true
    remove_path "$INSTALL_LOG" "NetBird installation log" || true

    forget_package_receipt || true
}

verify_removed_path() {
    local path="$1"
    local description="$2"

    if [[ -e "$path" || -L "$path" ]]; then
        mark_failure "$description remains after cleanup: $path"
    fi
}

verify_uninstallation() {
    verify_removed_path "$SERVICE_PLIST" "NetBird LaunchDaemon plist"
    verify_removed_path "$LEGACY_SERVICE_PLIST" "legacy NetBird LaunchDaemon plist"
    verify_removed_path "$CLI_PATH" "NetBird CLI"
    verify_removed_path "$APP_PATH" "NetBird desktop application"
    verify_removed_path "$LEGACY_APP_PATH" "legacy NetBird UI application"
    verify_removed_path "$STATE_DIR" "NetBird profiles and device state"
    verify_removed_path "$LEGACY_CONFIG_DIR" "legacy NetBird configuration"
    verify_removed_path "$MANAGED_PREFS" "NetBird managed preference"
    verify_removed_path "$SYSTEM_PREFS" "NetBird system preference"
    verify_removed_path "$RUNTIME_SOCKET" "NetBird runtime socket"
    verify_removed_path "$RUNTIME_DIR" "NetBird runtime directory"
    verify_removed_path "$LOG_DIR" "NetBird log directory"

    if /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1; then
        mark_failure "The NetBird LaunchDaemon is still loaded."
    fi

    if /bin/launchctl print "system/$LEGACY_SERVICE_LABEL" >/dev/null 2>&1; then
        mark_failure "The legacy NetBird LaunchDaemon is still loaded."
    fi

    if /usr/bin/pgrep -x netbird >/dev/null 2>&1; then
        mark_failure "A NetBird daemon process is still running."
    fi

    if /usr/bin/pgrep -x netbird-ui >/dev/null 2>&1; then
        mark_failure "A NetBird desktop UI process is still running."
    fi

    if /usr/sbin/pkgutil --pkg-info "$PACKAGE_ID" >/dev/null 2>&1; then
        mark_failure "The NetBird package receipt still exists."
    fi
}

main() {
    preflight
    initialize_log

    log "Starting complete NetBird uninstallation for macOS."
    warn "All NetBird profiles, enrollment state, and user UI data will be deleted."

    stop_netbird
    remove_netbird_artifacts
    verify_uninstallation

    if [[ "$FAILURE_COUNT" -ne 0 ]]; then
        error "NetBird uninstallation completed with $FAILURE_COUNT unresolved issue(s)."
        error "Review the log: $UNINSTALL_LOG"
        exit 1
    fi

    log "NetBird was completely removed from this Mac."
    log "Uninstallation log: $UNINSTALL_LOG"
    log "If JumpCloud still assigns the io.netbird.client policy, unbind it to prevent the managed preference from returning."
}

main "$@"
