# ---------------------------------------------------------------------------
# Administrator source address.
#
# Detected at plan time rather than hard-coded, because a home connection's
# public address changes whenever the router reconnects — and a stale value
# here silently locks the operator out of the bastion.
#
# checkip.amazonaws.com is used rather than a third-party service so that
# deployment does not depend on infrastructure outside the provider.
#
# Set var.admin_ip_cidr explicitly to override, which CI must do: the detected
# address there would be the runner's, not the operator's.
# ---------------------------------------------------------------------------

data "http" "myip" {
  count = var.admin_ip_cidr == null ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  admin_ip_cidr = var.admin_ip_cidr == null ? "${chomp(data.http.myip[0].response_body)}/32" : var.admin_ip_cidr
}

output "admin_ip_in_use" {
  description = "The address currently permitted to reach the bastion over SSH."
  value       = local.admin_ip_cidr
}
