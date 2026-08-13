variable "aws_region" {
  description = "AWS Region containing the existing VPC and subnet."
  type        = string
  default     = "ap-southeast-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a valid AWS Region name."
  }
}

variable "name_prefix" {
  description = "Short prefix used for resource names."
  type        = string
  default     = "sleek-netbird"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,23}$", var.name_prefix))
    error_message = "name_prefix must be 2-24 lowercase letters, numbers, or hyphens and start with a letter."
  }
}

variable "environment" {
  description = "Deployment environment label."
  type        = string
  default     = "production"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,15}$", var.environment))
    error_message = "environment must be 2-16 lowercase letters, numbers, or hyphens and start with a letter."
  }
}

variable "node_name" {
  description = "Short name of this exit node, appended to the prefix and environment."
  type        = string
  default     = "exit-1"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,15}$", var.node_name))
    error_message = "node_name must be 2-16 lowercase letters, numbers, or hyphens and start with a letter."
  }
}

variable "vpc_id" {
  description = "ID of the existing VPC."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must look like vpc-0123456789abcdef0."
  }
}

variable "subnet_id" {
  description = "Existing public subnet for the exit node. It must provide a route to an internet gateway."
  type        = string

  validation {
    condition     = can(regex("^subnet-[0-9a-f]+$", var.subnet_id))
    error_message = "subnet_id must look like subnet-0123456789abcdef0."
  }
}

variable "domain" {
  description = "Public NetBird management domain the exit node enrolls against."
  type        = string
  default     = "nbvpn.sleek.com"

  validation {
    condition = (
      length(var.domain) <= 253 &&
      can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", var.domain))
    )
    error_message = "domain must be a lowercase fully-qualified DNS name."
  }
}

variable "instance_type" {
  description = "Graviton instance type for the exit node."
  type        = string
  default     = "t4g.micro"

  validation {
    condition     = can(regex("^t4g\\.", var.instance_type))
    error_message = "instance_type must be a t4g Graviton size; the bootstrap and AMI lookup assume arm64."
  }
}

variable "root_volume_size_gib" {
  description = "Encrypted gp3 root-volume size."
  type        = number
  default     = 16

  validation {
    condition     = var.root_volume_size_gib >= 12 && floor(var.root_volume_size_gib) == var.root_volume_size_gib
    error_message = "root_volume_size_gib must be an integer of at least 12 GiB."
  }
}

variable "ami_id" {
  description = "Optional pinned Amazon-owned ARM64 AL2023 AMI. Null resolves the current public SSM parameter."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.ami_id == null || can(regex("^ami-[0-9a-f]+$", var.ami_id))
    error_message = "ami_id must be null or look like ami-0123456789abcdef0."
  }
}

variable "ami_ssm_parameter" {
  description = "Public SSM parameter used when ami_id is null."
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

variable "associate_public_ipv4_address" {
  description = "Assign an AWS-managed public IPv4 address. Required unless create_eip is true or the subnet routes through NAT."
  type        = bool
  default     = true
}

variable "create_eip" {
  description = "Allocate and associate a dedicated Elastic IP so the exit node keeps a stable egress address across stop/start."
  type        = bool
  default     = false
}

variable "open_wireguard_port" {
  description = "Open inbound UDP 51820 so peers can reach WireGuard directly instead of hole-punching or falling back to the relay. Everything else stays outbound-only."
  type        = bool
  default     = true
}

variable "key_name" {
  description = "Optional existing EC2 key-pair name. Session Manager remains the default administrative path."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.key_name == null || try(length(trimspace(var.key_name)) > 0, false)
    error_message = "key_name must be null or a non-empty EC2 key-pair name."
  }
}

variable "admin_ipv4_cidrs" {
  description = "Explicit IPv4 CIDRs allowed to SSH to the node. Empty disables SSH ingress."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.admin_ipv4_cidrs : can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0"
    ])
    error_message = "admin_ipv4_cidrs must contain valid, non-world-open IPv4 CIDRs."
  }
}

variable "ebs_kms_key_arn" {
  description = "Optional customer-managed KMS key ARN for the root volume. Null uses the AWS managed EBS key."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.ebs_kms_key_arn == null || can(regex("^arn:[^:]+:kms:[^:]+:[0-9]{12}:key/", var.ebs_kms_key_arn))
    error_message = "ebs_kms_key_arn must be null or a KMS key ARN."
  }
}

variable "secrets_kms_key_arn" {
  description = "Optional customer-managed KMS key ARN for the setup-key secret."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.secrets_kms_key_arn == null || can(regex("^arn:[^:]+:kms:[^:]+:[0-9]{12}:key/", var.secrets_kms_key_arn))
    error_message = "secrets_kms_key_arn must be null or a KMS key ARN."
  }
}

variable "secret_recovery_window_days" {
  description = "Secrets Manager recovery window if the secret resource is removed."
  type        = number
  default     = 30

  validation {
    condition     = var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30
    error_message = "secret_recovery_window_days must be between 7 and 30."
  }
}

variable "enable_termination_protection" {
  description = "Enable EC2 API termination protection. Off by default so a broken exit node can be replaced quickly."
  type        = bool
  default     = false
}

variable "enable_detailed_monitoring" {
  description = "Publish one-minute EC2 metrics. Off by default to keep the micro node cheap."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags applied through the AWS provider."
  type        = map(string)
  default     = {}
}
