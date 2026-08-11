#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

# NetBird system-wide installation for macOS.
#
# Intended execution:
#   - Run as root (for example, a JumpCloud macOS command)
#   - No setup key is used
#   - Creates a SleekVPNTest profile for each existing human macOS account
#   - Selects SleekVPNTest for the currently logged-in console user
#   - Users complete SSO by opening /Applications/NetBird.app
#
# The management URL is configured in two system-wide locations:
#   1. The NetBird LaunchDaemon arguments, for persistence on every Mac.
#   2. macOS managed preferences, so the value is authoritative for the UI
#      and daemon when the Mac is MDM-enrolled.

readonly MANAGEMENT_URL="https://nbvpn.sleek.com"
readonly PROFILE_NAME="SleekVPN"
readonly PACKAGE_BASE_URL="https://pkgs.netbird.io/macos"
readonly EXPECTED_TEAM_ID="TA739QLA7A"

readonly APP_PATH="/Applications/NetBird.app"
readonly APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"
readonly CLI_PATH="/usr/local/bin/netbird"
readonly PACKAGE_ID="io.netbird.client"
readonly SERVICE_LABEL="netbird"
readonly SERVICE_PLIST="/Library/LaunchDaemons/netbird.plist"
readonly MANAGED_PREFS_DIR="/Library/Managed Preferences"
readonly MANAGED_PREFS_PATH="$MANAGED_PREFS_DIR/io.netbird.client.plist"
readonly INSTALL_LOG="/var/log/netbird-jumpcloud-install.log"

TEMP_DIR=""
POLICY_TEMP=""
LOG_READY=0
COMMAND_STATUS=0
ENSURED_PROFILE_ID=""

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
            printf '%s\n' "$line" | /usr/bin/tee -a "$INSTALL_LOG" >&2
        else
            printf '%s\n' "$line" | /usr/bin/tee -a "$INSTALL_LOG"
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

die() {
    local message="$1"
    local status="${2:-1}"

    emit "ERROR" "$message"
    exit "$status"
}

cleanup() {
    if [[ -n "$POLICY_TEMP" && -e "$POLICY_TEMP" ]]; then
        /bin/rm -f "$POLICY_TEMP"
    fi

    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        /bin/rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

preflight() {
    if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
        die "This installer supports macOS only."
    fi

    if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
        die "Run this installer as root. In JumpCloud, set Run As to root."
    fi

    local command_path
    for command_path in \
        /bin/cat \
        /bin/chmod \
        /bin/cp \
        /bin/launchctl \
        /bin/mkdir \
        /bin/mv \
        /bin/rm \
        /bin/sleep \
        /usr/bin/awk \
        /usr/bin/codesign \
        /usr/bin/curl \
        /usr/bin/dscl \
        /usr/bin/grep \
        /usr/bin/mktemp \
        /usr/bin/plutil \
        /usr/bin/stat \
        /usr/bin/sudo \
        /usr/bin/tee \
        /usr/bin/touch \
        /usr/libexec/PlistBuddy \
        /usr/sbin/chown \
        /usr/sbin/installer \
        /usr/sbin/pkgutil; do

        [[ -x "$command_path" ]] ||
            die "Required macOS command is unavailable: $command_path"
    done
}

initialize_log() {
    /usr/bin/touch "$INSTALL_LOG"
    /bin/chmod 600 "$INSTALL_LOG"
    LOG_READY=1
}

run_logged() {
    local description="$1"
    shift

    log "$description"

    set +e
    "$@" 2>&1 | /usr/bin/tee -a "$INSTALL_LOG"
    COMMAND_STATUS=${PIPESTATUS[0]}
    set -e

    return "$COMMAND_STATUS"
}

must_run() {
    local description="$1"
    shift

    if ! run_logged "$description" "$@"; then
        local status="$COMMAND_STATUS"
        die "$description failed with exit code $status." "$status"
    fi
}

installed_package_is_healthy() {
    local signing_info

    [[ -d "$APP_PATH" ]] || return 1
    [[ -f "$APP_INFO_PLIST" ]] || return 1
    [[ -x "$CLI_PATH" ]] || return 1
    /usr/sbin/pkgutil --pkg-info "$PACKAGE_ID" >/dev/null 2>&1 || return 1
    /usr/bin/codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1 ||
        return 1

    signing_info="$(
        /usr/bin/codesign --display --verbose=4 "$APP_PATH" 2>&1
    )"
    printf '%s\n' "$signing_info" |
        /usr/bin/grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" ||
        return 1

    "$CLI_PATH" debug config --help >/dev/null 2>&1 || return 1
    "$CLI_PATH" service reconfigure --help >/dev/null 2>&1 || return 1

    return 0
}

