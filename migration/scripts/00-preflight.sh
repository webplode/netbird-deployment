#!/usr/bin/env bash
# Phase A step 0 — pre-flight. Safe to re-run; no NetBird service is touched.
#
#   MIGRATION_AWS_PROFILE=<admin> ./00-preflight.sh            # full pre-flight
#   MIGRATION_AWS_PROFILE=<admin> ./00-preflight.sh attach-ssm # only SSM access part
#
# What it does:
#   1. verifies the admin profile is not read-only;
#   2. snapshots the old management root volume (first backup it will ever have);
#   3. creates the encrypted, lifecycle-expired migration scratch bucket;
#   4. gives the old management host SSM access (role + instance profile);
#   5. fetches the LIVE runtime config files from the old host into .fetched/live/;
#   6. asserts the live NetBird management version equals the Terraform pin;
#   7. optionally exports a NetBird API backup when NETBIRD_PAT is set.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmds aws jq curl python3
require_write_profile

MIG_ROLE="sleek-netbird-migration-ssm"

attach_ssm() {
  log "Ensuring migration SSM role/instance-profile exists"
  if ! awsw iam get-role --role-name "$MIG_ROLE" >/dev/null 2>&1; then
    awsw iam create-role --role-name "$MIG_ROLE" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
      --tags Key=Name,Value="$MIG_ROLE" Key=Migration,Value=netbird-x86-to-arm64-2026-08 >/dev/null
    awsw iam attach-role-policy --role-name "$MIG_ROLE" \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  fi
  if ! awsw iam get-instance-profile --instance-profile-name "$MIG_ROLE" >/dev/null 2>&1; then
    awsw iam create-instance-profile --instance-profile-name "$MIG_ROLE" >/dev/null
    awsw iam add-role-to-instance-profile --instance-profile-name "$MIG_ROLE" --role-name "$MIG_ROLE"
    sleep 10 # IAM propagation
  fi

  local iid
  for iid in "$OLD_MGMT_ID" "$OLD_PEER1_ID" "$OLD_PEER2_ID"; do
    local existing
    existing="$(awsw ec2 describe-iam-instance-profile-associations \
      --filters "Name=instance-id,Values=$iid" \
      --query 'IamInstanceProfileAssociations[?State==`associated`].IamInstanceProfile.Arn' --output text)"
    if [[ -z "$existing" || "$existing" == "None" ]]; then
      log "Attaching $MIG_ROLE to $iid"
      awsw ec2 associate-iam-instance-profile --instance-id "$iid" \
        --iam-instance-profile Name="$MIG_ROLE" >/dev/null
    else
      echo "$iid already has instance profile: $existing"
    fi
  done

  log "Waiting for the old management host to register with SSM (Ubuntu snap agent retries on its own; up to 15 min)"
  local i
  for i in $(seq 1 45); do
    if ssm_is_managed "$OLD_MGMT_ID"; then
      echo "SSM Online: $OLD_MGMT_ID"
      return 0
    fi
    sleep 20
  done
  cat >&2 <<'EOT'
WARNING: old management did not register with SSM. The snap amazon-ssm-agent
may need a restart, which itself needs access. Options:
  a) export OLD_MGMT_SSH="ssh ubuntu@18.136.135.128"   (existing key management-stage-sg)
     and re-run; every old-host step then runs over SSH instead.
  b) temporarily open SSH + use EC2 Instance Connect, then:
     sudo snap restart amazon-ssm-agent
EOT
  return 1
}

snapshot_old_mgmt() {
  log "Snapshotting old management root volume $OLD_MGMT_ROOT_VOL (pre-migration backup)"
  local snap_id
  snap_id="$(awsw ec2 create-snapshot --volume-id "$OLD_MGMT_ROOT_VOL" \
    --description "pre-migration backup of NetBird MGMT root ($OLD_MGMT_ID) $(date -u +%Y-%m-%dT%H:%MZ)" \
    --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=netbird-mgmt-pre-migration},{Key=Migration,Value=netbird-x86-to-arm64-2026-08}]' \
    --query SnapshotId --output text)"
  echo "Snapshot started: $snap_id (completes in background; verified again by 05)"
  echo "$snap_id" > "${FETCH_DIR}/mgmt-root-snapshot-id.txt"
}

create_scratch_bucket() {
  log "Ensuring scratch bucket $MIG_BUCKET"
  if ! awsw s3api head-bucket --bucket "$MIG_BUCKET" 2>/dev/null; then
    awsw s3api create-bucket --bucket "$MIG_BUCKET" \
      --create-bucket-configuration LocationConstraint="$MIG_REGION" >/dev/null
  fi
  awsw s3api put-public-access-block --bucket "$MIG_BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  awsw s3api put-bucket-encryption --bucket "$MIG_BUCKET" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'
  awsw s3api put-bucket-lifecycle-configuration --bucket "$MIG_BUCKET" \
    --lifecycle-configuration '{"Rules":[{"ID":"expire-migration-artifacts","Status":"Enabled","Filter":{},"Expiration":{"Days":7},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":1}}]}'
  echo "Scratch bucket ready (SSE-KMS, public access blocked, 7-day expiry)."
}

