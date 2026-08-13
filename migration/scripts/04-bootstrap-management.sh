#!/usr/bin/env bash
# Phase A step 3 — bootstrap the NEW management stack (7 pinned services) on an
# empty datastore. Production keeps running on the old host; DNS and EIP are
# untouched. After this, run 03-copy-data.sh rehearsal to prove the restore
# procedure end-to-end.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmds aws jq terraform python3
require_write_profile

log "Enabling management bootstrap gate"
set_tfvar bootstrap_enabled.management true

log "Planning (must add exactly one SSM association, nothing else disruptive)"
tf plan -input=false -out=bootstrap-mgmt.tfplan
plan_readback bootstrap-mgmt.tfplan "$(count_creates aws_ssm_association)" 1 "exactly one SSM association"
plan_readback bootstrap-mgmt.tfplan "$(count_creates aws_eip_association)" 0 "zero EIP associations"
plan_readback bootstrap-mgmt.tfplan \
  '[.resource_changes[]? | select(.change.actions | index("delete"))] | length' \
  0 "nothing destroyed"

confirm_phrase "Apply management bootstrap (the association waits for in-instance success, up to 60 min)?" "APPLY"
tf apply -input=false bootstrap-mgmt.tfplan

log "Verifying"
NEW_MGMT_ID="$(new_instance_id management)"
ssm_run "$NEW_MGMT_ID" 300 <<'EOF'
set -e
uname -m
free -h | head -2
swapon --show
cd /opt/sleek-netbird
docker compose --env-file .env ps
EOF

TEMP_IP="$(new_temp_ip management)"
http_expect 401 --resolve "${MIG_DOMAIN}:443:${TEMP_IP}" "https://${MIG_DOMAIN}/healthz"
http_expect 308 -H "Host: attacker.invalid" "http://${TEMP_IP}/"
http_expect 308 --resolve "${MIG_DOMAIN}:80:${TEMP_IP}" "http://${MIG_DOMAIN}/"

log "Management bootstrap verified (empty datastore). Next: 03-copy-data.sh rehearsal"
