# ---------------------------------------------------------------------------
# A spoke VPC: private subnets only, no internet gateway.
#
# Everything a spoke needs from the outside world it gets through the Transit
# Gateway and the hub. That is the structural half of REQ-NCA-P2-03 — a PaaS
# resource placed here has no path to the public internet even if a security
# group is later misconfigured, because no such route exists.
# ---------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

variable "name" { type = string }
variable "cidr" { type = string }
variable "azs" { type = list(string) }
variable "transit_gateway_id" { type = string }
variable "default_route_to_tgw" {
  description = "Send 0.0.0.0/0 to the TGW so the hub NAT provides egress. False = fully isolated."
  type        = bool
  default     = true
}
variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_subnet" "private" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr, 8, 10 + count.index)
  availability_zone = var.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name}-private-${substr(var.azs[count.index], -1, 1)}"
    Tier = "private"
  })
}

# Dedicated /28s for the TGW attachment ENIs. Keeping them out of the workload
# subnets avoids the attachment eating usable addresses and makes flow logs
# easier to read.
resource "aws_subnet" "tgw" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr, 12, 3840 + count.index)
  availability_zone = var.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name}-tgw-${substr(var.azs[count.index], -1, 1)}"
    Tier = "transit"
  })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  subnet_ids                                      = aws_subnet.tgw[*].id
  transit_gateway_id                              = var.transit_gateway_id
  vpc_id                                          = aws_vpc.this.id
  dns_support                                     = "enable"
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = merge(var.tags, { Name = "${var.name}-attach" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-private-rt" })
}

resource "aws_route" "default_via_tgw" {
  count                  = var.default_route_to_tgw ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "tgw" {
  count          = length(aws_subnet.tgw)
  subnet_id      = aws_subnet.tgw[count.index].id
  route_table_id = aws_route_table.private.id
}

# VPC flow logs: evidence for the SOAR event story and for incident forensics.
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/aws/vpc/${var.name}/flowlogs"
  retention_in_days = 7
  tags              = var.tags
}

output "vpc_id" { value = aws_vpc.this.id }
output "cidr" { value = aws_vpc.this.cidr_block }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "route_table_id" { value = aws_route_table.private.id }
output "attachment_id" { value = aws_ec2_transit_gateway_vpc_attachment.this.id }
output "flow_log_group" { value = aws_cloudwatch_log_group.flow.name }

# Exposed so the SOAR block_ip action knows which ACL to write DENY rules into.
output "default_network_acl_id" {
  value = aws_vpc.this.default_network_acl_id
}
