resource "aws_security_group" "this" {
  name        = "${var.name}-sg"
  description = "TCP 443 HTTP CONNECT and optional HTTP gateway; default deny; no SSH."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name}-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "proxy" {
  for_each = toset(local.ingress_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "HTTP CONNECT and optional HTTP gateway"
  ip_protocol       = "tcp"
  from_port         = var.proxy_port
  to_port           = var.proxy_port
  cidr_ipv4         = each.value

  tags = {
    Name = "${var.name}-ingress-proxy"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = var.ssh_enabled ? toset(local.ingress_cidrs) : toset([])

  security_group_id = aws_security_group.this.id
  description       = "Password SSH for local forwarding (proxy_user)"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value

  tags = {
    Name = "${var.name}-ingress-ssh"
  }
}

# Egress only what bootstrap + CONNECT-to-443 vendors need.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "HTTPS (dnf, GHCR, SSM, CONNECT origins)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Name = "${var.name}-egress-443"
  }
}

resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.this.id
  description       = "HTTP (package mirrors)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Name = "${var.name}-egress-80"
  }
}

resource "aws_vpc_security_group_egress_rule" "dns_udp" {
  security_group_id = aws_security_group.this.id
  description       = "DNS UDP"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Name = "${var.name}-egress-dns-udp"
  }
}

resource "aws_vpc_security_group_egress_rule" "dns_tcp" {
  security_group_id = aws_security_group.this.id
  description       = "DNS TCP"
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Name = "${var.name}-egress-dns-tcp"
  }
}
