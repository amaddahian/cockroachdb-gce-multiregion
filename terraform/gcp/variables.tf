variable "project_id" {
  description = "GCP project ID where the cluster is deployed."
  type        = string
}

variable "admin_cidrs" {
  description = "CIDRs allowed to SSH (port 22) and reach the admin UI (port 8080)."
  type        = list(string)
}

variable "ssh_user" {
  description = "Linux user provisioned on each VM via instance metadata; used by Ansible to SSH in."
  type        = string
  default     = "crdb"
}

variable "ssh_pubkey_path" {
  description = "Path to the SSH public key installed on each VM."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
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

# -----------------------------------------------------------------------------
# Cluster topology
# -----------------------------------------------------------------------------

variable "topology" {
  description = <<-EOT
    Per-region cluster topology. Each entry: GCP region, subnet CIDR, CRDB
    locality label, zones to spread nodes across, and how many nodes in this
    region. Default reproduces the canonical 5-node 2/2/1 multi-region setup.

    Node ordinals (n1..nN) are assigned by walking the map in sorted-key order
    and round-robin across each entry's zones. With the default topology this
    produces n1+n2 in us-central1, n3+n4 in us-east4, n5 in us-east5.

    NOTE: changing this away from the default also requires updating
    sql/zone-configs.sql, which references the locality labels +region=us-central,
    +region=us-east-1, +region=us-east-2 and is sized for num_replicas=5.
  EOT
  type = map(object({
    region         = string
    cidr           = string
    locality_label = string
    zones          = list(string)
    node_count     = number
  }))
  default = {
    "us-central" = {
      region         = "us-central1"
      cidr           = "10.10.0.0/24"
      locality_label = "us-central"
      zones          = ["us-central1-a", "us-central1-b"]
      node_count     = 2
    }
    "us-east-1" = {
      region         = "us-east4"
      cidr           = "10.20.0.0/24"
      locality_label = "us-east-1"
      zones          = ["us-east4-a", "us-east4-b"]
      node_count     = 2
    }
    "us-east-2" = {
      region         = "us-east5"
      cidr           = "10.30.0.0/24"
      locality_label = "us-east-2"
      zones          = ["us-east5-a"]
      node_count     = 1
    }
  }

  validation {
    condition = alltrue([
      for k, v in var.topology : v.node_count >= 1 && length(v.zones) >= 1
    ])
    error_message = "Every topology entry needs node_count >= 1 and at least one zone."
  }
}

# -----------------------------------------------------------------------------
# CRDB runtime tuning
# -----------------------------------------------------------------------------

variable "crdb_cache" {
  description = "Fraction of node RAM for the CRDB block cache (--cache=). Sum with crdb_max_sql_memory should stay <= 0.8."
  type        = string
  default     = ".25"
}

variable "crdb_max_sql_memory" {
  description = "Fraction of node RAM for SQL memory pools (--max-sql-memory=)."
  type        = string
  default     = ".25"
}

# -----------------------------------------------------------------------------
# DB Console admin user
# -----------------------------------------------------------------------------

variable "crdb_admin_user" {
  description = "Username to create for DB Console (web UI) login. Set to \"\" to skip user creation entirely (DB Console will reject all logins). NOTE: cannot be \"admin\" or \"root\" — both are built-in role names whose passwords are not editable."
  type        = string
  default     = "consoleadmin"

  validation {
    condition     = !contains(["admin", "root"], lower(var.crdb_admin_user))
    error_message = "crdb_admin_user cannot be 'admin' or 'root' — those are built-in CRDB roles whose passwords are not editable. Try 'consoleadmin', 'dbadmin', or your own name."
  }
}

variable "crdb_admin_password" {
  description = "Password for crdb_admin_user. Empty = auto-generate a 24-char alphanumeric password and stash it at ansible/certs/admin_password.txt on the controller (gitignored, mode 0600). Set explicitly to use your own password."
  type        = string
  default     = ""
  sensitive   = true
}

# -----------------------------------------------------------------------------
# DNS (opt-in)
# -----------------------------------------------------------------------------

variable "dns_managed_zone" {
  description = "Name of an existing google_dns_managed_zone in this project. Empty string disables DNS record creation."
  type        = string
  default     = ""
}

variable "dns_name_template" {
  description = "Per-node FQDN template. {n} is replaced by the node ordinal (n1, n2, ...). Trailing dot required when set."
  type        = string
  default     = "crdb-{n}.cluster.example.com."
}

variable "dns_use_internal_ips" {
  description = "If true, A records resolve to internal IPs (use with private zones). If false, external IPs (public zones)."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Internal regional load balancer (opt-in)
# -----------------------------------------------------------------------------

variable "create_internal_lb" {
  description = "Create a regional internal TCP load balancer in front of the SQL port. Backends are all nodes in var.internal_lb_region."
  type        = bool
  default     = false
}

variable "internal_lb_region" {
  description = "Region for the internal LB. Must be one of var.topology[*].region when create_internal_lb=true."
  type        = string
  default     = ""
}

variable "internal_lb_subnetwork" {
  description = "Optional subnetwork override for the LB forwarding rule. Defaults to the cluster subnet in internal_lb_region."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# External regional load balancer (opt-in)
# -----------------------------------------------------------------------------

variable "create_external_lb" {
  description = "Create a regional EXTERNAL (internet-facing) Network Load Balancer fronting both the SQL port (26257) and the admin UI (8080). Public VIP. Source-restricted to var.admin_cidrs at the firewall (the existing allow-sql-external + allow-admin-ui rules cover client traffic via the LB; an additional rule allows GCP health-check probers)."
  type        = bool
  default     = false
}

variable "external_lb_region" {
  description = "Region for the external LB. Backends are all nodes in that region. Must be one of var.topology[*].region when create_external_lb=true."
  type        = string
  default     = ""
}
