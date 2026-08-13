#!/usr/bin/env bash
# PHASE B — the downtime window. Run only inside the approved maintenance
# window with the operator present. Sequence:
#
#   gate 1 (human) -> stop old stack -> final cold copy + restore + verify
#   gate 2 (human) -> EIP cutover via Terraform -> post-verification
#
# Rollback before gate 2 = start the old stack again (EIP never moved).
# Rollback after gate 2  = 90-rollback.sh management.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmds aws jq terraform uv python3
require_write_profile

NEW_MGMT_ID="$(new_instance_id management)"

log "Pre-window checks"
# Fresh pre-window snapshot of the old root volume must exist and be completed.
snap_id="$(cat "${FETCH_DIR}/mgmt-root-snapshot-id.txt" 2>/dev/null || true)"
if [[ -n "$snap_id" ]]; then
  state="$(awsw ec2 describe-snapshots --snapshot-ids "$snap_id" --query 'Snapshots[0].State' --output text)"
  echo "pre-migration snapshot $snap_id: $state"
  [[ "$state" == "completed" ]] || { echo "FATAL: snapshot not completed." >&2; exit 1; }
else
  echo "FATAL: no snapshot recorded — run 00-preflight.sh first." >&2; exit 1
fi
verify_eip_holder "$EIP_MGMT_ALLOC" "$OLD_MGMT_ID"
ssm_run "$NEW_MGMT_ID" 120 <<'EOF' >/dev/null
cd /opt/sleek-netbird && docker compose --env-file .env ps --services --filter status=running | grep -q management
EOF
echo "new management stack is up (rehearsal state); old stack still owns the EIP."

confirm_phrase "GATE 1 — begin downtime: stop the OLD production stack now?" "STOP_OLD_STACK"

log "Stopping the old stack (it must never start again after this point)"
run_on_old_mgmt 300 <<'EOF'
set -Eeuo pipefail
compose_dir="$(docker inspect netbird-caddy --format '{{ range .Mounts }}{{ if eq .Destination "/etc/caddy/Caddyfile" }}{{ .Source }}{{ end }}{{ end }}' | xargs dirname)"
cd "$compose_dir"
docker compose down
docker ps --format '{{.Names}}'
echo OLD_STACK_DOWN
EOF

log "Final cold copy + restore"
"${MIG_ROOT}/scripts/03-copy-data.sh" final

log "Recording rollback holder and enabling the management EIP gate"
set_tfvar eip_rollback_instance_ids.management "\"${OLD_MGMT_ID}\""
set_tfvar eip_association_enabled.management true
set_tfvar eip_cutover_confirmation "\"REASSOCIATE_SLEEK_NETBIRD_EIPS\""

tf plan -input=false -out=cutover-mgmt.tfplan
plan_readback cutover-mgmt.tfplan "$(count_creates aws_eip_association)" 1 "exactly one EIP association"
plan_readback cutover-mgmt.tfplan \
  '[.resource_changes[]? | select(.change.actions | index("delete"))] | length' \
  0 "nothing destroyed"
verify_eip_holder "$EIP_MGMT_ALLOC" "$OLD_MGMT_ID"

confirm_phrase "GATE 2 — move EIP ${EIP_MGMT_IP} from ${OLD_MGMT_ID} to ${NEW_MGMT_ID}?" "MOVE_MGMT_EIP"
tf apply -input=false cutover-mgmt.tfplan

log "Post-cutover verification (through real DNS)"
sleep 15
http_expect 308 "http://${MIG_DOMAIN}/"
http_expect 401 "https://${MIG_DOMAIN}/healthz"
http_expect 308 -H "Host: attacker.invalid" "http://${EIP_MGMT_IP}/"
verify_eip_holder "$EIP_MGMT_ALLOC" "$NEW_MGMT_ID"

log "Clearing the cutover confirmation phrase"
set_tfvar eip_cutover_confirmation "\"\""

cat <<EOT

WINDOW COMPLETE.
  - Clients reconnect automatically to ${MIG_DOMAIN} (record data preserved).
  - Old exit nodes reconnect to the new control plane and keep routing.
  - Verify the authenticated health check manually (do not paste the token in logs).
  - Confirm in the dashboard: peers reconnecting, routes healthy.
  - The OLD stack on ${OLD_MGMT_ID} must never be started again.
Next (daytime): 06-cutover-peer.sh peer_1, then peer_2.
EOT
