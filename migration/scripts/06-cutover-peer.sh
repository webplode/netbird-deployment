#!/usr/bin/env bash
# Phase C — migrate one routing peer at a time. Run the day after the
# management window, once for peer_1 and (after full acceptance) for peer_2.
#
#   ./06-cutover-peer.sh peer_1
#   ./06-cutover-peer.sh peer_2

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmds aws jq terraform python3
require_write_profile

PEER="${1:-}"
case "$PEER" in
  peer_1) OLD_ID="$OLD_PEER1_ID"; ALLOC="$EIP_PEER1_ALLOC"; EIP_IP="$EIP_PEER1_IP" ;;
  peer_2) OLD_ID="$OLD_PEER2_ID"; ALLOC="$EIP_PEER2_ALLOC"; EIP_IP="$EIP_PEER2_IP" ;;
  *) echo "usage: $0 peer_1|peer_2" >&2; exit 64 ;;
esac

log "Pre-checks: management must already be cut over"
verify_eip_holder "$EIP_MGMT_ALLOC" "$(new_instance_id management)"

log "Enabling ${PEER} bootstrap gate"
set_tfvar "bootstrap_enabled.${PEER}" true
tf plan -input=false -out="bootstrap-${PEER}.tfplan"
plan_readback "bootstrap-${PEER}.tfplan" "$(count_creates aws_ssm_association)" 1 "exactly one SSM association"
plan_readback "bootstrap-${PEER}.tfplan" "$(count_creates aws_eip_association)" 0 "zero EIP associations"
plan_readback "bootstrap-${PEER}.tfplan" \
  '[.resource_changes[]? | select(.change.actions | index("delete"))] | length' \
  0 "nothing destroyed"
confirm_phrase "Apply ${PEER} bootstrap (enrolls a NEW peer with its setup key)?" "APPLY"
tf apply -input=false "bootstrap-${PEER}.tfplan"

log "Verifying the new peer"
NEW_ID="$(new_instance_id "$PEER")"
ssm_run "$NEW_ID" 300 <<'EOF'
set -e
rpm -q netbird
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
netbird status --check live
netbird status --check ready
netbird status --check startup
EOF

cat <<EOT

MANUAL DASHBOARD CHECK before the EIP move:
  1. The new peer (sleek-netbird-production-${PEER//_/-}) appears connected.
  2. It is in the intended routing group, so group-defined routes now have it
     as an additional (HA) routing peer alongside the old exit node.
  3. Policies grant it nothing broader than the old peer had.
EOT
confirm_phrase "Dashboard checks done — move EIP ${EIP_IP} from ${OLD_ID} to the new ${PEER}?" "MOVE_PEER_EIP"

verify_eip_holder "$ALLOC" "$OLD_ID"
set_tfvar "eip_rollback_instance_ids.${PEER}" "\"${OLD_ID}\""
set_tfvar "eip_association_enabled.${PEER}" true
set_tfvar eip_cutover_confirmation "\"REASSOCIATE_SLEEK_NETBIRD_EIPS\""

tf plan -input=false -out="cutover-${PEER}.tfplan"
plan_readback "cutover-${PEER}.tfplan" "$(count_creates aws_eip_association)" 1 "exactly one EIP association"
plan_readback "cutover-${PEER}.tfplan" \
  '[.resource_changes[]? | select(.change.actions | index("delete"))] | length' \
  0 "nothing destroyed"
tf apply -input=false "cutover-${PEER}.tfplan"

log "Post-cutover verification"
verify_eip_holder "$ALLOC" "$NEW_ID"
sleep 10
ssm_run "$NEW_ID" 180 <<EOF
set -e
netbird status --check live
egress_ip="\$(curl -fsS --max-time 15 https://checkip.amazonaws.com | tr -d '\n')"
echo "egress ip: \$egress_ip"
[[ "\$egress_ip" == "${EIP_IP}" ]] || { echo "FATAL: egress IP is not ${EIP_IP}"; exit 1; }
EOF

set_tfvar eip_cutover_confirmation "\"\""

cat <<EOT

${PEER} cut over. The egress IP ${EIP_IP} is preserved, so any external
allowlist (databases, SaaS) keeps working unchanged. Now:
  - verify a real client route through this peer (database reachability, failover);
  - remove the OLD peer (${OLD_ID}) from the NetBird dashboard once satisfied;
  - keep the old instance stopped (not terminated) for the rollback window.
EOT
