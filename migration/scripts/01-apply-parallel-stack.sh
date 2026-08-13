#!/usr/bin/env bash
# Phase A step 1 — create the parallel ARM64 stack. No EIP moves, no bootstrap,
# no impact on the running production stack. Safe to re-run.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmds aws jq terraform python3
require_write_profile

log "Installing migration tfvars/backend into $TF_DIR"
if [[ -f "${TF_DIR}/terraform.tfvars" ]]; then
  echo "terraform.tfvars already exists — leaving it in place (gates may already be flipped)."
else
  install -m 0644 "${MIG_ROOT}/tfvars/terraform.tfvars.migration-base" "${TF_DIR}/terraform.tfvars"
fi
install -m 0644 "${MIG_ROOT}/tfvars/backend.hcl.migration" "${TF_DIR}/backend.hcl"

log "terraform init / fmt / validate"
tf init -backend-config=backend.hcl -input=false -reconfigure
tf fmt -check -recursive
tf validate

log "Planning first apply"
tf plan -input=false -out=first-apply.tfplan

plan_readback first-apply.tfplan "$(count_creates aws_instance)" 3 "exactly three new instances"
plan_readback first-apply.tfplan "$(count_creates aws_ssm_association)" 0 "zero SSM associations"
plan_readback first-apply.tfplan "$(count_creates aws_eip_association)" 0 "zero EIP associations"
plan_readback first-apply.tfplan \
  '[.resource_changes[]? | select(.type == "aws_instance") | .change.after.instance_type] | unique' \
  '["t4g.small"]' "all instances t4g.small"
plan_readback first-apply.tfplan \
  '[.resource_changes[]? | select(.change.actions | index("delete"))] | length' \
  0 "nothing destroyed"

tf show first-apply.tfplan | tail -20
confirm_phrase "Plan readbacks passed. Apply the parallel stack?" "APPLY"
tf apply -input=false first-apply.tfplan

log "New stack created. Outputs:"
tf_output_json instances | jq .
tf_output_json runtime_secret_arns | jq .
tf_output_json observed_eip_holders | jq .

log "Next: 02-populate-secrets.sh"
