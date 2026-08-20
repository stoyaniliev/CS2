# Auto-detect the administrator's public IP so the bastion rule stays correct
# across ISP address changes. Overridable via var.admin_ip_cidr for CI runs,
# where the detected address would be the runner's, not the operator's.

data "http" "myip" {
  count = var.admin_ip_cidr == null ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  detected_ip   = var.admin_ip_cidr == null ? "${chomp(data.http.myip[0].response_body)}/32" : var.admin_ip_cidr
  admin_ip_cidr = local.detected_ip
}

output "admin_ip_in_use" {
  description = "The address currently permitted to SSH to the bastion."
  value       = local.admin_ip_cidr
}