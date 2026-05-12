# --- DNS records (opt-in) -----------------------------------------------
# Created only when var.dns_managed_zone is non-empty.
#
# Public zones: set var.dns_use_internal_ips = false (default) so records
#   resolve to the per-node external IP. Operator can connect from anywhere.
# Private zones: set var.dns_use_internal_ips = true so records resolve to
#   internal IPs. Use for in-VPC service discovery.
#
# When DNS is on, each node's FQDN is appended to its TLS cert SANs (see
# ansible/roles/cockroachdb/tasks/certs.yml), so clients can connect with
# sslmode=verify-full against the hostname.

resource "google_dns_record_set" "node" {
  for_each     = var.dns_managed_zone == "" ? {} : local.nodes
  name         = replace(var.dns_name_template, "{n}", each.key)
  type         = "A"
  ttl          = 60
  managed_zone = var.dns_managed_zone
  rrdatas = [
    var.dns_use_internal_ips
    ? google_compute_address.internal[each.key].address
    : google_compute_address.external[each.key].address
  ]
}

# Round-robin record across all nodes — useful as a generic client target
# when no load balancer is in front of the cluster.
resource "google_dns_record_set" "any" {
  count        = var.dns_managed_zone == "" ? 0 : 1
  name         = replace(var.dns_name_template, "{n}", "any")
  type         = "A"
  ttl          = 60
  managed_zone = var.dns_managed_zone
  rrdatas = [
    for k in keys(local.nodes) :
    (var.dns_use_internal_ips
      ? google_compute_address.internal[k].address
    : google_compute_address.external[k].address)
  ]
}
