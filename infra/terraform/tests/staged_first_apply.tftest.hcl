mock_provider "aws" {
  override_during = plan

  override_data {
    target = data.aws_partition.current
    values = {
      partition = "aws"
    }
  }

  override_data {
    target = data.aws_iam_policy_document.ec2_assume_role
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  override_data {
    target = data.aws_iam_policy_document.runtime_secret["management"]
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  override_data {
    target = data.aws_iam_policy_document.runtime_secret["peer_1"]
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  override_data {
    target = data.aws_iam_policy_document.runtime_secret["peer_2"]
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  override_data {
    target = data.aws_ami.selected
    values = {
      architecture = "arm64"
      name         = "al2023-ami-test-arm64"
    }
  }

  override_data {
    target = data.aws_subnet.selected["subnet-0123456789abcdef0"]
    values = {
      availability_zone = "ap-southeast-1a"
      vpc_id            = "vpc-0123456789abcdef0"
    }
  }

  override_data {
    target = data.aws_subnet.selected["subnet-0fedcba9876543210"]
    values = {
      availability_zone = "ap-southeast-1b"
      vpc_id            = "vpc-0123456789abcdef0"
    }
  }

  override_data {
    target = data.aws_eip.selected["management"]
    values = {
      instance_id = "i-aaaaaaaaaaaaaaaaa"
      public_ip   = "192.0.2.10"
    }
  }

  override_data {
    target = data.aws_eip.selected["peer_1"]
    values = {
      instance_id = "i-bbbbbbbbbbbbbbbbb"
      public_ip   = "192.0.2.11"
    }
  }

  override_data {
    target = data.aws_eip.selected["peer_2"]
    values = {
      instance_id = "i-ccccccccccccccccc"
      public_ip   = "192.0.2.12"
    }
  }

  override_resource {
    target = aws_instance.node["management"]
    values = {
      id = "i-11111111111111111"
    }
  }

  override_resource {
    target = aws_instance.node["peer_1"]
    values = {
      id = "i-22222222222222222"
    }
  }

  override_resource {
    target = aws_instance.node["peer_2"]
    values = {
      id = "i-33333333333333333"
    }
  }
}

variables {
  ami_id = "ami-0123456789abcdef0"
  vpc_id = "vpc-0123456789abcdef0"

  subnet_ids = {
    management = "subnet-0123456789abcdef0"
    peer_1     = "subnet-0123456789abcdef0"
    peer_2     = "subnet-0fedcba9876543210"
  }

  eip_allocation_ids = {
    management = "eipalloc-0123456789abcdef0"
    peer_1     = "eipalloc-11111111111111111"
    peer_2     = "eipalloc-22222222222222222"
  }
}

run "first_apply_is_staged" {
  command = plan

  assert {
    condition     = length(aws_instance.node) == 3
    error_message = "The topology must contain exactly three EC2 instances."
  }

  assert {
    condition = alltrue([
      for node in aws_instance.node : node.instance_type == "t4g.small"
    ])
    error_message = "Every node must use the user-mandated t4g.small instance type."
  }

  assert {
    condition     = length(aws_eip_association.cutover) == 0
    error_message = "A default first apply must not reassociate any production EIP."
  }

  assert {
    condition = (
      length(aws_ssm_association.management_bootstrap) == 0 &&
      length(aws_ssm_association.peer_bootstrap) == 0
    )
    error_message = "A default first apply must not start or enroll any workload."
  }

  assert {
    condition = (
      aws_instance.node["management"].source_dest_check &&
      !aws_instance.node["peer_1"].source_dest_check &&
      !aws_instance.node["peer_2"].source_dest_check
    )
    error_message = "Source/destination checks must be disabled only on routing peers."
  }

  assert {
    condition = alltrue([
      for node in aws_instance.node : node.metadata_options[0].http_tokens == "required"
    ])
    error_message = "IMDSv2 must be required on every instance."
  }

  assert {
    condition = alltrue([
      for node in aws_instance.node : node.root_block_device[0].encrypted
    ])
    error_message = "Every root volume must remain encrypted."
  }
}

run "unconfirmed_eip_cutover_is_rejected" {
  command = plan

  variables {
    bootstrap_enabled = {
      management = true
      peer_1     = false
      peer_2     = false
    }

    eip_association_enabled = {
      management = true
      peer_1     = false
      peer_2     = false
    }

    eip_rollback_instance_ids = {
      management = "i-aaaaaaaaaaaaaaaaa"
    }
  }

  expect_failures = [aws_eip_association.cutover["management"]]
}

run "confirmed_eip_cutover_is_admitted" {
  command = plan

  variables {
    bootstrap_enabled = {
      management = true
      peer_1     = false
      peer_2     = false
    }

    eip_association_enabled = {
      management = true
      peer_1     = false
      peer_2     = false
    }

    eip_rollback_instance_ids = {
      management = "i-aaaaaaaaaaaaaaaaa"
    }

    eip_cutover_confirmation = "REASSOCIATE_SLEEK_NETBIRD_EIPS"
  }

  assert {
    condition     = length(aws_eip_association.cutover) == 1
    error_message = "A confirmed one-node cutover must admit exactly one EIP association."
  }
}

run "converged_cutover_needs_no_confirmation" {
  command = plan

  override_data {
    target = data.aws_eip.selected["management"]
    values = {
      instance_id = "i-11111111111111111"
      public_ip   = "192.0.2.10"
    }
  }

  variables {
    bootstrap_enabled = {
      management = true
      peer_1     = false
      peer_2     = false
    }

    eip_association_enabled = {
      management = true
      peer_1     = false
      peer_2     = false
    }

    eip_rollback_instance_ids = {
      management = "i-aaaaaaaaaaaaaaaaa"
    }
  }

  assert {
    condition     = length(aws_eip_association.cutover) == 1
    error_message = "An already-converged EIP association must remain manageable after clearing confirmation."
  }
}

run "peer_bootstrap_before_management_cutover_is_rejected" {
  command = plan

  variables {
    bootstrap_enabled = {
      management = true
      peer_1     = true
      peer_2     = false
    }

    eip_association_enabled = {
      management = true
      peer_1     = false
      peer_2     = false
    }

    eip_rollback_instance_ids = {
      management = "i-aaaaaaaaaaaaaaaaa"
    }

    eip_cutover_confirmation = "REASSOCIATE_SLEEK_NETBIRD_EIPS"
  }

  expect_failures = [aws_ssm_association.peer_bootstrap["peer_1"]]
}

run "peer_bootstrap_after_management_cutover_is_admitted" {
  command = plan

  override_data {
    target = data.aws_eip.selected["management"]
    values = {
      instance_id = "i-11111111111111111"
      public_ip   = "192.0.2.10"
    }
  }

  variables {
    bootstrap_enabled = {
      management = true
      peer_1     = true
      peer_2     = false
    }

    eip_association_enabled = {
      management = true
      peer_1     = false
      peer_2     = false
    }
  }

  assert {
    condition     = length(aws_ssm_association.peer_bootstrap) == 1
    error_message = "Exactly one peer bootstrap must be admitted after management cutover is observed."
  }
}
