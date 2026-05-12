output "nodes" {
  description = "Per-node infra metadata consumed by ansible/inventory/render.sh."
  value = {
    for k, v in local.nodes : k => {
      internal_ip    = google_compute_address.internal[k].address
      external_ip    = google_compute_address.external[k].address
      locality_label = v.locality
      gce_zone       = v.zone
      region         = v.region
      # FQDN minus trailing dot when DNS is enabled, else empty string.
      dns_name = var.dns_managed_zone == "" ? "" : trimsuffix(replace(var.dns_name_template, "{n}", k), ".")
    }
  }
}

output "ansible_group_vars" {
  description = "Terraform-controlled values rendered into ansible/inventory/group_vars/all.yml by render.sh."
  value = {
    crdb_cache          = var.crdb_cache
    crdb_max_sql_memory = var.crdb_max_sql_memory
    # When LB is enabled, every node cert needs the VIP as a SAN so clients
    # can connect to --host=<lb_ip> with sslmode=verify-full.
    crdb_lb_ip = var.create_internal_lb ? google_compute_forwarding_rule.sql[0].ip_address : ""
  }
}

output "dns_records" {
  description = "FQDNs created when var.dns_managed_zone is set (empty list otherwise)."
  value = var.dns_managed_zone == "" ? [] : concat(
    [for k, _ in local.nodes : trimsuffix(replace(var.dns_name_template, "{n}", k), ".")],
    [trimsuffix(replace(var.dns_name_template, "{n}", "any"), ".")],
  )
}

output "internal_lb_ip" {
  description = "Internal load balancer IP (empty string when create_internal_lb=false)."
  value       = var.create_internal_lb ? google_compute_forwarding_rule.sql[0].ip_address : ""
}

output "ssh_user" {
  description = "SSH user provisioned via instance metadata; used by Ansible inventory."
  value       = var.ssh_user
}

output "node_internal_ips" {
  description = "Internal IP per node."
  value       = { for k, _ in local.nodes : k => google_compute_address.internal[k].address }
}

output "node_external_ips" {
  description = "External IP per node (used for SSH from operator and admin UI)."
  value       = { for k, _ in local.nodes : k => google_compute_address.external[k].address }
}

output "node_localities" {
  description = "CRDB locality label per node."
  value       = { for k, v in local.nodes : k => v.locality }
}

output "admin_ui_url" {
  description = "CRDB admin UI on n1 (any node works)."
  value       = "https://${google_compute_address.external["n1"].address}:8080"
}

output "sql_connection_string_root" {
  description = "Root client connection string. Requires the controller-side ansible/certs/ directory."
  value       = "postgresql://root@${google_compute_address.external["n1"].address}:26257/defaultdb?sslmode=verify-full&sslrootcert=ansible/certs/ca.crt&sslcert=ansible/certs/client.root.crt&sslkey=ansible/certs/client.root.key"
  sensitive   = true
}
