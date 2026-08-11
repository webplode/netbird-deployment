output "selected_ami" {
  description = "Resolved Amazon Linux 2023 ARM64 AMI. Pin it through ami_id after qualification if required."
  value = {
    id           = local.selected_ami_id
    architecture = data.aws_ami.selected.architecture
    name         = data.aws_ami.selected.name
  }
}

output "instances" {
  description = "New node identities and addresses. desired_eip is not associated until its cutover gate is enabled."
  value = {
    for key, instance in aws_instance.node : key => {
      instance_id         = instance.id
      availability_zone   = instance.availability_zone
      private_ip          = instance.private_ip
      temporary_public_ip = instance.public_ip
      desired_eip         = data.aws_eip.selected[key].public_ip
      eip_cutover_enabled = var.eip_association_enabled[key]
      ssm_bootstrap       = var.bootstrap_enabled[key]
    }
  }
}

output "runtime_secret_arns" {
  description = "Populate these secrets outside Terraform; no secret value is stored in state."
  value = {
    for key, secret in aws_secretsmanager_secret.runtime : key => secret.arn
  }
}

output "management_data_volume_id" {
  description = "Persistent, prevent-destroy EBS volume for management and Caddy state."
  value       = aws_ebs_volume.management_data.id
}

output "ssm_document_names" {
  description = "Bootstrap command documents used by the gated SSM associations."
  value = merge(
    { management = aws_ssm_document.management_bootstrap.name },
    { for key, document in aws_ssm_document.peer_bootstrap : key => document.name },
  )
}

output "observed_eip_holders" {
  description = "Current EIP associations observed during refresh. Record these as rollback IDs before cutover."
  value = {
    for key, eip in data.aws_eip.selected : key => {
      allocation_id = eip.id
      public_ip     = eip.public_ip
      instance_id   = eip.instance_id
    }
  }
}
