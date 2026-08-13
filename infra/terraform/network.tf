resource "aws_security_group" "management" {
  name_prefix            = "${var.name_prefix}-${var.environment}-management-"
  description            = "Public NetBird management reverse proxy and STUN only."
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true

  tags = {
    Name = "${var.name_prefix}-${var.environment}-management"
    Role = "management"
  }
}

resource "aws_security_group" "peers" {
  name_prefix            = "${var.name_prefix}-${var.environment}-peers-"
  description            = "Routing peers initiate NetBird and routed connections outbound."
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true

  tags = {
    Name = "${var.name_prefix}-${var.environment}-peers"
    Role = "routing-peer"
  }
}

resource "aws_vpc_security_group_ingress_rule" "management_http" {
  security_group_id = aws_security_group.management.id
  description       = "HTTP redirect and ACME challenge"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "management_https" {
  security_group_id = aws_security_group.management.id
  description       = "NetBird HTTPS, API, gRPC, WebSocket, and relay"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "management_quic" {
  security_group_id = aws_security_group.management.id
  description       = "Caddy HTTP3 and NetBird relay QUIC"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_ingress_rule" "management_stun" {
  security_group_id = aws_security_group.management.id
  description       = "Coturn STUN"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 3478
  to_port           = 3478
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_ingress_rule" "management_ssh" {
  for_each = var.admin_ipv4_cidrs

  security_group_id = aws_security_group.management.id
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

resource "aws_vpc_security_group_ingress_rule" "peers_wireguard" {
  security_group_id = aws_security_group.peers.id
  description       = "WireGuard direct P2P; parity with the current exit nodes so clients connect directly instead of relaying"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 51820
  to_port           = 51820
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_ingress_rule" "peers_ssh" {
  for_each = var.admin_ipv4_cidrs

  security_group_id = aws_security_group.peers.id
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

resource "aws_vpc_security_group_egress_rule" "management_all" {
  security_group_id = aws_security_group.management.id
  description       = "Package, ACME, IdP, and peer-control egress"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "peers_all" {
  security_group_id = aws_security_group.peers.id
  description       = "NetBird control, P2P, relay, and routed-resource egress"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
