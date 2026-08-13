#!/usr/bin/env bash
# Emergency rollback of one node's EIP cutover.
#
#   ./90-rollback.sh management | peer_1 | peer_2
#
# management: stops the NEW writer first (never two writers), returns the EIP
# to the old instance, restarts the old stack, and removes the association from
# Terraform state so a later apply does not steal the EIP back.
# peers: returns the EIP; the old exit node is still enrolled and resumes.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmds aws jq terraform python3
require_write_profile

NODE="${1:-}"
case "$NODE" in
  management) OLD_ID="$OLD_MGMT_ID"; ALLOC="$EIP_MGMT_ALLOC"; EIP_IP="$EIP_MGMT_IP" ;;
  peer_1)     OLD_ID="$OLD_PEER1_ID"; ALLOC="$EIP_PEER1_ALLOC"; EIP_IP="$EIP_PEER1_IP" ;;
  peer_2)     OLD_ID="$OLD_PEER2_ID"; ALLOC="$EIP_PEER2_ALLOC"; EIP_IP="$EIP_PEER2_IP" ;;
  *) echo "usage: $0 management|peer_1|peer_2" >&2; exit 64 ;;
esac

NODE_UPPER="$(printf '%s' "$NODE" | tr '[:lower:]' '[:upper:]')"
confirm_phrase "ROLLBACK ${NODE}: return EIP ${EIP_IP} to ${OLD_ID}?" "ROLLBACK_${NODE_UPPER}"

if [[ "$NODE" == "management" ]]; then
  log "Stopping the NEW management writer first"
  NEW_MGMT_ID="$(new_instance_id management)"
  ssm_run "$NEW_MGMT_ID" 300 <<'EOF'
cd /opt/sleek-netbird && docker compose --env-file .env down && echo NEW_WRITER_DOWN
EOF
fi

log "Re-associating ${EIP_IP} to ${OLD_ID}"
awsw ec2 associate-address --allocation-id "$ALLOC" --instance-id "$OLD_ID" \
  --allow-reassociation >/dev/null
verify_eip_holder "$ALLOC" "$OLD_ID"

if [[ "$NODE" == "management" ]]; then
  log "Starting the OLD stack"
  run_on_old_mgmt 600 <<'EOF'
set -Eeuo pipefail
compose_dir="${OLD_COMPOSE_DIR:-}"
if [[ -z "$compose_dir" ]]; then
  for d in /home/iznogoud/netbird-new /root/netbird-new /opt/netbird-new; do
    [[ -f "$d/docker-compose.yml" ]] && compose_dir="$d" && break
  done
fi
[[ -n "$compose_dir" ]] || { echo "FATAL: compose dir not found; start manually"; exit 1; }
cd "$compose_dir"
docker compose up -d
sleep 20
docker compose ps
echo OLD_STACK_UP
EOF
  sleep 10
  http_expect 401 "https://${MIG_DOMAIN}/healthz"
  cat <<'EOT'
Old control plane restored. IMPORTANT: any change made while the NEW writer was
live (new peers, revoked keys) exists only in the new datastore — reconcile
manually before any further attempt.
EOT
fi

log "Reconciling Terraform (remove the association from state, disable the gate)"
tf state rm "aws_eip_association.cutover[\"${NODE}\"]" || echo "state address absent — continuing"
set_tfvar "eip_association_enabled.${NODE}" false
set_tfvar eip_cutover_confirmation "\"\""
tf plan -input=false -out=rollback-verify.tfplan
plan_readback rollback-verify.tfplan \
  '[.resource_changes[]? | select(.change.actions != ["no-op"])] | length' \
  0 "no pending changes after rollback"

log "Rollback of ${NODE} complete and Terraform is clean."
