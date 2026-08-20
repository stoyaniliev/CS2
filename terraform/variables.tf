variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "innovatech"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "region" {
  description = "Frankfurt: nearest AWS region to Innovatech's Eindhoven site and EU-resident."
  type        = string
  default     = "eu-central-1"
}

variable "azs" {
  description = "Two AZs. Two is the minimum for RDS multi-AZ and for surviving an AZ loss (REQ-NCA-P2-01)."
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b"]
}

# ---------------------------------------------------------------------------
# Address plan
#
#   10.0.0.0/16   hub        shared services: egress, DNS, hybrid entry point
#   10.1.0.0/16   platform   k3s nodes running SOAR containers + observability
#   10.2.0.0/16   data       RDS and interface endpoints, no route to internet
#   192.168.100.0/24         on-premises (Hyper-V lab), reached via Tailscale
#
# Non-overlapping by design so the on-prem range can be advertised into the
# cloud without translation, and so future spokes slot in at 10.3+.
# ---------------------------------------------------------------------------

variable "hub_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "platform_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "data_cidr" {
  type    = string
  default = "10.2.0.0/16"
}

variable "onprem_cidr" {
  description = "Hyper-V lab network on the workstation."
  type        = string
  default     = "192.168.100.0/24"
}

variable "internal_domain" {
  description = "Private DNS zone. Resolvable from the VPCs and from on-prem (REQ-NCA-P2-04)."
  type        = string
  default     = "innovatech.internal"
}

# ---------------------------------------------------------------------------
# Cost controls
# ---------------------------------------------------------------------------

variable "enable_resolver_inbound" {
  description = <<-EOT
    Route53 Resolver inbound endpoint lets on-prem resolve *.innovatech.internal.
    Costs ~USD 0.125/hr per ENI (2 ENIs = ~USD 6/day). Turn off when not demoing
    the hybrid DNS path; VPC-internal resolution keeps working either way.
  EOT
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = <<-EOT
    true  = one NAT gateway (~USD 32/mo, single point of failure for egress)
    false = one per AZ (~USD 64/mo, survives an AZ loss)

    Kept true for the sandbox budget. The failure mode and the production
    recommendation are written up in docs/01-design-document.md; egress loss
    degrades updates but does not stop SOAR response actions, which run in
    Lambda on the AWS network.
  EOT
  type        = bool
  default     = true
}

variable "admin_ip_cidr" {
  description = "Administrator public IP as a /32. Leave null to auto-detect."
  type        = string
  default     = null
}

variable "alert_email" {
  description = "Subscribed to the SOAR notification topic."
  type        = string
}
