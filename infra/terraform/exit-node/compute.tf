resource "aws_instance" "exit_node" {
  ami                         = local.selected_ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  associate_public_ip_address = var.associate_public_ipv4_address
  vpc_security_group_ids      = [aws_security_group.exit_node.id]
  iam_instance_profile        = aws_iam_instance_profile.exit_node.name
  key_name                    = var.key_name

  # Exit-node routes masquerade behind the instance address, but forwarding
  # must never depend on the ENI's source/destination filter.
  source_dest_check = false

  monitoring                           = var.enable_detailed_monitoring
  ebs_optimized                        = true
  disable_api_stop                     = false
  disable_api_termination              = var.enable_termination_protection
  instance_initiated_shutdown_behavior = "stop"

  user_data_base64 = base64gzip(templatefile("${path.module}/templates/exit-node-user-data.sh.tftpl", {
    aws_region                      = var.aws_region
    domain                          = var.domain
    hostname                        = local.hostname
    netbird_client_version          = local.netbird_client.version
    netbird_client_arm64_rpm_sha256 = local.netbird_client.arm64_rpm_sha256
    netbird_rpm_signing_key_sha256  = local.netbird_client.rpm_signing_key_sha256
    setup_key_secret_arn            = aws_secretsmanager_secret.setup_key.arn
  }))
  user_data_replace_on_change = true

  credit_specification {
    cpu_credits = "unlimited"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_protocol_ipv6          = "disabled"
    http_put_response_hop_limit = 1
    http_tokens                 = "required"
    instance_metadata_tags      = "disabled"
  }

  maintenance_options {
    auto_recovery = "default"
  }

  root_block_device {
    delete_on_termination = true
    encrypted             = true
    kms_key_id            = var.ebs_kms_key_arn
    volume_size           = var.root_volume_size_gib
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125

    tags = {
      Name = "${local.hostname}-root"
      Role = "exit-node"
    }
  }

  tags = {
    Name         = local.hostname
    Role         = "exit-node"
    Architecture = "arm64"
  }

  lifecycle {
    precondition {
      condition     = data.aws_ami.selected.architecture == "arm64"
      error_message = "The selected AMI must use the arm64 architecture required by t4g instances."
    }

    precondition {
      condition     = data.aws_subnet.selected.vpc_id == var.vpc_id
      error_message = "subnet_id must belong to vpc_id."
    }

    precondition {
      condition     = var.associate_public_ipv4_address || var.create_eip
      error_message = "The exit node needs internet egress: enable associate_public_ipv4_address or create_eip (or route the subnet through NAT and override this check)."
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.ssm_core,
    aws_iam_role_policy.setup_key,
  ]
}
