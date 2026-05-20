output "workload_vm_external_ip" {
  description = "Public IP of the workload VM. SSH target for the operator."
  value       = google_compute_address.external.address
}

output "workload_vm_internal_ip" {
  description = "Internal (VPC) IP of the workload VM. Useful for SQL connection strings if you want to record the source IP."
  value       = google_compute_instance.workload.network_interface[0].network_ip
}

output "ssh_command" {
  description = "Convenience SSH command. Pass through to the shell to connect."
  value       = "ssh ${var.ssh_user}@${google_compute_address.external.address}"
}

output "ssh_user" {
  description = "Linux user provisioned on the workload VM (matches var.ssh_user). Read by workload.sh."
  value       = var.ssh_user
}
