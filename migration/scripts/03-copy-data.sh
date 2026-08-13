#!/usr/bin/env bash
# Data copy old management -> new management via S3 presigned URLs.
#
#   ./03-copy-data.sh rehearsal   # old stack stays up; hot copy for validation
#   ./03-copy-data.sh final       # old stack must already be DOWN (called by 05)
#
# Design: the old host uploads with curl -T against a presigned PUT URL (no AWS
# credentials needed on it); the new host downloads with curl against a
# presigned GET URL (its instance role is never widened). SHA-256 is computed
# on the old host and re-verified on the new host before anything is replaced.
# The new host keeps one previous datastore generation in /srv/netbird/previous.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmds aws jq uv terraform
require_write_profile

MODE="${1:-}"
[[ "$MODE" == "rehearsal" || "$MODE" == "final" ]] || { echo "usage: $0 rehearsal|final" >&2; exit 64; }

# Old-host paths recorded by 00-preflight.sh; needed in final mode because the
# caddy container is already gone and cannot be inspected for its bind mount.
if [[ -f "${FETCH_DIR}/live/paths.env" ]]; then
  # shellcheck disable=SC1091
  source "${FETCH_DIR}/live/paths.env"
  export OLD_COMPOSE_DIR="${COMPOSE_DIR:-}"
fi
if [[ "$MODE" == "final" && -z "${OLD_COMPOSE_DIR:-}" ]]; then
  echo "FATAL: OLD_COMPOSE_DIR unknown (run 00-preflight.sh fetch first)." >&2
  exit 1
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PREFIX="copy-${MODE}-${STAMP}"
NEW_MGMT_ID="$(new_instance_id management)"
[[ "$NEW_MGMT_ID" == i-* ]] || { echo "FATAL: new management instance not found in terraform output." >&2; exit 1; }

presign() { # presign put|get <key>
  uv run --quiet --with boto3 python "${MIG_ROOT}/scripts/presign.py" "$1" "$MIG_BUCKET" "$2" \
    --expires 3600 --profile "$MIGRATION_AWS_PROFILE" --region "$MIG_REGION"
}

if [[ "$MODE" == "final" ]]; then
  log "FINAL mode: asserting the old stack is down"
  running="$(run_on_old_mgmt 120 <<'EOF'
docker ps --filter label=com.docker.compose.project=netbird-new --format '{{.Names}}' | wc -l
EOF
)"
  if [[ "${running//[[:space:]]/}" != "0" ]]; then
    echo "FATAL: old netbird-new containers still running. Stop the old stack first (05 does this)." >&2
    exit 1
  fi
fi

log "1/4 Uploading from the old host (mode: $MODE)"
put_data_url="$(presign put "${PREFIX}/mgmt-data.tar.gz")"
put_caddy_url="$(presign put "${PREFIX}/caddy-data.tar.gz")"
put_manifest_url="$(presign put "${PREFIX}/manifest.txt")"

run_on_old_mgmt 1800 <<EOF
set -Eeuo pipefail
umask 077
volume_path="\$(docker volume inspect ${OLD_MGMT_VOLUME} --format '{{ .Mountpoint }}')"
compose_dir="\$(docker inspect netbird-caddy --format '{{ range .Mounts }}{{ if eq .Destination "/etc/caddy/Caddyfile" }}{{ .Source }}{{ end }}{{ end }}' 2>/dev/null | xargs dirname || true)"
if [[ -z "\$compose_dir" ]]; then
  # final mode: containers are gone; use the path recorded at pre-flight
  compose_dir="${OLD_COMPOSE_DIR:-/root/netbird-new}"
