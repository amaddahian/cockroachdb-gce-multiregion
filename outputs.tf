output "node_internal_ips" {
  description = "Internal IP per node (used for join)."
  value       = { for k, _ in local.nodes : k => google_compute_address.internal[k].address }
}

output "node_external_ips" {
  description = "External IP per node (used for SSH and the local cockroach CLI)."
  value       = { for k, _ in local.nodes : k => google_compute_address.external[k].address }
}

output "node_localities" {
  description = "Locality label per node."
  value       = { for k, v in local.nodes : k => v.locality }
}

output "admin_ui_url" {
  description = "CRDB admin UI on n1 (use any node)."
  value       = "https://${google_compute_address.external["n1"].address}:8080"
}

output "sql_connection_string_root" {
  description = "Connection string for the root client. Requires ./certs from the local certs directory."
  value       = "postgresql://root@${google_compute_address.external["n1"].address}:26257/defaultdb?sslmode=verify-full&sslrootcert=./certs/ca.crt&sslcert=./certs/client.root.crt&sslkey=./certs/client.root.key"
  sensitive   = true
}
