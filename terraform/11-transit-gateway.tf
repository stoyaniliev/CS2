# ---------------------------------------------------------------------------
# Transit Gateway — the hub of the hub-and-spoke (REQ-NCA-P2-02)
#
# Default association and propagation are switched OFF. Every attachment is
# bound to a route table explicitly, so reachability is something written down
# rather than something that happens by accident. Two route tables:
#
#   hub-rt    reaches everything (it is the shared-services and egress path)
#   spoke-rt  reaches the hub only — spokes cannot talk to each other
#
# That is the "controlled traffic flow" the requirement asks for: a compromised
# k3s node in the platform spoke has no network path to the data spoke except
# the routes we deliberately add below.
# ---------------------------------------------------------------------------

resource "aws_ec2_transit_gateway" "main" {
  description                     = "Innovatech hub-and-spoke core"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  vpn_ecmp_support                = "enable"

  tags = { Name = "${var.project}-tgw" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "hub" {
  subnet_ids                                      = aws_subnet.hub_tgw[*].id
  transit_gateway_id                              = aws_ec2_transit_gateway.main.id
  vpc_id                                          = aws_vpc.hub.id
  dns_support                                     = "enable"
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project}-hub-attach" }
}

# --- Route tables ----------------------------------------------------------

resource "aws_ec2_transit_gateway_route_table" "hub" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  tags               = { Name = "${var.project}-tgw-rt-hub" }
}

resource "aws_ec2_transit_gateway_route_table" "spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  tags               = { Name = "${var.project}-tgw-rt-spoke" }
}

# --- Associations: which table an attachment consults -----------------------

resource "aws_ec2_transit_gateway_route_table_association" "hub" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub.id
}

resource "aws_ec2_transit_gateway_route_table_association" "platform" {
  transit_gateway_attachment_id  = module.platform_spoke.attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke.id
}

resource "aws_ec2_transit_gateway_route_table_association" "data" {
  transit_gateway_attachment_id  = module.data_spoke.attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke.id
}

# --- Propagations: hub table learns every spoke prefix ----------------------

resource "aws_ec2_transit_gateway_route_table_propagation" "platform_to_hub" {
  transit_gateway_attachment_id  = module.platform_spoke.attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "data_to_hub" {
  transit_gateway_attachment_id  = module.data_spoke.attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub.id
}

# --- Spoke table: default out through the hub, nothing lateral --------------

resource "aws_ec2_transit_gateway_route" "spoke_default" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke.id
}

# One deliberate exception: the platform spoke must reach the database.
# Written as an explicit route so it appears in the design document as a
# conscious decision rather than an emergent property.
resource "aws_ec2_transit_gateway_route" "platform_to_data" {
  destination_cidr_block         = var.data_cidr
  transit_gateway_attachment_id  = module.data_spoke.attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke.id
}

# --- Spokes ----------------------------------------------------------------

module "platform_spoke" {
  source = "./modules/spoke-vpc"

  name               = "${var.project}-platform"
  cidr               = var.platform_cidr
  azs                = var.azs
  transit_gateway_id = aws_ec2_transit_gateway.main.id

  # Needs egress: pulling container images, Helm charts, OS updates.
  default_route_to_tgw = true

  tags = { Spoke = "platform" }
}

module "data_spoke" {
  source = "./modules/spoke-vpc"

  name               = "${var.project}-data"
  cidr               = var.data_cidr
  azs                = var.azs
  transit_gateway_id = aws_ec2_transit_gateway.main.id

  # No default route at all. The database has no outbound internet path,
  # by construction rather than by firewall rule (REQ-NCA-P2-03).
  default_route_to_tgw = false

  tags = { Spoke = "data" }
}

# The data spoke still needs a return path toward the platform spoke.
resource "aws_route" "data_to_platform" {
  route_table_id         = module.data_spoke.route_table_id
  destination_cidr_block = var.platform_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id
}

resource "aws_route" "data_to_hub" {
  route_table_id         = module.data_spoke.route_table_id
  destination_cidr_block = var.hub_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id
}

# On-prem reachability from both spokes, for syslog return traffic and
# Prometheus scraping the on-prem node exporter.
resource "aws_route" "platform_to_onprem" {
  route_table_id         = module.platform_spoke.route_table_id
  destination_cidr_block = var.onprem_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id
}

resource "aws_ec2_transit_gateway_route" "onprem_via_hub" {
  destination_cidr_block         = var.onprem_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke.id
}
