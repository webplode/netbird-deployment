resource "aws_secretsmanager_secret" "runtime" {
  for_each = local.nodes

  name                    = "${var.name_prefix}/${var.environment}/${replace(each.key, "_", "-")}/runtime"
  description             = "Runtime-only secret for ${local.nodes[each.key].hostname}; Terraform owns metadata, not secret values."
  kms_key_id              = var.secrets_kms_key_arn
  recovery_window_in_days = var.secret_recovery_window_days

  tags = {
    Name = "${local.nodes[each.key].hostname}-runtime"
    Role = each.value.role
  }
}
