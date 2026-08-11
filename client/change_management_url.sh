#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

# Change the management endpoint for an existing macOS installation created by
# install_netbird.sh. This script changes only the installer-owned managed
# preference and the paired LaunchDaemon argument.

readonly CLI_PATH="/usr/local/bin/netbird"
readonly SERVICE_LABEL="netbird"
readonly SERVICE_PLIST="/Library/LaunchDaemons/netbird.plist"
readonly MANAGED_PREFS_PATH="/Library/Managed Preferences/io.netbird.client.plist"
readonly EXIT_INVOCATION=2
readonly EXIT_PRIVILEGE=3
readonly EXIT_PREREQUISITE=4
readonly EXIT_PERSISTENCE=5

TARGET_URL=""
TEMP_DIR=""
POLICY_SNAPSHOT=""
SERVICE_SNAPSHOT=""
POLICY_STAGE=""
SERVICE_STAGE=""
POLICY_OLD_URL=""
SERVICE_OLD_URL=""
POLICY_BASELINE_HASH=""
SERVICE_BASELINE_HASH=""
SERVICE_URL_INDEX=-1
SERVICE_SNAPSHOT_URL_INDEX=-1
SERVICE_CANONICAL=0
SERVICE_WAS_LOADED=0
declare -a SERVICE_ARGS=()

timestamp() {
    /bin/date '+%Y-%m-%d %H:%M:%S'
}

