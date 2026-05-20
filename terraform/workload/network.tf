# Look up the cluster's VPC + subnet by name. The cluster stack creates the
# VPC as "${var.network_name}-vpc" and each per-region subnet as
# "${var.network_name}-${region}". Operator must keep network_name in sync
# between the two stacks (defaults match).
data "google_compute_network" "crdb" {
  name = "${var.network_name}-vpc"
}

data "google_compute_subnetwork" "primary" {
  name   = "${var.network_name}-${var.region}"
  region = var.region
}

# SSH to the workload VM. Targets a workload-specific tag so we don't have to
# touch the cluster stack's existing allow-ssh rule (which targets ["crdb"]).
# Outbound 26257/8080 to the cluster works via the cluster's allow-internal
# rule, which permits any source in the VPC CIDRs to crdb-tagged nodes — the
# workload VM's internal IP is in one of those CIDRs by virtue of sitting in
# the same subnet, so no extra firewall is needed for cluster traffic.
resource "google_compute_firewall" "allow_ssh_workload" {
  name        = "${var.network_name}-allow-ssh-workload"
  network     = data.google_compute_network.crdb.name
  description = "Allow SSH from admin CIDRs into the workload VM."

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.admin_cidrs
  target_tags   = ["crdb-workload"]
}