fetch_live_config() {
  log "Fetching LIVE runtime config from the old management host"
  install -d -m 0700 "${FETCH_DIR}/live"
  local out
  out="$(run_on_old_mgmt 300 <<'EOF'
set -Eeuo pipefail
compose_dir="$(docker inspect netbird-caddy --format '{{ range .Mounts }}{{ if eq .Destination "/etc/caddy/Caddyfile" }}{{ .Source }}{{ end }}{{ end }}' | xargs dirname)"
echo "COMPOSE_DIR=$compose_dir"
for f in management.json relay.env turnserver.conf dashboard.env .env Caddyfile docker-compose.yml; do
  if [[ -f "$compose_dir/$f" ]]; then
    printf '===FILE %s===\n' "$f"
    base64 < "$compose_dir/$f"
    printf '===END %s===\n' "$f"
  else
    printf '===MISSING %s===\n' "$f"
  fi
done
echo "===VERSIONS==="
docker inspect netbird-management --format '{{ .Config.Image }} {{ .Image }}'
docker exec netbird-management sh -c '/go/netbird-mgmt --version 2>/dev/null || netbird-mgmt --version 2>/dev/null || true'
echo "===DATASTORE==="
volume_path="$(docker volume inspect netbird-new_netbird_management --format '{{ .Mountpoint }}')"
echo "VOLUME_PATH=$volume_path"
ls -la "$volume_path"
du -sh "$volume_path"
EOF
)"
  printf '%s\n' "$out" > "${FETCH_DIR}/live/raw-fetch.txt"
  chmod 0600 "${FETCH_DIR}/live/raw-fetch.txt"

  python3 - "$FETCH_DIR/live" <<'PYEOF'
import base64, pathlib, re, sys
dest = pathlib.Path(sys.argv[1])
raw = (dest / "raw-fetch.txt").read_text()
for name, body in re.findall(r"===FILE (\S+)===\n(.*?)\n===END \1===", raw, re.DOTALL):
    path = dest / name.lstrip(".")
    path.write_bytes(base64.b64decode(body))
    path.chmod(0o600)
    print(f"fetched: {name} -> {path.name} ({path.stat().st_size} bytes)")
for name in re.findall(r"===MISSING (\S+)===", raw):
    print(f"MISSING on old host: {name}")
PYEOF

  grep -E '^(COMPOSE_DIR|VOLUME_PATH)=' "${FETCH_DIR}/live/raw-fetch.txt" \
    > "${FETCH_DIR}/live/paths.env"
  log "Old-host paths recorded in .fetched/live/paths.env"
}

check_version_pin() {
  log "Comparing live management version against the Terraform pin ($PINNED_MGMT_VERSION)"
  local live_section
  live_section="$(sed -n '/===VERSIONS===/,/===DATASTORE===/p' "${FETCH_DIR}/live/raw-fetch.txt")"
  echo "$live_section"
  if grep -q "$PINNED_MGMT_VERSION" <<<"$live_section"; then
    echo "OK: live management matches the pinned version."
  else
    cat >&2 <<EOT
WARNING: could not confirm the live management version equals $PINNED_MGMT_VERSION.
The old stack runs :latest. NetBird schema migrations are ONE-WAY: if the live
version is NEWER than the pin, update the pins in infra/terraform/locals.tf
(management/signal/relay/dashboard images + client RPM) BEFORE Phase A apply.
Do not proceed on a mismatch.
EOT
    return 1
  fi
}

export_api_backup() {
  if [[ -z "${NETBIRD_PAT:-}" ]]; then
    echo "NETBIRD_PAT not set — skipping NetBird API export (optional but recommended)."
    return 0
  fi
  log "Exporting NetBird API objects (extra data-safety artifact)"
  install -d -m 0700 "${FETCH_DIR}/api-backup"
  local ep
  for ep in peers groups policies networks setup-keys users routes dns/nameservers; do
    curl -fsS -H "Authorization: Token ${NETBIRD_PAT}" \
      "https://${MIG_DOMAIN}/api/${ep}" \
      -o "${FETCH_DIR}/api-backup/${ep//\//-}.json" \
      && echo "exported: ${ep}" || echo "WARN: export failed for ${ep} (check PAT scope)"
  done
  chmod 0600 "${FETCH_DIR}/api-backup/"*.json
}

install -d -m 0700 "$FETCH_DIR"

case "${1:-all}" in
  attach-ssm) attach_ssm ;;
  all)
    snapshot_old_mgmt
    create_scratch_bucket
    attach_ssm
    fetch_live_config
    check_version_pin
    export_api_backup
    log "Pre-flight complete. Review .fetched/live/, then run 01-apply-parallel-stack.sh"
    ;;
  *) echo "usage: $0 [all|attach-ssm]" >&2; exit 64 ;;
esac