package_architecture() {
    case "$(/usr/bin/uname -m)" in
        arm64)
            printf '%s\n' "arm64"
            ;;
        x86_64)
            printf '%s\n' "amd64"
            ;;
        *)
            return 1
            ;;
    esac
}

download_and_install_package() {
    local package_arch
    local package_url
    local package_path
    local signature_output
    local signature_status

    package_arch="$(package_architecture)" ||
        die "Unsupported Mac architecture: $(/usr/bin/uname -m)"
    package_url="$PACKAGE_BASE_URL/$package_arch"

    TEMP_DIR="$(/usr/bin/mktemp -d /private/tmp/netbird-install.XXXXXX)"
    package_path="$TEMP_DIR/netbird.pkg"

    must_run \
        "Downloading the official NetBird package for $package_arch" \
        /usr/bin/curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --proto '=https' \
        --connect-timeout 30 \
        --max-time 900 \
        --retry 3 \
        --retry-delay 3 \
        --output "$package_path" \
        "$package_url"

    [[ -s "$package_path" ]] ||
        die "The downloaded NetBird package is empty."

    set +e
    signature_output="$(
        /usr/sbin/pkgutil --check-signature "$package_path" 2>&1
    )"
    signature_status=$?
    set -e

    printf '%s\n' "$signature_output" >>"$INSTALL_LOG"

    if [[ "$signature_status" -ne 0 ]]; then
        die "The downloaded NetBird package has an invalid signature."
    fi

    printf '%s\n' "$signature_output" |
        /usr/bin/grep -Fq "($EXPECTED_TEAM_ID)" ||
        die "The NetBird package is not signed by the expected NetBird team."

    must_run \
        "Installing the signed NetBird package" \
        /usr/sbin/installer -pkg "$package_path" -target /
}

verify_installation() {
    local app_signing_info
    local package_version
    local netbird_version

    [[ -d "$APP_PATH" ]] ||
        die "NetBird.app was not installed at $APP_PATH."
    [[ -f "$APP_INFO_PLIST" ]] ||
        die "NetBird.app is missing its Info.plist."
    [[ -x "$CLI_PATH" ]] ||
        die "The NetBird CLI was not installed at $CLI_PATH."

    /usr/sbin/pkgutil --pkg-info "$PACKAGE_ID" >/dev/null 2>&1 ||
        die "The NetBird package receipt '$PACKAGE_ID' is missing."

    if ! /usr/bin/codesign --verify --deep --strict \
        "$APP_PATH" >>"$INSTALL_LOG" 2>&1; then
        die "NetBird.app failed code-signature verification."
    fi

    app_signing_info="$(
        /usr/bin/codesign --display --verbose=4 "$APP_PATH" 2>&1
    )"
    printf '%s\n' "$app_signing_info" >>"$INSTALL_LOG"
    printf '%s\n' "$app_signing_info" |
        /usr/bin/grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" ||
        die "NetBird.app is not signed by the expected NetBird team."

    package_version="$(
        /usr/sbin/pkgutil --pkg-info "$PACKAGE_ID" |
            /usr/bin/awk -F': ' '/^version:/ { print $2 }'
    )"
    netbird_version="$("$CLI_PATH" version 2>&1)" ||
        die "The NetBird CLI could not report its version."

    log "Verified NetBird.app, CLI, package receipt, and code signature."
    log "Installed package version: ${package_version:-unknown}"
    log "NetBird CLI version: $(printf '%s\n' "$netbird_version" | /usr/bin/awk 'NR == 1')"
}

apply_managed_policy() {
    local configured_url
    local existing_url

    /bin/mkdir -p "$MANAGED_PREFS_DIR"

    if [[ -f "$MANAGED_PREFS_PATH" ]]; then
        /usr/bin/plutil -lint "$MANAGED_PREFS_PATH" >/dev/null 2>&1 ||
            die "Existing NetBird managed preferences are invalid; refusing to overwrite them."

        existing_url="$(
            /usr/libexec/PlistBuddy \
                -c 'Print :managementURL' \
                "$MANAGED_PREFS_PATH" 2>/dev/null || true
        )"
        if [[ "$existing_url" == "$MANAGEMENT_URL" ]]; then
            log "The macOS managed preference already has the required management URL."
            return 0
        fi
    fi

    POLICY_TEMP="$(
        /usr/bin/mktemp "$MANAGED_PREFS_DIR/.io.netbird.client.XXXXXX"
    )"

    if [[ -f "$MANAGED_PREFS_PATH" ]]; then
        /bin/cp -p "$MANAGED_PREFS_PATH" "$POLICY_TEMP"
    else
        /bin/cat >"$POLICY_TEMP" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