emit() {
    local level="$1"
    shift
    printf '[%s] %s: %s\n' "$(timestamp)" "$level" "$*" >&2
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
    [[ -z "$POLICY_STAGE" || ! -e "$POLICY_STAGE" ]] || /bin/rm -f "$POLICY_STAGE"
    [[ -z "$SERVICE_STAGE" || ! -e "$SERVICE_STAGE" ]] || /bin/rm -f "$SERVICE_STAGE"
    [[ -z "$TEMP_DIR" || ! -d "$TEMP_DIR" ]] || /bin/rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

valid_percent_escapes() {
    local remainder="$1"

    while [[ "$remainder" == *%* ]]; do
        remainder="${remainder#*%}"
        [[ "$remainder" =~ ^[0-9A-Fa-f][0-9A-Fa-f] ]] || return 1
        remainder="${remainder:2}"
    done
    return 0
}

valid_ipv6_literal() {
    local address="$1"

    /usr/bin/awk -v address="$address" '
        function count_side(side, pieces, count, cursor) {
            if (side == "") {
                return 0
            }
            count = split(side, pieces, ":")
            for (cursor = 1; cursor <= count; cursor++) {
                if (pieces[cursor] !~ /^[0-9A-Fa-f]{1,4}$/) {
                    invalid = 1
                }
            }
            return count
        }
        BEGIN {
            if (address !~ /^[0-9A-Fa-f:]+$/ || index(address, ":") == 0 || index(address, ":::") != 0) {
                exit 1
            }

            compressed = address
            compression_count = gsub(/::/, "@", compressed)
            if (compression_count > 1) {
                exit 1
            }

            if (compression_count == 0) {
                segment_count = count_side(address)
                exit (!invalid && segment_count == 8) ? 0 : 1
            }

            compression_index = index(address, "::")
            left = substr(address, 1, compression_index - 1)
            right = substr(address, compression_index + 2)
            segment_count = count_side(left) + count_side(right)
            exit (!invalid && segment_count < 8) ? 0 : 1
        }
    '
}

normalize_management_url() {
    local input="$1"
    local authority
    local host
    local host_display
    local port="443"
    local path
    local query
    local explicit_port=""
    local normalized_port=""

    [[ -n "$input" ]] || return 1
    case "$input" in
        *[[:space:]]*|*\\*|*\"*|*\'*|*\;*|*\`*|*\$*) return 1 ;;
    esac
    valid_percent_escapes "$input" || return 1

    if [[ ! "$input" =~ ^[Hh][Tt][Tt][Pp][Ss]://([^/?#]+)(/[^?#]*)?(\?[^#]*)?$ ]]; then
        return 1
    fi

    authority="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]:-}"
    query="${BASH_REMATCH[3]:-}"

    [[ "$authority" != *@* ]] || return 1

    if [[ "$authority" == \[* ]]; then
        if [[ ! "$authority" =~ ^(\[[0-9A-Fa-f:.]+\])(:([0-9]+))?$ ]]; then
            return 1
        fi
        host="${BASH_REMATCH[1]}"
        explicit_port="${BASH_REMATCH[3]:-}"
        valid_ipv6_literal "${host:1:${#host}-2}" || return 1
    else
        if [[ "$authority" == *:*:* ]]; then
            return 1
        fi
        if [[ "$authority" =~ ^([^:]+):([0-9]+)$ ]]; then
            host="${BASH_REMATCH[1]}"
            explicit_port="${BASH_REMATCH[2]}"
        else
            host="$authority"
        fi
        [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
        [[ "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
    fi

    [[ -n "$host" ]] || return 1
    if [[ -n "$explicit_port" ]]; then
        [[ "$explicit_port" =~ ^[0-9]+$ ]] || return 1
        normalized_port="$explicit_port"
        while [[ "${#normalized_port}" -gt 1 && "$normalized_port" == 0* ]]; do
            normalized_port="${normalized_port#0}"
        done
        [[ "${#normalized_port}" -le 5 ]] || return 1
        [[ "$normalized_port" != "0" ]] || return 1
        if [[ "${#normalized_port}" -eq 5 && "$normalized_port" > "65535" ]]; then
            return 1
        fi
        port="$((10#$normalized_port))"
    fi

    while [[ "$path" != "/" && "$path" == */ ]]; do
        path="${path%/}"
    done
    [[ "$path" != "/" ]] || path=""

    host_display="$(printf '%s' "$host" | /usr/bin/awk '{ print tolower($0) }')"
    printf 'https://%s' "$host_display"
    [[ "$port" == "443" ]] || printf ':%s' "$port"
    printf '%s%s\n' "$path" "$query"
}

urls_equivalent() {
    local left
    local right

    left="$(normalize_management_url "$1")" || return 1
    right="$(normalize_management_url "$2")" || return 1
    [[ "$left" == "$right" ]]
}

require_commands() {
    local command_path
    for command_path in \
        /bin/chmod \
        /bin/cp \
        /bin/date \
        /bin/launchctl \
        /bin/mv \
        /bin/rm \
        /bin/sleep \
        /usr/bin/awk \
        /usr/bin/grep \
        /usr/bin/id \
        /usr/bin/mktemp \
        /usr/bin/plutil \
        /usr/bin/shasum \
        /usr/bin/stat \
        /usr/bin/uname \
        /usr/libexec/PlistBuddy \
        /usr/sbin/chown; do

        [[ -x "$command_path" ]] ||
            die "Required macOS command is unavailable: $command_path" "$EXIT_PREREQUISITE"
    done
}

file_metadata_is_installer_owned() {
    local path="$1"
    [[ "$(/usr/bin/stat -f '%Su' "$path")" == "root" ]] || return 1
    [[ "$(/usr/bin/stat -f '%Sg' "$path")" == "wheel" ]] || return 1
    [[ "$(/usr/bin/stat -f '%Lp' "$path")" == "644" ]] || return 1
}

file_metadata_matches_snapshot() {
    local path="$1"
    local snapshot="$2"
    [[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$path")" == \
        "$(/usr/bin/stat -f '%u:%g:%Lp' "$snapshot")" ]]
}

read_service_arguments() {
    local path="$1"
    local index=0
    local value
    local flag_count=0

    SERVICE_ARGS=()
    SERVICE_URL_INDEX=-1

    while value="$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:$index" "$path" 2>/dev/null)"; do
        [[ "$value" != *$'\n'* ]] || return 1
        SERVICE_ARGS[$index]="$value"
        index=$((index + 1))
    done
    ((index > 0)) || return 1

    for ((index = 0; index < ${#SERVICE_ARGS[@]}; index++)); do
        if [[ "${SERVICE_ARGS[$index]}" == "--management-url" ]]; then
            flag_count=$((flag_count + 1))
            SERVICE_URL_INDEX=$((index + 1))
        fi
    done

    [[ "$flag_count" -eq 1 ]] || return 1
    [[ "$SERVICE_URL_INDEX" -lt "${#SERVICE_ARGS[@]}" ]] || return 1
    [[ -n "${SERVICE_ARGS[$SERVICE_URL_INDEX]}" ]] || return 1
}

service_definition_is_canonical() {
    [[ "${#SERVICE_ARGS[@]}" -ge 5 ]] || return 1
    [[ "${SERVICE_ARGS[0]}" == "$CLI_PATH" ]] || return 1
    [[ "${SERVICE_ARGS[1]}" == "service" ]] || return 1
    [[ "${SERVICE_ARGS[2]}" == "run" ]] || return 1
    return 0
}

plist_semantic_hash_without_url() {
    local source="$1"
    local key_path="$2"
    local copy="$TEMP_DIR/hash.$RANDOM.$RANDOM.plist"
    local hash

    /bin/cp "$source" "$copy" || return 1
    /usr/libexec/PlistBuddy -c "Set $key_path __NETBIRD_URL_SENTINEL__" "$copy" >/dev/null || return 1
    /usr/bin/plutil -convert xml1 "$copy" || return 1
    hash="$(/usr/bin/shasum -a 256 "$copy" | /usr/bin/awk '{ print $1 }')" || return 1
    /bin/rm -f "$copy"
    printf '%s\n' "$hash"
}

wait_for_bootout() {
    local label="$1"
    local attempt

    for ((attempt = 1; attempt <= 50; attempt++)); do
        /bin/launchctl print "$label" >/dev/null 2>&1 || return 0
        /bin/sleep 0.2
    done
    return 0
}

bootstrap_with_retry() {
    local domain="$1"
    local plist="$2"
    local attempt

    for ((attempt = 1; attempt <= 5; attempt++)); do
        /bin/launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1 && return 0
        /bin/sleep 0.3
    done
    return 1
}

raw_file_hash() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

policy_semantic_hash() {
    plist_semantic_hash_without_url "$1" ':managementURL'
}

service_semantic_hash() {
    plist_semantic_hash_without_url "$1" ":ProgramArguments:$SERVICE_URL_INDEX"
}

preflight() {
    local normalized
    local loaded_service

    [[ "$#" -eq 1 ]] ||
        die "Usage: $0 <absolute-https-management-url>" "$EXIT_INVOCATION"

    normalized="$(normalize_management_url "$1")" ||
        die "Management URL must be an absolute HTTPS URL without credentials, fragments, whitespace, or an invalid port." "$EXIT_INVOCATION"
    TARGET_URL="$normalized"

    [[ "$(/usr/bin/uname -s)" == "Darwin" ]] ||
        die "This management URL changer supports macOS only." "$EXIT_PRIVILEGE"
    [[ "$(/usr/bin/id -u)" -eq 0 ]] ||
        die "Run this management URL changer as root." "$EXIT_PRIVILEGE"

    require_commands
    [[ -x "$CLI_PATH" ]] ||
        die "Existing NetBird CLI is missing or not executable at $CLI_PATH." "$EXIT_PREREQUISITE"
    [[ -f "$MANAGED_PREFS_PATH" ]] ||
        die "Installer-owned managed preferences are missing at $MANAGED_PREFS_PATH." "$EXIT_PREREQUISITE"
    [[ -f "$SERVICE_PLIST" ]] ||
        die "Installer-owned LaunchDaemon is missing at $SERVICE_PLIST." "$EXIT_PREREQUISITE"
    /usr/bin/plutil -lint "$MANAGED_PREFS_PATH" >/dev/null 2>&1 ||
        die "Managed preferences are malformed; no state was changed." "$EXIT_PREREQUISITE"
    /usr/bin/plutil -lint "$SERVICE_PLIST" >/dev/null 2>&1 ||
        die "LaunchDaemon plist is malformed; no state was changed." "$EXIT_PREREQUISITE"
    file_metadata_is_installer_owned "$MANAGED_PREFS_PATH" ||
        die "Managed preferences must be owned by root:wheel with mode 0644." "$EXIT_PREREQUISITE"
    file_metadata_is_installer_owned "$SERVICE_PLIST" ||
        die "LaunchDaemon plist must be owned by root:wheel with mode 0644." "$EXIT_PREREQUISITE"
    if loaded_service="$(/bin/launchctl print "system/$SERVICE_LABEL" 2>/dev/null)"; then
        printf '%s\n' "$loaded_service" | /usr/bin/grep -Fq "$CLI_PATH" ||
            die "The loaded system/$SERVICE_LABEL job does not match $CLI_PATH." "$EXIT_PREREQUISITE"
        SERVICE_WAS_LOADED=1
    else
        log "system/$SERVICE_LABEL is not loaded; persistent configuration will be updated without starting it."
    fi

    POLICY_OLD_URL="$(/usr/libexec/PlistBuddy -c 'Print :managementURL' "$MANAGED_PREFS_PATH" 2>/dev/null)" ||
        die "Managed preferences do not contain managementURL." "$EXIT_PREREQUISITE"
    normalize_management_url "$POLICY_OLD_URL" >/dev/null ||
        die "Managed preferences contain an invalid managementURL." "$EXIT_PREREQUISITE"

    read_service_arguments "$SERVICE_PLIST" ||
        die "LaunchDaemon must contain exactly one paired --management-url argument." "$EXIT_PREREQUISITE"
    SERVICE_SNAPSHOT_URL_INDEX="$SERVICE_URL_INDEX"
    SERVICE_OLD_URL="${SERVICE_ARGS[$SERVICE_URL_INDEX]}"
    normalize_management_url "$SERVICE_OLD_URL" >/dev/null ||
        die "LaunchDaemon contains an invalid paired management URL." "$EXIT_PREREQUISITE"
    if service_definition_is_canonical; then
        SERVICE_CANONICAL=1
    else
        die "LaunchDaemon is not in the canonical installer-owned NetBird service shape." "$EXIT_PREREQUISITE"
    fi
}

take_snapshots() {
    TEMP_DIR="$(/usr/bin/mktemp -d /private/tmp/netbird-management-url.XXXXXX)"
    POLICY_SNAPSHOT="$TEMP_DIR/managed-preferences.plist"
    SERVICE_SNAPSHOT="$TEMP_DIR/netbird.plist"
    /bin/cp -p "$MANAGED_PREFS_PATH" "$POLICY_SNAPSHOT"
    /bin/cp -p "$SERVICE_PLIST" "$SERVICE_SNAPSHOT"
    POLICY_BASELINE_HASH="$(policy_semantic_hash "$POLICY_SNAPSHOT")"
    SERVICE_BASELINE_HASH="$(service_semantic_hash "$SERVICE_SNAPSHOT")"
}

atomic_restore() {
    local snapshot="$1"
    local destination="$2"
    local directory="${destination%/*}"
    local base="${destination##*/}"
    local stage

    stage="$(/usr/bin/mktemp "$directory/.${base}.restore.XXXXXX")" || return 1
    if ! /bin/cp -p "$snapshot" "$stage" ||
        ! /usr/sbin/chown root:wheel "$stage" ||
        ! /bin/chmod 644 "$stage" ||
        ! /bin/mv -f "$stage" "$destination"; then

        /bin/rm -f "$stage"
        return 1
    fi
}

restore_initial_state() {
    local failed=0
    local current_policy_hash=""
    local current_service_hash=""
    local snapshot_policy_hash=""
    local snapshot_service_hash=""

    warn "Restoring the original persistence state."
    if [[ "$SERVICE_WAS_LOADED" -eq 1 ]] &&
        /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1; then
        /bin/launchctl bootout "system/$SERVICE_LABEL" >/dev/null 2>&1 ||
            die "Could not stop system/$SERVICE_LABEL before rollback; target persistence was left unchanged." "$EXIT_PERSISTENCE"
        wait_for_bootout "system/$SERVICE_LABEL"
    elif /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1; then
        /bin/launchctl bootout "system/$SERVICE_LABEL" >/dev/null 2>&1 ||
            die "Could not restore the original unloaded state for system/$SERVICE_LABEL; target persistence was left unchanged." "$EXIT_PERSISTENCE"
        wait_for_bootout "system/$SERVICE_LABEL"
    fi

    atomic_restore "$SERVICE_SNAPSHOT" "$SERVICE_PLIST" || failed=1
    atomic_restore "$POLICY_SNAPSHOT" "$MANAGED_PREFS_PATH" || failed=1

    /usr/bin/plutil -lint "$SERVICE_PLIST" >/dev/null 2>&1 || failed=1
    /usr/bin/plutil -lint "$MANAGED_PREFS_PATH" >/dev/null 2>&1 || failed=1
    file_metadata_is_installer_owned "$SERVICE_PLIST" || failed=1
    file_metadata_is_installer_owned "$MANAGED_PREFS_PATH" || failed=1
    file_metadata_matches_snapshot "$SERVICE_PLIST" "$SERVICE_SNAPSHOT" || failed=1
    file_metadata_matches_snapshot "$MANAGED_PREFS_PATH" "$POLICY_SNAPSHOT" || failed=1
    current_service_hash="$(raw_file_hash "$SERVICE_PLIST")" || failed=1
    snapshot_service_hash="$(raw_file_hash "$SERVICE_SNAPSHOT")" || failed=1
    current_policy_hash="$(raw_file_hash "$MANAGED_PREFS_PATH")" || failed=1
    snapshot_policy_hash="$(raw_file_hash "$POLICY_SNAPSHOT")" || failed=1
    [[ -n "$current_service_hash" && "$current_service_hash" == "$snapshot_service_hash" ]] || failed=1
    [[ -n "$current_policy_hash" && "$current_policy_hash" == "$snapshot_policy_hash" ]] || failed=1

    read_service_arguments "$SERVICE_PLIST" || failed=1
    if [[ "$failed" -eq 0 ]]; then
        urls_equivalent "${SERVICE_ARGS[$SERVICE_URL_INDEX]}" "$SERVICE_OLD_URL" || failed=1
        urls_equivalent "$(/usr/libexec/PlistBuddy -c 'Print :managementURL' "$MANAGED_PREFS_PATH" 2>/dev/null)" "$POLICY_OLD_URL" || failed=1
    fi

    if [[ "$failed" -ne 0 ]]; then
        die "Both old snapshots could not be restored and verified; system/$SERVICE_LABEL remains stopped." "$EXIT_PERSISTENCE"
    fi

    if [[ "$SERVICE_WAS_LOADED" -eq 1 ]]; then
        bootstrap_with_retry system "$SERVICE_PLIST" || failed=1
        /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1 || failed=1
    elif /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1; then
        failed=1
    fi

    if [[ "$failed" -ne 0 ]]; then
        die "Old persistence was restored, but the original LaunchDaemon loaded state did not recover." "$EXIT_PERSISTENCE"
    fi
    log "Verified exact old persistence and the original LaunchDaemon loaded state."
}

fail_persistence() {
    local message="$1"
    restore_initial_state
    die "$message" "$EXIT_PERSISTENCE"
}

write_managed_policy() {
    local directory="${MANAGED_PREFS_PATH%/*}"
    local configured
    local hash

    POLICY_STAGE="$(/usr/bin/mktemp "$directory/.io.netbird.client.XXXXXX")" || return 1
    /bin/cp -p "$MANAGED_PREFS_PATH" "$POLICY_STAGE" || return 1
    /usr/libexec/PlistBuddy -c "Set :managementURL $TARGET_URL" "$POLICY_STAGE" >/dev/null || return 1
    /usr/bin/plutil -convert xml1 "$POLICY_STAGE" || return 1
    /usr/bin/plutil -lint "$POLICY_STAGE" >/dev/null || return 1
    configured="$(/usr/libexec/PlistBuddy -c 'Print :managementURL' "$POLICY_STAGE")" || return 1
    urls_equivalent "$configured" "$TARGET_URL" || return 1
    hash="$(policy_semantic_hash "$POLICY_STAGE")" || return 1
    [[ "$hash" == "$POLICY_BASELINE_HASH" ]] || return 1
    /usr/sbin/chown root:wheel "$POLICY_STAGE" || return 1
    /bin/chmod 644 "$POLICY_STAGE" || return 1
    /bin/mv -f "$POLICY_STAGE" "$MANAGED_PREFS_PATH" || return 1
    POLICY_STAGE=""
    log "Persisted managementURL=$TARGET_URL in managed preferences."
}

verify_policy() {
    local configured
    local hash
    /usr/bin/plutil -lint "$MANAGED_PREFS_PATH" >/dev/null 2>&1 || return 1
    file_metadata_is_installer_owned "$MANAGED_PREFS_PATH" || return 1
    configured="$(/usr/libexec/PlistBuddy -c 'Print :managementURL' "$MANAGED_PREFS_PATH" 2>/dev/null)" || return 1
    urls_equivalent "$configured" "$TARGET_URL" || return 1
    hash="$(policy_semantic_hash "$MANAGED_PREFS_PATH")" || return 1
    [[ "$hash" == "$POLICY_BASELINE_HASH" ]]
}

write_service_plist() {
    local directory="${SERVICE_PLIST%/*}"
    local hash

    [[ "$SERVICE_CANONICAL" -eq 1 ]] || return 1
    SERVICE_URL_INDEX="$SERVICE_SNAPSHOT_URL_INDEX"
    SERVICE_STAGE="$(/usr/bin/mktemp "$directory/.netbird.XXXXXX")" || return 1
    /bin/cp -p "$SERVICE_SNAPSHOT" "$SERVICE_STAGE" || return 1
    /usr/libexec/PlistBuddy \
        -c "Set :ProgramArguments:$SERVICE_URL_INDEX $TARGET_URL" \
        "$SERVICE_STAGE" >/dev/null || return 1
    /usr/bin/plutil -lint "$SERVICE_STAGE" >/dev/null || return 1
    hash="$(service_semantic_hash "$SERVICE_STAGE")" || return 1
    [[ "$hash" == "$SERVICE_BASELINE_HASH" ]] || return 1
    /usr/sbin/chown root:wheel "$SERVICE_STAGE" || return 1
    /bin/chmod 644 "$SERVICE_STAGE" || return 1

    if [[ "$SERVICE_WAS_LOADED" -eq 1 ]] &&
        /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1; then
        /bin/launchctl bootout "system/$SERVICE_LABEL" >/dev/null 2>&1 || return 1
        wait_for_bootout "system/$SERVICE_LABEL"
    elif /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1; then
        /bin/launchctl bootout "system/$SERVICE_LABEL" >/dev/null 2>&1 || return 1
        wait_for_bootout "system/$SERVICE_LABEL"
    fi
    /bin/mv -f "$SERVICE_STAGE" "$SERVICE_PLIST" || return 1
    SERVICE_STAGE=""
    if [[ "$SERVICE_WAS_LOADED" -eq 1 ]]; then
        bootstrap_with_retry system "$SERVICE_PLIST" || return 1
    fi
    log "Persisted the canonical LaunchDaemon with only its paired management URL changed."
}

verify_service() {
    local hash
    /usr/bin/plutil -lint "$SERVICE_PLIST" >/dev/null 2>&1 || return 1
    file_metadata_is_installer_owned "$SERVICE_PLIST" || return 1
    if [[ "$SERVICE_WAS_LOADED" -eq 1 ]]; then
        /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1 || return 1
    elif /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1; then
        return 1
    fi
    read_service_arguments "$SERVICE_PLIST" || return 1
    urls_equivalent "${SERVICE_ARGS[$SERVICE_URL_INDEX]}" "$TARGET_URL" || return 1
    hash="$(service_semantic_hash "$SERVICE_PLIST")" || return 1
    [[ "$hash" == "$SERVICE_BASELINE_HASH" ]]
}

configure_service() {
    local current_url

    read_service_arguments "$SERVICE_PLIST" || return 1
    current_url="${SERVICE_ARGS[$SERVICE_URL_INDEX]}"
    if urls_equivalent "$current_url" "$TARGET_URL"; then
        log "LaunchDaemon already contains the target management URL."
    else
        write_service_plist || return 1
    fi

    verify_service
}

main() {
    preflight "$@"
    take_snapshots

    log "Changing the NetBird management URL to $TARGET_URL."
    write_managed_policy || fail_persistence "Could not safely persist the managed preference."
    verify_policy || fail_persistence "Managed-preference verification failed."
    configure_service || fail_persistence "Service reconfiguration could not preserve and verify the installer-owned LaunchDaemon."

    verify_policy || fail_persistence "Final managed-preference verification failed."
    verify_service || fail_persistence "Final LaunchDaemon persistence verification failed."

    log "Successfully verified management URL $TARGET_URL in managed preferences and LaunchDaemon persistence."
    warn "NetBird connection state was intentionally not changed or required. A different control plane may require re-enrollment or SSO."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
