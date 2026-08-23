# ---------------------------------------------------------------------------
# Simulated on-premises corporate server (REQ-NCA-P2-06)
#
# The requirement names on-premises workstations and servers as event sources,
# and the assignment permits simulating them. This instance plays that role: it
# runs rsyslog and a forwarder agent that tails the authentication log and
# posts anything security-relevant to the SOAR ingest endpoint.
#
# It is a real host producing real log lines from real failed logins, not a
# script generating synthetic JSON. When the demonstration runs a brute force
# against it, sshd writes the failures, the agent picks them up, and the
# response fires. Nothing is fabricated anywhere in that chain.
#
# It sits in the platform spoke rather than in a separate network because the
# genuine on-premises network is reached over Tailscale, and adding a fourth
# VPC to imitate one would add cost without adding realism. The instance is
# tagged Environment=onpremises so dashboards and Prometheus can distinguish it.
# ---------------------------------------------------------------------------

resource "aws_security_group" "corp_server" {
  name        = "${var.project}-corp-server"
  description = "Simulated on-premises corporate server"
  vpc_id      = module.platform_spoke.vpc_id

  ingress {
    description = "SSH from the bastion, and from the platform spoke for the brute force simulation"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.hub_cidr, var.platform_cidr]
  }

  ingress {
    description = "node_exporter, so the host appears in Prometheus like any monitored server"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [var.platform_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-corp-server-sg" }
}

resource "aws_instance" "corp_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = module.platform_spoke.private_subnet_ids[0]
  key_name               = aws_key_pair.main.key_name
  vpc_security_group_ids = [aws_security_group.corp_server.id]

  user_data = templatefile("${path.module}/templates/corp-server-install.sh.tftpl", {
    soar_ingest_url = "https://${aws_api_gateway_rest_api.soar.id}.execute-api.${var.region}.amazonaws.com/prod/events"
    forwarder_code  = file("${path.module}/../soar/forwarder/syslog_forwarder.py")
  })

  user_data_replace_on_change = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name        = "${var.project}-corp-server"
    Role        = "onprem-server"
    Environment = "onpremises"
    # Not marked SOARable: this host is the event *source*. Quarantining the
    # machine that reports intrusions would silence the alarm rather than
    # contain the intruder.
  }

  depends_on = [aws_api_gateway_stage.prod]
}

resource "aws_route53_record" "corp_server" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "corp-server.${var.internal_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.corp_server.private_ip]
}

output "corp_server_ip" {
  description = "Simulated on-premises server, the syslog event source"
  value       = aws_instance.corp_server.private_ip
}

output "corp_server_id" {
  value = aws_instance.corp_server.id
}