PLIST
    fi

    if ! /usr/libexec/PlistBuddy \
        -c "Set :managementURL $MANAGEMENT_URL" \
        "$POLICY_TEMP" >/dev/null 2>&1; then

        /usr/libexec/PlistBuddy \
            -c "Add :managementURL string $MANAGEMENT_URL" \
            "$POLICY_TEMP" >/dev/null
    fi

    /usr/bin/plutil -convert xml1 "$POLICY_TEMP"
    /usr/bin/plutil -lint "$POLICY_TEMP" >/dev/null

    configured_url="$(
        /usr/libexec/PlistBuddy \
            -c 'Print :managementURL' \
            "$POLICY_TEMP" 2>/dev/null || true
    )"
    [[ "$configured_url" == "$MANAGEMENT_URL" ]] ||
        die "Generated NetBird policy contains the wrong management URL."

    /usr/sbin/chown root:wheel "$POLICY_TEMP"
    /bin/chmod 644 "$POLICY_TEMP"
    /bin/mv -f "$POLICY_TEMP" "$MANAGED_PREFS_PATH"
    POLICY_TEMP=""

    log "Configured macOS managed preference managementURL=$MANAGEMENT_URL."
}

repair_service_configuration() {
    warn "NetBird service reconfiguration failed; rebuilding the service definition."
    run_logged "Stopping the existing NetBird service" \
        "$CLI_PATH" service stop || true
    run_logged "Removing the existing NetBird service definition" \
        "$CLI_PATH" service uninstall || true
    must_run \
        "Installing the NetBird system service with the Sleek management URL" \
        "$CLI_PATH" service install --management-url "$MANAGEMENT_URL"
    must_run \
        "Starting the NetBird system service" \
        "$CLI_PATH" service start
}

configure_system_service() {
    local service_arguments

    if [[ -f "$SERVICE_PLIST" ]]; then
        service_arguments="$(
            /usr/libexec/PlistBuddy \
                -c 'Print :ProgramArguments' \
                "$SERVICE_PLIST" 2>&1 || true
        )"

        if printf '%s\n' "$service_arguments" |
            /usr/bin/grep -Fq "$MANAGEMENT_URL"; then

            log "The NetBird system service already has the required management URL."
        elif ! run_logged \
            "Persisting the Sleek management URL in the NetBird system service" \
            "$CLI_PATH" service reconfigure \
                --management-url "$MANAGEMENT_URL"; then

            repair_service_configuration
        fi
    else
        must_run \
            "Installing the NetBird system service with the Sleek management URL" \
            "$CLI_PATH" service install --management-url "$MANAGEMENT_URL"
    fi

    if ! /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1; then
        must_run \
            "Starting the NetBird system service" \
            "$CLI_PATH" service start
    fi

    /bin/sleep 2

    /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1 ||
        die "The NetBird LaunchDaemon is not loaded."
    [[ -f "$SERVICE_PLIST" ]] ||
        die "The NetBird LaunchDaemon plist is missing."

    service_arguments="$(
        /usr/libexec/PlistBuddy \
            -c 'Print :ProgramArguments' \
            "$SERVICE_PLIST" 2>&1 || true
    )"
    printf '%s\n' "$service_arguments" |
        /usr/bin/grep -Fq "$MANAGEMENT_URL" ||
        die "The NetBird system service does not contain the required management URL."

    log "Verified the NetBird system LaunchDaemon."
}

run_netbird_as_user() {
    local username="$1"
    shift

    /usr/bin/sudo -n -H -u "$username" -- "$CLI_PATH" "$@"
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

current_console_user() {
    local username

    username="$(
        /usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true
    )"

    case "$username" in
        ""|root|loginwindow|_mbsetupuser)
            return 1
            ;;
    esac

    printf '%s\n' "$username"
}

profile_id_for_user() {
    local username="$1"
    local matches
    local match_count
    local profile_rows

    profile_rows="$(
        run_netbird_as_user "$username" \
            profile list --show-id 2>>"$INSTALL_LOG"
    )" || return 3

    matches="$(
        printf '%s\n' "$profile_rows" |
            /usr/bin/awk -v profile_name="$PROFILE_NAME" '
                NR > 1 && $2 == profile_name {
                    print $1
                }
            '
    )"
    match_count="$(
        printf '%s\n' "$matches" |
            /usr/bin/awk 'NF { count++ } END { print count + 0 }'
    )"

    case "$match_count" in
        0)
            return 1
            ;;
        1)
            printf '%s\n' "$matches"
            return 0
            ;;
        *)
            return 2
            ;;
    esac
}

