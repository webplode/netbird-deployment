#!/usr/bin/env bash
# Shared constants and helpers for the NetBird migration scripts.
# Source this file; do not execute it.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Fixed inventory, verified read-only on 2026-08-13 against account 560723684645.
# ---------------------------------------------------------------------------
export MIG_REGION="ap-southeast-1"
export MIG_ACCOUNT="560723684645"
export MIG_DOMAIN="nbvpn.sleek.com"

# Old (current production) instances.
export OLD_MGMT_ID="i-0ebece0782d6bd148"        # NetBird MGMT Server, Ubuntu 24.04, t3.small
export OLD_PEER1_ID="i-071741f3f69aabd73"       # nb-prod-exitnode-01, AL2023, t3.small
export OLD_PEER2_ID="i-006ffee7739f25a05"       # nb-prod-exitnode-02, AL2023, t3.small
export OLD_MGMT_ROOT_VOL="vol-096c5b0c627728431" # 30 GiB gp3, UNENCRYPTED, holds the docker volume

# Elastic IPs (allocation IDs are the durable identity; IPs shown for humans).
export EIP_MGMT_ALLOC="eipalloc-0cdfcdf07221f2f96"  # 18.136.135.128 -> old mgmt
export EIP_PEER1_ALLOC="eipalloc-03cb123d9dd951339" # 18.143.19.220  -> old exitnode-01
export EIP_PEER2_ALLOC="eipalloc-02f15b26c1f2b84ea" # 47.130.71.73   -> old exitnode-02
export EIP_MGMT_IP="18.136.135.128"
export EIP_PEER1_IP="18.143.19.220"
export EIP_PEER2_IP="47.130.71.73"

# Old-management runtime layout (Docker Compose project "netbird-new").
export OLD_COMPOSE_PROJECT="netbird-new"
export OLD_MGMT_VOLUME="netbird-new_netbird_management"

# Migration scratch bucket (created by 00-preflight.sh, lifecycle-expired).
export MIG_BUCKET="sleek-netbird-migration-scratch-${MIG_ACCOUNT}"

# Terraform stack locations.
MIG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MIG_ROOT
export REPO_ROOT="${MIG_ROOT%/migration}"
export TF_DIR="${REPO_ROOT}/infra/terraform"
export FETCH_DIR="${MIG_ROOT}/.fetched"
export PINNED_MGMT_VERSION="0.76.1"

# ---------------------------------------------------------------------------
# Credentials. Every write script requires MIGRATION_AWS_PROFILE and refuses
# read-only roles. Read helpers may fall back to the read-only profile.
# ---------------------------------------------------------------------------
awsw() { aws --profile "${MIGRATION_AWS_PROFILE:?Set MIGRATION_AWS_PROFILE to the admin SSO profile}" --region "$MIG_REGION" "$@"; }

require_cmds() {
  local missing=0 cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "FATAL: missing required command: $cmd" >&2; missing=1; }
  done
  [[ "$missing" -eq 0 ]]
}

require_write_profile() {
  local arn
  arn="$(awsw sts get-caller-identity --query Arn --output text)"
  echo "Caller: $arn"
  if [[ "$arn" == *ViewOnly* || "$arn" == *readonly* || "$arn" == *ReadOnly* ]]; then
    echo "FATAL: MIGRATION_AWS_PROFILE resolves to a read-only role. Use the admin profile." >&2
    return 1
  fi
}

confirm_phrase() {
  # confirm_phrase "prompt" "EXPECTED"
  local answer
  read -r -p "$1 Type '$2' to continue: " answer
  [[ "$answer" == "$2" ]] || { echo "Aborted: confirmation phrase mismatch." >&2; return 1; }
}

log() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------------------
# SSM command execution with output capture.
#   ssm_run <instance-id> <timeout-seconds> <<'EOF' ... script ... EOF
# ---------------------------------------------------------------------------
ssm_run() {
  local instance_id="$1" timeout="$2" script command_id status b64
  script="$(cat)"
  # AWS-RunShellScript executes with /bin/sh (dash on Ubuntu); route the script
  # into a real bash and dodge all sh-level quoting via base64.
  b64="$(printf '%s' "$script" | base64 | tr -d '\n')"
  command_id="$(awsw ssm send-command \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --comment "sleek-netbird-migration" \
    --timeout-seconds "$timeout" \
    --parameters "$(jq -n --arg b "$b64" --arg t "$timeout" \
      '{commands: [("printf %s " + $b + " | base64 -d | /bin/bash")], executionTimeout: [$t]}')" \
    --query 'Command.CommandId' --output text)"
  while :; do
    status="$(awsw ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
      --query Status --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Success) break ;;
      Pending|InProgress|Delayed) sleep 5 ;;
      *)
        echo "SSM command $command_id on $instance_id ended: $status" >&2
        awsw ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
          --query '{stdout:StandardOutputContent,stderr:StandardErrorContent}' --output json >&2
        return 1 ;;
    esac
  done
  awsw ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
    --query StandardOutputContent --output text
}

ssm_is_managed() {
  local instance_id="$1"
  [[ "$(awsw ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=${instance_id}" \
        --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" == "Online" ]]
}

# Run a script on the OLD management host: SSM when registered, otherwise SSH.
# Default verified 2026-08-13: iznogoud@10.241.0.14 with passwordless sudo.
export OLD_MGMT_SSH="${OLD_MGMT_SSH:-ssh -o BatchMode=yes iznogoud@10.241.0.14}"
run_on_old_mgmt() {
  local timeout="$1" script
  script="$(cat)"
  if ssm_is_managed "$OLD_MGMT_ID"; then
    ssm_run "$OLD_MGMT_ID" "$timeout" <<<"$script"
  elif [[ -n "${OLD_MGMT_SSH:-}" ]]; then
    # shellcheck disable=SC2029
    ${OLD_MGMT_SSH} "sudo bash -s" <<<"$script"
  else
    echo "FATAL: old management is not SSM-managed and OLD_MGMT_SSH is not set." >&2
    echo "Run '00-preflight.sh attach-ssm' first, or export OLD_MGMT_SSH." >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Terraform helpers.
# ---------------------------------------------------------------------------
tf() {
  AWS_PROFILE="${MIGRATION_AWS_PROFILE:?Set MIGRATION_AWS_PROFILE to the admin SSO profile}" \
  AWS_REGION="$MIG_REGION" \
  terraform -chdir="$TF_DIR" "$@"
}

tf_output_json() { tf output -json "$1"; }

new_instance_id() {
  # new_instance_id management|peer_1|peer_2
  tf_output_json instances | jq -r --arg k "$1" '.[$k].instance_id'
}

new_temp_ip() {
  tf_output_json instances | jq -r --arg k "$1" '.[$k].temporary_public_ip'
}

# plan_readback <plan-file> <jq-filter> <expected> <label>
plan_readback() {
  local plan_file="$1" filter="$2" expected="$3" label="$4" actual
  actual="$(tf show -json "$plan_file" | jq -c "$filter")"
  if [[ "$actual" != "$expected" ]]; then
    echo "FATAL plan readback: $label — expected $expected, plan has $actual" >&2
    return 1
  fi
  echo "readback OK: $label = $actual"
}

count_creates() {
  # jq filter string: creates of a given resource type
  printf '[.resource_changes[]? | select(.type == "%s" and (.change.actions == ["create"]))] | length' "$1"
}

set_tfvar() {
  # set_tfvar <dotted.key or key> <raw-hcl-value>  (see set-tfvar.py)
  python3 "${MIG_ROOT}/scripts/set-tfvar.py" "${TF_DIR}/terraform.tfvars" "$1" "$2"
}

verify_eip_holder() {
  # verify_eip_holder <alloc-id> <expected-instance-id>
  local holder
  holder="$(awsw ec2 describe-addresses --allocation-ids "$1" \
    --query 'Addresses[0].InstanceId' --output text)"
  if [[ "$holder" != "$2" ]]; then
    echo "FATAL: EIP $1 is on '$holder', expected '$2'. Refresh and review before continuing." >&2
    return 1
  fi
}

http_expect() {
  # http_expect <expected-code> <curl args...>
  local expected="$1"; shift
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$@")"
  if [[ "$code" != "$expected" ]]; then
    echo "FATAL: expected HTTP $expected, got $code for: $*" >&2
    return 1
  fi
  echo "HTTP $code OK: $*"
}
