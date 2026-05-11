locals {
  regions = {
    "us-central1" = "10.10.0.0/24"
    "us-east4"    = "10.20.0.0/24"
    "us-east5"    = "10.30.0.0/24"
  }
}

resource "google_compute_network" "crdb" {
  name                    = "${var.network_name}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
}

resource "google_compute_subnetwork" "crdb" {
  for_each      = local.regions
  name          = "${var.network_name}-${each.key}"
  region        = each.key
  network       = google_compute_network.crdb.id
  ip_cidr_range = each.value
}

resource "google_compute_firewall" "internal" {
  name        = "${var.network_name}-allow-internal"
  network     = google_compute_network.crdb.name
  description = "Allow CRDB SQL (26257) and admin UI (8080) between cluster subnets."

  allow {
    protocol = "tcp"
    ports    = ["26257", "8080"]
  }

  source_ranges = values(local.regions)
  target_tags   = ["crdb"]
}

resource "google_compute_firewall" "ssh" {
  name        = "${var.network_name}-allow-ssh"
  network     = google_compute_network.crdb.name
  description = "Allow SSH from admin CIDRs."

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.admin_cidrs
  target_tags   = ["crdb"]
}

resource "google_compute_firewall" "admin_ui" {
  name        = "${var.network_name}-allow-admin-ui"
  network     = google_compute_network.crdb.name
  description = "Allow CRDB admin UI (8080) from admin CIDRs."

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges = var.admin_cidrs
  target_tags   = ["crdb"]
}

resource "google_compute_firewall" "sql_external" {
  name        = "${var.network_name}-allow-sql-external"
  network     = google_compute_network.crdb.name
  description = "Allow SQL (26257) from admin CIDRs so the local cockroach CLI can apply zone configs."

  allow {
    protocol = "tcp"
    ports    = ["26257"]
  }

  source_ranges = var.admin_cidrs
  target_tags   = ["crdb"]
}
