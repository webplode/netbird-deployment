locals {
  hostname = "${var.name_prefix}-${var.environment}-${var.node_name}"

  selected_ami_id = var.ami_id != null ? var.ami_id : nonsensitive(data.aws_ssm_parameter.al2023_arm64[0].value)

  # Same pinned client release as infra/terraform; update both together.
  netbird_client = {
    version                = "0.76.1"
    arm64_rpm_sha256       = "19c42fcd1566d3120bc547f631f4b41ba81f864c76ce5fdec393f3476baa9aa2"
    rpm_signing_key_sha256 = "62a19f1371ef014bd9e47fcd4b4c6d62476b7b6e22d530ad64b57c645fc11f5d"
  }
}
