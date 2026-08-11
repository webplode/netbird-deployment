variable "aws_region" {
  description = "AWS Region containing the existing VPC, subnets, and EIPs."
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
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}$", var.name_prefix))
    error_message = "name_prefix must be 3-24 lowercase letters, numbers, or hyphens and start with a letter."
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

variable "vpc_id" {
  description = "ID of the existing VPC."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must look like vpc-0123456789abcdef0."
  }
}

variable "subnet_ids" {
  description = "Existing subnet for each node. peer_1 and peer_2 must be in different Availability Zones."
  type = object({
    management = string
    peer_1     = string
    peer_2     = string
  })

  validation {
    condition = alltrue([
      for subnet_id in values(var.subnet_ids) : can(regex("^subnet-[0-9a-f]+$", subnet_id))
    ])
    error_message = "Every subnet ID must look like subnet-0123456789abcdef0."
  }
}

variable "private_ipv4_addresses" {
  description = "Optional fixed private IPv4 addresses. Leave omitted for AWS-assigned addresses; do not reuse live addresses."
  type = object({
    management = optional(string)
    peer_1     = optional(string)
    peer_2     = optional(string)
  })
  default = {}

  validation {
    condition = alltrue([
      for address in values(var.private_ipv4_addresses) : address == null || can(cidrnetmask("${address}/32"))
    ])
    error_message = "private_ipv4_addresses values must be valid IPv4 addresses."
  }
}

variable "eip_allocation_ids" {
  description = "Externally owned EIP allocation IDs. Supplying IDs alone never moves them; see eip_association_enabled."
  type = object({
    management = string
    peer_1     = string
    peer_2     = string
  })

  validation {
    condition = (
      length(distinct(values(var.eip_allocation_ids))) == 3 &&
      alltrue([
        for allocation_id in values(var.eip_allocation_ids) : can(regex("^eipalloc-[0-9a-f]+$", allocation_id))
      ])
    )
    error_message = "Provide three distinct EIP allocation IDs in eipalloc-... form."
  }
}

variable "eip_association_enabled" {
  description = "Per-node production cutover gate. Enable only one reviewed association at a time."
  type = object({
    management = bool
    peer_1     = bool
    peer_2     = bool
  })
  default = {
    management = false
    peer_1     = false
    peer_2     = false
  }
}

variable "eip_rollback_instance_ids" {
  description = "Instance IDs currently holding each EIP, recorded immediately before cutover for manual rollback."
  type = object({
    management = optional(string)
    peer_1     = optional(string)
    peer_2     = optional(string)
  })
  default = {}

  validation {
    condition = alltrue([
      for instance_id in values(var.eip_rollback_instance_ids) : instance_id == null || can(regex("^i-[0-9a-f]+$", instance_id))
    ])
    error_message = "eip_rollback_instance_ids values must look like i-0123456789abcdef0."
  }
}

variable "eip_cutover_confirmation" {
  description = "Must equal REASSOCIATE_SLEEK_NETBIRD_EIPS before any enabled EIP association can apply."
  type        = string
  default     = ""
}

variable "bootstrap_enabled" {
  description = "Per-node SSM bootstrap gate. Populate its Secrets Manager value before enabling a node."
  type = object({
    management = bool
    peer_1     = bool
    peer_2     = bool
  })
  default = {
    management = false
    peer_1     = false
    peer_2     = false
  }
}

variable "associate_public_ipv4_address" {
  description = "Give each new instance a temporary public IPv4 address before its EIP cutover."
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
  description = "Explicit IPv4 CIDRs allowed to SSH to the nodes. Empty disables SSH ingress."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.admin_ipv4_cidrs : can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0"
    ])
    error_message = "admin_ipv4_cidrs must contain valid, non-world-open IPv4 CIDRs."
  }
}

variable "domain" {
  description = "Public NetBird management domain."
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

variable "acme_email" {
  description = "ACME account email used by Caddy."
  type        = string
  default     = "anh.bui@sleek.com"

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.acme_email))
    error_message = "acme_email must be an email address."
  }
}

