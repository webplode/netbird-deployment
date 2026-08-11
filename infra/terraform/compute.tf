resource "aws_instance" "node" {
  for_each = local.nodes

  ami                         = local.selected_ami_id
  instance_type               = local.instance_type
  subnet_id                   = each.value.subnet_id
  private_ip                  = each.value.private_ip
  associate_public_ip_address = var.associate_public_ipv4_address
  vpc_security_group_ids = [
    each.value.security_group_target == "management" ? aws_security_group.management.id : aws_security_group.peers.id,
  ]
  iam_instance_profile = aws_iam_instance_profile.node[each.key].name
  key_name             = var.key_name
  source_dest_check    = each.value.source_dest_check

  monitoring                           = var.enable_detailed_monitoring
  ebs_optimized                        = true
  disable_api_stop                     = false
  disable_api_termination              = var.enable_termination_protection
  instance_initiated_shutdown_behavior = "stop"

  user_data_base64 = base64gzip(templatefile("${path.module}/templates/base-user-data.sh.tftpl", {
    hostname = each.value.hostname
  }))
  user_data_replace_on_change = true

  credit_specification {
    cpu_credits = "unlimited"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_protocol_ipv6          = "disabled"
    http_put_response_hop_limit = each.value.metadata_hop_limit
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
    volume_size           = each.value.root_volume_size_gib
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125

    tags = {
      Name = "${each.value.hostname}-root"
      Role = each.value.role
    }
  }

  tags = {
    Name         = each.value.hostname
    Role         = each.value.role
    Architecture = "arm64"
  }

  lifecycle {
    precondition {
      condition     = data.aws_ami.selected.architecture == "arm64"
      error_message = "The selected AMI must use the arm64 architecture required by t4g.small."
    }

    precondition {
      condition     = data.aws_subnet.selected[each.value.subnet_id].vpc_id == var.vpc_id
      error_message = "Every selected subnet must belong to vpc_id."
    }

    precondition {
      condition = (
        each.key != "peer_2" ||
        data.aws_subnet.selected[var.subnet_ids.peer_1].availability_zone != data.aws_subnet.selected[var.subnet_ids.peer_2].availability_zone
      )
      error_message = "peer_1 and peer_2 must occupy different Availability Zones."
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.ssm_core,
    aws_iam_role_policy.runtime_secret,
  ]
}

resource "aws_ebs_volume" "management_data" {
  availability_zone = data.aws_subnet.selected[var.subnet_ids.management].availability_zone
  encrypted         = true
  kms_key_id        = var.ebs_kms_key_arn
  size              = var.management_data_volume_size_gib
  snapshot_id       = var.management_data_snapshot_id
  type              = "gp3"
  iops              = 3000
  throughput        = 125

  tags = {
    Name = "${local.nodes.management.hostname}-data"
    Role = "management-data"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "management_data" {
  device_name                    = "/dev/sdf"
  instance_id                    = aws_instance.node["management"].id
  volume_id                      = aws_ebs_volume.management_data.id
  force_detach                   = false
  stop_instance_before_detaching = true
}

resource "aws_eip_association" "cutover" {
  for_each = local.eip_cutovers

  allocation_id       = var.eip_allocation_ids[each.key]
  instance_id         = aws_instance.node[each.key].id
  allow_reassociation = true

  depends_on = [
    aws_ssm_association.management_bootstrap,
    aws_ssm_association.peer_bootstrap,
  ]

  lifecycle {
    precondition {
      condition     = var.bootstrap_enabled[each.key]
      error_message = "Complete the node's successful SSM bootstrap before enabling its EIP cutover."
    }

    precondition {
      condition = (
        var.eip_cutover_confirmation == "REASSOCIATE_SLEEK_NETBIRD_EIPS" ||
        data.aws_eip.selected[each.key].instance_id == aws_instance.node[each.key].id
      )
      error_message = "Set eip_cutover_confirmation to REASSOCIATE_SLEEK_NETBIRD_EIPS for an intentional production cutover."
    }

    precondition {
      condition = (
        try(var.eip_rollback_instance_ids[each.key], null) != null ||
        data.aws_eip.selected[each.key].instance_id == aws_instance.node[each.key].id
      )
      error_message = "Record the current EIP holder in eip_rollback_instance_ids before enabling cutover."
    }

    precondition {
      condition = (
        data.aws_eip.selected[each.key].instance_id == try(var.eip_rollback_instance_ids[each.key], null) ||
        data.aws_eip.selected[each.key].instance_id == aws_instance.node[each.key].id
      )
      error_message = "The EIP holder changed after rollback metadata was recorded; refresh and review before cutover."
    }
  }
}
