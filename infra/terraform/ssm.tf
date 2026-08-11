resource "aws_ssm_document" "management_bootstrap" {
  name            = "${local.nodes.management.hostname}-bootstrap"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install and converge the Sleek NetBird management Compose stack without placing secrets in Terraform state."
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "bootstrapManagement"
      inputs = {
        timeoutSeconds = "3600"
        runCommand = [templatefile("${path.module}/templates/management-bootstrap.sh.tftpl", {
          caddyfile_b64          = base64encode(local.caddy_config)
          compose_b64            = base64encode(local.compose_config)
          compose_sha256         = local.compose_aarch64_sha256
          compose_version        = local.compose_version
          data_volume_id         = aws_ebs_volume.management_data.id
          domain                 = var.domain
          management_public_ipv4 = data.aws_eip.selected["management"].public_ip
          runtime_secret_arn     = aws_secretsmanager_secret.runtime["management"].arn
          turn_realm             = var.turn_realm
        })]
      }
    }]
  })

  tags = {
    Name = "${local.nodes.management.hostname}-bootstrap"
    Role = "management"
  }
}

resource "aws_ssm_document" "peer_bootstrap" {
  for_each = local.peer_nodes

  name            = "${each.value.hostname}-bootstrap"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install, enroll, and verify the ${each.value.hostname} NetBird routing peer."
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "bootstrapRoutingPeer"
      inputs = {
        timeoutSeconds = "1800"
        runCommand = [templatefile("${path.module}/templates/peer-bootstrap.sh.tftpl", {
          domain                          = var.domain
          netbird_client_arm64_rpm_sha256 = local.netbird_client.arm64_rpm_sha256
          netbird_client_version          = local.netbird_client.version
          netbird_rpm_signing_key_sha256  = local.netbird_client.rpm_signing_key_sha256
          peer_hostname                   = each.value.hostname
          runtime_secret_arn              = aws_secretsmanager_secret.runtime[each.key].arn
        })]
      }
    }]
  })

  tags = {
    Name = "${each.value.hostname}-bootstrap"
    Role = "routing-peer"
  }
}

resource "aws_ssm_association" "management_bootstrap" {
  count = var.bootstrap_enabled.management ? 1 : 0

  name                             = aws_ssm_document.management_bootstrap.name
  association_name                 = "${local.nodes.management.hostname}-bootstrap"
  document_version                 = aws_ssm_document.management_bootstrap.latest_version
  compliance_severity              = "HIGH"
  wait_for_success_timeout_seconds = 3600

  targets {
    key    = "InstanceIds"
    values = [aws_instance.node["management"].id]
  }

  depends_on = [aws_volume_attachment.management_data]
}

resource "aws_ssm_association" "peer_bootstrap" {
  for_each = local.enabled_peer_bootstraps

  name                             = aws_ssm_document.peer_bootstrap[each.key].name
  association_name                 = "${local.nodes[each.key].hostname}-bootstrap"
  document_version                 = aws_ssm_document.peer_bootstrap[each.key].latest_version
  compliance_severity              = "HIGH"
  wait_for_success_timeout_seconds = 1800

  targets {
    key    = "InstanceIds"
    values = [aws_instance.node[each.key].id]
  }

  lifecycle {
    precondition {
      condition = (
        var.bootstrap_enabled.management &&
        var.eip_association_enabled.management &&
        data.aws_eip.selected["management"].instance_id == aws_instance.node["management"].id
      )
      error_message = "Bootstrap peers only after the management workload is enabled and its EIP is observed on the new management instance."
    }
  }
}