variable "acme_ca" {
  description = "ACME directory URL used by Caddy."
  type        = string
  default     = "https://acme.zerossl.com/v2/DV90"

  validation {
    condition     = startswith(var.acme_ca, "https://")
    error_message = "acme_ca must use HTTPS."
  }
}

variable "oidc_issuer_url" {
  description = "JumpCloud OIDC issuer consumed by OAuth2-Proxy."
  type        = string
  default     = "https://oauth.id.jumpcloud.com/"

  validation {
    condition     = startswith(var.oidc_issuer_url, "https://")
    error_message = "oidc_issuer_url must use HTTPS."
  }
}

variable "oauth2_allowed_group" {
  description = "OIDC group permitted to access the NetBird dashboard."
  type        = string
  default     = "NetBird Staging Admin"

  validation {
    condition     = length(trimspace(var.oauth2_allowed_group)) > 0
    error_message = "oauth2_allowed_group cannot be empty."
  }
}

variable "turn_realm" {
  description = "Coturn authentication realm retained from the current deployment."
  type        = string
  default     = "wiretrustee.com"
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

variable "root_volume_sizes_gib" {
  description = "Encrypted gp3 root-volume sizes."
  type = object({
    management = number
    peer_1     = number
    peer_2     = number
  })
  default = {
    management = 30
    peer_1     = 16
    peer_2     = 16
  }

  validation {
    condition     = alltrue([for size in values(var.root_volume_sizes_gib) : size >= 12 && floor(size) == size])
    error_message = "Every root volume must be an integer of at least 12 GiB."
  }
}

variable "management_data_volume_size_gib" {
  description = "Size of the persistent management/Caddy gp3 data volume."
  type        = number
  default     = 30

  validation {
    condition     = var.management_data_volume_size_gib >= 20 && floor(var.management_data_volume_size_gib) == var.management_data_volume_size_gib
    error_message = "management_data_volume_size_gib must be an integer of at least 20 GiB."
  }
}

variable "management_data_snapshot_id" {
  description = "Optional snapshot of a dedicated compatible data volume. A snapshot of the old root disk is not directly compatible."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.management_data_snapshot_id == null || can(regex("^snap-[0-9a-f]+$", var.management_data_snapshot_id))
    error_message = "management_data_snapshot_id must be null or look like snap-0123456789abcdef0."
  }
}

variable "ebs_kms_key_arn" {
  description = "Optional customer-managed KMS key ARN for all EBS volumes. Null uses the AWS managed EBS key."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.ebs_kms_key_arn == null || can(regex("^arn:[^:]+:kms:[^:]+:[0-9]{12}:key/", var.ebs_kms_key_arn))
    error_message = "ebs_kms_key_arn must be null or a KMS key ARN."
  }
}

variable "secrets_kms_key_arn" {
  description = "Optional customer-managed KMS key ARN for runtime Secrets Manager secrets."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.secrets_kms_key_arn == null || can(regex("^arn:[^:]+:kms:[^:]+:[0-9]{12}:key/", var.secrets_kms_key_arn))
    error_message = "secrets_kms_key_arn must be null or a KMS key ARN."
  }
}

variable "secret_recovery_window_days" {
  description = "Secrets Manager recovery window if a secret resource is removed."
  type        = number
  default     = 30

  validation {
    condition     = var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30
    error_message = "secret_recovery_window_days must be between 7 and 30."
  }
}

variable "enable_termination_protection" {
  description = "Enable EC2 API termination protection. Disable explicitly before an intentional replacement or destroy."
  type        = bool
  default     = true
}

variable "enable_detailed_monitoring" {
  description = "Publish one-minute EC2 metrics."
  type        = bool
  default     = true
}

variable "alarm_action_arns" {
  description = "Optional SNS topic ARNs invoked by CloudWatch alarms."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.alarm_action_arns : can(regex("^arn:[^:]+:sns:", arn))])
    error_message = "alarm_action_arns must contain SNS topic ARNs."
  }
}

variable "tags" {
  description = "Additional tags applied through the AWS provider."
  type        = map(string)
  default     = {}
}
