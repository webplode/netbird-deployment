data "aws_partition" "current" {}

data "aws_ssm_parameter" "al2023_arm64" {
  count = var.ami_id == null ? 1 : 0

  name = var.ami_ssm_parameter
}

data "aws_ami" "selected" {
  owners = ["amazon"]

  filter {
    name   = "image-id"
    values = [local.selected_ami_id]
  }
}

data "aws_subnet" "selected" {
  id = var.subnet_id
}