fi
work="\$(mktemp -d /var/tmp/nb-mig.XXXXXX)"
trap 'rm -rf "\$work"' EXIT
tar -C "\$volume_path" -czf "\$work/mgmt-data.tar.gz" .
tar -C "\$compose_dir/caddy_data" -czf "\$work/caddy-data.tar.gz" .
( cd "\$work" && sha256sum mgmt-data.tar.gz caddy-data.tar.gz > manifest.txt )
cat "\$work/manifest.txt"
for pair in "mgmt-data.tar.gz|${put_data_url}" "caddy-data.tar.gz|${put_caddy_url}" "manifest.txt|${put_manifest_url}"; do
  f="\${pair%%|*}"; u="\${pair#*|}"
  code="\$(curl -sS -T "\$work/\$f" -o /dev/null -w '%{http_code}' "\$u")"
  [[ "\$code" == "200" ]] || { echo "FATAL: PUT \$f returned HTTP \$code"; exit 1; }
done
echo UPLOAD_OK
EOF

log "2/4 Verifying the manifest landed"
awsw s3api head-object --bucket "$MIG_BUCKET" --key "${PREFIX}/manifest.txt" >/dev/null
awsw s3 cp "s3://${MIG_BUCKET}/${PREFIX}/manifest.txt" "${FETCH_DIR}/${PREFIX}-manifest.txt" --quiet
cat "${FETCH_DIR}/${PREFIX}-manifest.txt"

log "3/4 Restoring on the new management host"
get_data_url="$(presign get "${PREFIX}/mgmt-data.tar.gz")"
get_caddy_url="$(presign get "${PREFIX}/caddy-data.tar.gz")"
get_manifest_url="$(presign get "${PREFIX}/manifest.txt")"

ssm_run "$NEW_MGMT_ID" 1800 <<EOF
set -Eeuo pipefail
umask 077
mountpoint -q /srv/netbird || { echo "FATAL: /srv/netbird not mounted (management bootstrap not done)"; exit 1; }
work="\$(mktemp -d /var/tmp/nb-mig.XXXXXX)"
trap 'rm -rf "\$work"' EXIT
cd "\$work"
curl -fsS -o mgmt-data.tar.gz  '${get_data_url}'
curl -fsS -o caddy-data.tar.gz '${get_caddy_url}'
curl -fsS -o manifest.txt      '${get_manifest_url}'
sha256sum --check --status manifest.txt || { echo "FATAL: checksum mismatch after download"; exit 1; }
echo "checksums verified on new host"

cd /opt/sleek-netbird
docker compose --env-file .env down

rm -rf /srv/netbird/previous
mkdir -p /srv/netbird/previous
[ -d /srv/netbird/management ] && mv /srv/netbird/management /srv/netbird/previous/management
[ -d /srv/netbird/caddy-data ] && mv /srv/netbird/caddy-data /srv/netbird/previous/caddy-data
install -d -o root -g root -m 0700 /srv/netbird/management /srv/netbird/caddy-data
tar -C /srv/netbird/management -xzf "\$work/mgmt-data.tar.gz"
tar -C /srv/netbird/caddy-data -xzf "\$work/caddy-data.tar.gz"
chown -R root:root /srv/netbird/management /srv/netbird/caddy-data
ls -la /srv/netbird/management | head

docker compose --env-file .env up -d
expected="\$(docker compose --env-file .env config --services | wc -l | tr -d ' ')"
for _ in \$(seq 1 60); do
  running="\$(docker compose --env-file .env ps --services --filter status=running | wc -l | tr -d ' ')"
  [[ "\$running" == "\$expected" ]] && break
  sleep 5
done
sleep 10
running="\$(docker compose --env-file .env ps --services --filter status=running | wc -l | tr -d ' ')"
[[ "\$running" == "\$expected" ]] || { docker compose --env-file .env ps; echo "FATAL: only \$running/\$expected services running after restore"; exit 1; }
echo "RESTORE_OK: \$running/\$expected services running with restored data"
EOF

log "4/4 HTTP verification against the new host (DNS untouched)"
TEMP_IP="$(new_temp_ip management)"
http_expect 401 --resolve "${MIG_DOMAIN}:443:${TEMP_IP}" "https://${MIG_DOMAIN}/healthz"
http_expect 308 -H "Host: attacker.invalid" "http://${TEMP_IP}/"

log "Cleaning scratch objects for this run"
awsw s3 rm "s3://${MIG_BUCKET}/${PREFIX}/" --recursive --quiet

log "Copy ($MODE) complete and verified."
