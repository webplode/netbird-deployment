# Terraform owns only the secret container. The raw NetBird setup key is
# populated outside Terraform (aws secretsmanager put-secret-value) so it never
# enters plans, state, or user data. The instance reads it at boot.
resource "aws_secretsmanager_secret" "setup_key" {
  name                    = "${var.name_prefix}/${var.environment}/${var.node_name}/setup-key"
  description             = "Raw NetBird setup key for ${local.hostname}; Terraform owns metadata, not the value."
  kms_key_id              = var.secrets_kms_key_arn
  recovery_window_in_days = var.secret_recovery_window_days

  tags = {
    Name = "${local.hostname}-setup-key"
    Role = "exit-node"
  }
}