ensure_profile_for_user() {
    local username="$1"
    local lookup_status
    local profile_id

    set +e
    profile_id="$(profile_id_for_user "$username")"
    lookup_status=$?
    set -e

    case "$lookup_status" in
        0)
            log "Profile $PROFILE_NAME already exists for macOS user $username."
            ;;
        1)
            must_run \
                "Creating profile $PROFILE_NAME for macOS user $username" \
                run_netbird_as_user "$username" \
                    profile add "$PROFILE_NAME"

            set +e
            profile_id="$(profile_id_for_user "$username")"
            lookup_status=$?
            set -e

            [[ "$lookup_status" -eq 0 ]] ||
                die "Profile $PROFILE_NAME was created for $username but could not be uniquely resolved."
            ;;
        2)
            die "Multiple profiles named $PROFILE_NAME exist for $username; remove duplicates and rerun."
            ;;
        *)
            die "Could not list NetBird profiles for macOS user $username."
            ;;
    esac

    ENSURED_PROFILE_ID="$profile_id"
}

profile_is_active_for_user() {
    local username="$1"
    local profile_id="$2"
    local profile_rows

    profile_rows="$(
        run_netbird_as_user "$username" \
            profile list --show-id 2>>"$INSTALL_LOG"
    )" || return 1

    printf '%s\n' "$profile_rows" |
        /usr/bin/awk -v profile_id="$profile_id" '
            NR > 1 && $1 == profile_id && $3 == "✓" {
                found = 1
            }
            END {
                exit found ? 0 : 1
            }
        '
}

provision_user_profiles() {
    local console_profile_id=""
    local console_user=""
    local profile_count=0
    local user_list
    local username

    user_list="$(local_human_users)"
    [[ -n "$user_list" ]] ||
        die "No local human macOS accounts were found; cannot create $PROFILE_NAME."

    console_user="$(current_console_user || true)"

    while IFS= read -r username; do
        [[ -n "$username" ]] || continue

        ensure_profile_for_user "$username"
        profile_count=$((profile_count + 1))

        if [[ "$username" == "$console_user" ]]; then
            console_profile_id="$ENSURED_PROFILE_ID"
        fi
    done <<<"$user_list"

    if [[ -n "$console_profile_id" ]]; then
        if profile_is_active_for_user "$console_user" "$console_profile_id"; then
            log "Profile $PROFILE_NAME is already active for console user $console_user."
        else
            must_run \
                "Selecting profile $PROFILE_NAME for console user $console_user" \
                run_netbird_as_user "$console_user" \
                    profile select "$console_profile_id"
        fi

        profile_is_active_for_user "$console_user" "$console_profile_id" ||
            die "Profile $PROFILE_NAME was not selected for console user $console_user."

        log "Verified active profile $PROFILE_NAME for console user $console_user."
    else
        warn "No normal console user is logged in; profiles were created but none was selected."
    fi

    log "Verified profile $PROFILE_NAME for $profile_count local macOS user account(s)."
    log "The managed policy enforces managementURL=$MANAGEMENT_URL for every profile."
}

verify_effective_configuration() {
    local attempt
    local config_output=""
    local config_status=1

    for ((attempt = 1; attempt <= 30; attempt++)); do
        set +e
        config_output="$("$CLI_PATH" debug config 2>&1)"
        config_status=$?
        set -e

        if [[ "$config_status" -eq 0 ]] &&
            printf '%s\n' "$config_output" |
                /usr/bin/grep -Fq \
                    "\"managementUrl\": \"$MANAGEMENT_URL"; then

            log "Verified the daemon's effective management URL."
            return 0
        fi

        /bin/sleep 2
    done

    die "NetBird is installed, but the daemon did not report the required management URL."
}

main() {
    preflight
    initialize_log

    log "Starting system-wide NetBird installation for macOS."
    log "Required management URL: $MANAGEMENT_URL"
    log "Architecture: $(/usr/bin/uname -m)"

    if installed_package_is_healthy; then
        log "A healthy official NetBird package is already installed; skipping package installation."
    else
        download_and_install_package
    fi

    verify_installation
    apply_managed_policy
    configure_system_service
    provision_user_profiles
    verify_effective_configuration

    log "NetBird installation and configuration completed successfully."
    log "All macOS users can launch $APP_PATH and complete SSO."
    log "No setup key was used and no OAuth session was started by this script."
    log "Installation log: $INSTALL_LOG"
}

main "$@"
