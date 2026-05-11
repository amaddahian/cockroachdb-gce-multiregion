variable "project_id" {
  description = "GCP project ID where the cluster is deployed."
  type        = string
}

variable "admin_cidrs" {
  description = "CIDRs allowed to SSH (port 22) and reach the admin UI (port 8080)."
  type        = list(string)
}

variable "ssh_user" {
  description = "Linux user created on each VM and used for Terraform SSH provisioning."
  type        = string
  default     = "crdb"
}

variable "ssh_pubkey_path" {
  description = "Path to the SSH public key installed on each VM."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_privkey_path" {
  description = "Path to the matching SSH private key Terraform uses to connect."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "crdb_version" {
  description = "CockroachDB release tag (e.g. v25.4.0). Used to fetch the linux-amd64 tarball."
  type        = string
  default     = "v25.4.0"
}

variable "machine_type" {
  description = "GCE machine type for each CRDB node."
  type        = string
  default     = "n2-standard-4"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB."
  type        = number
  default     = 50
}

variable "data_disk_size_gb" {
  description = "Data (store) disk size in GB. pd-ssd."
  type        = number
  default     = 250
}

variable "network_name" {
  description = "Name prefix for the VPC and its resources."
  type        = string
  default     = "crdb"
}
