# ---------------------------------------------------------------------------
# Container platform (REQ-NCA-P2-07)
#
# k3s on EC2 rather than EKS: the Fontys account SCP denies eks:*, confirmed by
# probe. k3s is a CNCF-certified conformant Kubernetes distribution, so the
# manifests and Helm charts are unchanged from what EKS would take — the
# portability argument for the design document holds.
# ---------------------------------------------------------------------------

resource "aws_security_group" "k3s" {
  name        = "${var.project}-k3s"
  description = "k3s server and workloads"
  vpc_id      = module.platform_spoke.vpc_id

  ingress {
    description = "SSH from the bastion"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.hub_cidr]
  }

  ingress {
    description = "Kubernetes API from hub and on-prem admin"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.hub_cidr, var.onprem_cidr]
  }

  ingress {
    description = "Grafana, Prometheus, Alertmanager via NodePort"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [var.hub_cidr, var.onprem_cidr, var.platform_cidr]
  }

  ingress {
    description = "Node-to-node inside the cluster"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-k3s-sg" }
}

resource "aws_instance" "k3s_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.large" # 2 vCPU / 8 GB — Prometheus + Loki + Grafana + SOAR pods
  subnet_id              = module.platform_spoke.private_subnet_ids[0]
  key_name               = aws_key_pair.main.key_name
  vpc_security_group_ids = [aws_security_group.k3s.id]
  iam_instance_profile   = aws_iam_instance_profile.k3s.name

  user_data                   = file("${path.module}/templates/k3s-install.sh")
  user_data_replace_on_change = true

  root_block_device {
    volume_size = 40
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.project}-k3s-server"
    Role = "k3s-server"
  }
}

# ---------------------------------------------------------------------------
# Demo target: the "compromised workstation" the SOAR quarantine action acts on.
#
# Prometheus scrapes its node_exporter. When quarantine-host swaps its security
# group, the scrape starts failing and the Grafana panel goes red — detection,
# response and consequence all visible on one screen.
# ---------------------------------------------------------------------------

resource "aws_security_group" "workload_normal" {
  name        = "${var.project}-workload-normal"
  description = "Healthy state: reachable by Prometheus"
  vpc_id      = module.platform_spoke.vpc_id

  ingress {
    description = "node_exporter metrics"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [var.platform_cidr]
  }

  ingress {
    description = "SSH from the bastion"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.hub_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-workload-normal-sg" }
}

# Empty ingress AND empty egress: total network isolation. The instance keeps
# running so forensics are possible, but it can neither be reached nor call out.
resource "aws_security_group" "quarantine" {
  name        = "${var.project}-quarantine"
  description = "SOAR isolation group - no ingress, no egress"
  vpc_id      = module.platform_spoke.vpc_id

  tags = {
    Name    = "${var.project}-quarantine-sg"
    Purpose = "soar-response-action"
  }
}

resource "aws_instance" "demo_workstation" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = module.platform_spoke.private_subnet_ids[1]
  key_name               = aws_key_pair.main.key_name
  vpc_security_group_ids = [aws_security_group.workload_normal.id]

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    apt-get update -y
    apt-get install -y prometheus-node-exporter
    systemctl enable --now prometheus-node-exporter
  EOF

  # The SOAR quarantine action changes this instance's security groups at
  # runtime. Terraform must not treat that as configuration drift and revert it.
  lifecycle {
    ignore_changes = [vpc_security_group_ids]
  }

  tags = {
    Name     = "${var.project}-demo-workstation"
    Role     = "demo-target"
    SOARable = "true" # the quarantine action refuses to touch anything without this
  }
}

output "k3s_private_ip" {
  value = aws_instance.k3s_server.private_ip
}

output "demo_workstation_id" {
  value = aws_instance.demo_workstation.id
}
