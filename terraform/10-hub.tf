# ---------------------------------------------------------------------------
# Hub VPC — shared services (REQ-NCA-P2-02)
#
# The only VPC with an internet gateway. It provides:
#   - outbound egress for every spoke, via NAT
#   - the hybrid entry point (Tailscale subnet router)
#   - Route53 Resolver endpoints for hybrid DNS
#
# Concentrating internet exposure in one place means there is exactly one
# perimeter to audit rather than three.
# ---------------------------------------------------------------------------

resource "aws_vpc" "hub" {
  cidr_block           = var.hub_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-hub" }
}

resource "aws_internet_gateway" "hub" {
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "${var.project}-hub-igw" }
}

resource "aws_subnet" "hub_public" {
  count                   = length(var.azs)
  vpc_id                  = aws_vpc.hub.id
  cidr_block              = cidrsubnet(var.hub_cidr, 8, count.index)
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-hub-public-${substr(var.azs[count.index], -1, 1)}"
    Tier = "public"
  }
}

resource "aws_subnet" "hub_private" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.hub.id
  cidr_block        = cidrsubnet(var.hub_cidr, 8, 10 + count.index)
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.project}-hub-private-${substr(var.azs[count.index], -1, 1)}"
    Tier = "private"
  }
}

resource "aws_subnet" "hub_tgw" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.hub.id
  cidr_block        = cidrsubnet(var.hub_cidr, 12, 3840 + count.index)
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.project}-hub-tgw-${substr(var.azs[count.index], -1, 1)}"
    Tier = "transit"
  }
}

# --- NAT -------------------------------------------------------------------
# Count driven by var.single_nat_gateway; see the variable description for the
# availability trade-off being made here.

resource "aws_eip" "nat" {
  count  = var.single_nat_gateway ? 1 : length(var.azs)
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip-${count.index}" }
}

resource "aws_nat_gateway" "this" {
  count         = var.single_nat_gateway ? 1 : length(var.azs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.hub_public[count.index].id

  tags       = { Name = "${var.project}-nat-${count.index}" }
  depends_on = [aws_internet_gateway.hub]
}

# --- Routing ---------------------------------------------------------------

resource "aws_route_table" "hub_public" {
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "${var.project}-hub-public-rt" }
}

resource "aws_route" "hub_public_internet" {
  route_table_id         = aws_route_table.hub_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.hub.id
}

# Return path: traffic from the spokes arriving via TGW must find its way back.
#
# on-prem is deliberately NOT listed here. It is reached through the Tailscale
# subnet router, which lives inside this VPC — sending it to the TGW would
# bounce the packet straight back and form a loop. That route is added in
# 21-hybrid-gateway.tf, pointing at the router's ENI.
resource "aws_route" "hub_public_to_spokes" {
  for_each = {
    platform = var.platform_cidr
    data     = var.data_cidr
  }
  route_table_id         = aws_route_table.hub_public.id
  destination_cidr_block = each.value
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

resource "aws_route_table_association" "hub_public" {
  count          = length(aws_subnet.hub_public)
  subnet_id      = aws_subnet.hub_public[count.index].id
  route_table_id = aws_route_table.hub_public.id
}

resource "aws_route_table" "hub_private" {
  count  = length(var.azs)
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "${var.project}-hub-private-rt-${count.index}" }
}

resource "aws_route" "hub_private_nat" {
  count                  = length(var.azs)
  route_table_id         = aws_route_table.hub_private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
}

resource "aws_route" "hub_private_to_spokes" {
  for_each = {
    "platform-0" = { az = 0, cidr = var.platform_cidr }
    "platform-1" = { az = 1, cidr = var.platform_cidr }
    "data-0"     = { az = 0, cidr = var.data_cidr }
    "data-1"     = { az = 1, cidr = var.data_cidr }
  }
  route_table_id         = aws_route_table.hub_private[each.value.az].id
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

resource "aws_route_table_association" "hub_private" {
  count          = length(aws_subnet.hub_private)
  subnet_id      = aws_subnet.hub_private[count.index].id
  route_table_id = aws_route_table.hub_private[count.index].id
}

resource "aws_route_table_association" "hub_tgw" {
  count          = length(aws_subnet.hub_tgw)
  subnet_id      = aws_subnet.hub_tgw[count.index].id
  route_table_id = aws_route_table.hub_private[count.index].id
}
