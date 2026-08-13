# NetBird peers need no inbound ports: control, ICE/STUN, relay, and routed
# traffic are all initiated outbound. SSH stays closed unless explicit
# administrator CIDRs are supplied; Session Manager is the default path.
resource "aws_security_group" "exit_node" {
  name_prefix            = "${local.hostname}-"
  description            = "NetBird exit node; outbound-only with optional admin SSH."
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true

  tags = {
    Name = local.hostname
    Role = "exit-node"
  }
}

resource "aws_vpc_security_group_ingress_rule" "wireguard" {
  count = var.open_wireguard_port ? 1 : 0

  security_group_id = aws_security_group.exit_node.id
  description       = "WireGuard direct P2P (optional; peers can also hole-punch or relay)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 51820
  to_port           = 51820
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = var.admin_ipv4_cidrs

  security_group_id = aws_security_group.exit_node.id
  description       = "Explicit administrator SSH access"
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"

  lifecycle {
    precondition {
      condition     = try(length(trimspace(var.key_name)) > 0, false)
      error_message = "SSH ingress requires a non-empty EC2 key_name; Session Manager is the default."
    }
  }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.exit_node.id
  description       = "NetBird control, P2P, relay, and routed internet egress"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_eip" "exit_node" {
  count = var.create_eip ? 1 : 0

  domain = "vpc"

  tags = {
    Name = "${local.hostname}-eip"
    Role = "exit-node"
  }
}

resource "aws_eip_association" "exit_node" {
  count = var.create_eip ? 1 : 0

  allocation_id = aws_eip.exit_node[0].id
  instance_id   = aws_instance.exit_node.id
}
