# ---------------------------------------------------------------------------
# Hybrid gateway (business context: "secure and reliable communication with
# the existing on-premises infrastructure")
#
# One instance, two jobs:
#   1. Tailscale subnet router — advertises the cloud ranges to the on-prem
#      machines and vice versa, over a WireGuard mesh. Chosen over Site-to-Site
#      VPN because the on-premises lab sits behind consumer NAT with no static
#      public address, which rules out an IPsec tunnel endpoint.
#   2. Bastion — the single SSH entry point to instances in the private spokes.
#
# Justification for the design document: this is the Zero Trust position.
# Rather than a flat tunnel joining two trusted networks, every node
# authenticates individually to the coordination server and ACLs are applied
# per-node. Losing one machine does not expose the network behind it.
# ---------------------------------------------------------------------------

variable "tailscale_auth_key" {
  description = <<-EOT
    Reusable, ephemeral, pre-authorised auth key from
    https://login.tailscale.com/admin/settings/keys
    Tag it (e.g. tag:aws) so ACLs can be written against it.
  EOT
  type        = string
  sensitive   = true
}

resource "aws_security_group" "hybrid_gw" {
  name        = "${var.project}-hybrid-gw"
  description = "Bastion and Tailscale subnet router"
  vpc_id      = aws_vpc.hub.id

  ingress {
    description = "SSH from the administrator workstation only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.admin_ip_cidr]
  }

  ingress {
    description = "Tailscale WireGuard, for direct peer-to-peer rather than relayed traffic"
    from_port   = 41641
    to_port     = 41641
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Traffic from the internal networks being routed on-prem"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.hub_cidr, var.platform_cidr, var.data_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-hybrid-gw-sg" }
}

resource "aws_instance" "hybrid_gw" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.hub_public[0].id
  key_name               = aws_key_pair.main.key_name
  vpc_security_group_ids = [aws_security_group.hybrid_gw.id]

  # Required: the kernel will not forward packets for other hosts while the
  # source/destination check is active, which silently breaks subnet routing.
  source_dest_check = false

  user_data = templatefile("${path.module}/templates/hybrid-gw.sh.tftpl", {
    tailscale_auth_key = var.tailscale_auth_key
    advertise_routes   = join(",", [var.hub_cidr, var.platform_cidr, var.data_cidr])
    onprem_cidr        = var.onprem_cidr
  })

  user_data_replace_on_change = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.project}-hybrid-gw"
    Role = "hybrid-gateway"
  }
}

# Now the on-prem route can point at a real ENI (see note in 10-hub.tf).
resource "aws_route" "hub_public_to_onprem" {
  route_table_id         = aws_route_table.hub_public.id
  destination_cidr_block = var.onprem_cidr
  network_interface_id   = aws_instance.hybrid_gw.primary_network_interface_id
}

resource "aws_route" "hub_private_to_onprem" {
  count                  = length(var.azs)
  route_table_id         = aws_route_table.hub_private[count.index].id
  destination_cidr_block = var.onprem_cidr
  network_interface_id   = aws_instance.hybrid_gw.primary_network_interface_id
}

output "bastion_public_ip" {
  value = aws_instance.hybrid_gw.public_ip
}

output "ssh_bastion" {
  value = "ssh -i innovatech-key.pem ubuntu@${aws_instance.hybrid_gw.public_ip}"
}
