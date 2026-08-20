# ---------------------------------------------------------------------------
# Private DNS (REQ-NCA-P2-04)
#
# A private hosted zone associated with all three VPCs gives cloud resources
# names like db.innovatech.internal that resolve to private addresses only.
# The Resolver inbound endpoint extends the same names to the on-premises
# network, so a syslog collector on the corp server can reach the database by
# name without a hosts file.
# ---------------------------------------------------------------------------

resource "aws_route53_zone" "internal" {
  name = var.internal_domain

  vpc {
    vpc_id = aws_vpc.hub.id
  }

  # Additional VPC associations are managed by the separate resources below;
  # ignoring the inline block prevents Terraform fighting itself on re-apply.
  lifecycle {
    ignore_changes = [vpc]
  }

  tags = { Name = "${var.project}-internal-zone" }
}

resource "aws_route53_zone_association" "platform" {
  zone_id = aws_route53_zone.internal.zone_id
  vpc_id  = module.platform_spoke.vpc_id
}

resource "aws_route53_zone_association" "data" {
  zone_id = aws_route53_zone.internal.zone_id
  vpc_id  = module.data_spoke.vpc_id
}

# --- Resolver inbound endpoint ---------------------------------------------
# On-prem DNS forwards *.innovatech.internal here.

resource "aws_security_group" "resolver_inbound" {
  count       = var.enable_resolver_inbound ? 1 : 0
  name        = "${var.project}-resolver-inbound"
  description = "DNS queries from on-premises and from the VPCs"
  vpc_id      = aws_vpc.hub.id

  ingress {
    description = "DNS over UDP"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.onprem_cidr, var.hub_cidr, var.platform_cidr, var.data_cidr]
  }

  ingress {
    description = "DNS over TCP (large responses, zone transfers)"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [var.onprem_cidr, var.hub_cidr, var.platform_cidr, var.data_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-resolver-inbound-sg" }
}

resource "aws_route53_resolver_endpoint" "inbound" {
  count     = var.enable_resolver_inbound ? 1 : 0
  name      = "${var.project}-inbound"
  direction = "INBOUND"

  security_group_ids = [aws_security_group.resolver_inbound[0].id]

  dynamic "ip_address" {
    for_each = aws_subnet.hub_private
    content {
      subnet_id = ip_address.value.id
    }
  }

  tags = { Name = "${var.project}-resolver-inbound" }
}

output "resolver_inbound_ips" {
  description = "Point the on-prem resolver at these for *.innovatech.internal"
  value       = var.enable_resolver_inbound ? [for ip in aws_route53_resolver_endpoint.inbound[0].ip_address : ip.ip] : []
}
