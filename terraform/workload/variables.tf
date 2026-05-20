variable "project_id" {
  description = "GCP project where the workload VM lives. Must be the same project as the CRDB cluster stack — the VPC and subnet are looked up by name."
  type        = string
}

variable "admin_cidrs" {
  description = "CIDRs allowed to SSH (port 22) into the workload VM. Same convention as the cluster stack's admin_cidrs."
  type        = list(string)
}

variable "ssh_user" {
  description = "Linux user provisioned on the workload VM via instance metadata. Defaults to the same user the cluster stack uses."
  type        = string
  default     = "crdb"
}

variable "ssh_pubkey_path" {
  description = "Path to the SSH public key installed on the workload VM."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "region" {
  description = "GCP region for the workload VM. Should be the cluster's primary region (where leaseholders default to) for lowest latency."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the workload VM. Must be in var.region."
  type        = string
  default     = "us-central1-a"
}

variable "network_name" {
  description = "Same value as var.network_name in the cluster stack — used to look up the existing VPC (named '<network_name>-vpc') and subnet (named '<network_name>-<region>')."
  type        = string
  default     = "crdb"
}

variable "machine_type" {
  description = "GCE machine type for the workload VM. n2-standard-4 is a sensible default for kv/tpcc generators; bump to n2-standard-8/16 for high-throughput tests."
  type        = string
  default     = "n2-standard-4"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB. The workload VM has no separate data disk."
  type        = number
  default     = 50
}
