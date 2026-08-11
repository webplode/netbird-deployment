data "aws_partition" "current" {}

data "aws_ssm_parameter" "al2023_arm64" {
  count = var.ami_id == null ? 1 : 0
  name  = var.ami_ssm_parameter
}

locals {
  selected_ami_id = var.ami_id != null ? var.ami_id : data.aws_ssm_parameter.al2023_arm64[0].value
}

data "aws_ami" "selected" {
  owners = ["amazon"]

  filter {
    name   = "image-id"
    values = [local.selected_ami_id]
  }
}

data "aws_subnet" "selected" {
  for_each = toset(values(var.subnet_ids))
  id       = each.value
}

data "aws_eip" "selected" {
  for_each = var.eip_allocation_ids
  id       = each.value
}
