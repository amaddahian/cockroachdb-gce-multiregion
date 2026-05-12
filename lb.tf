# --- Internal regional load balancer (opt-in) ---------------------------
# Created when var.create_internal_lb = true. Backends are all cluster nodes
# in var.internal_lb_region, grouped per zone. Clients in the VPC connect to
# the forwarding-rule IP on 26257 instead of pinning to a specific node.

locals {
  lb_enabled = var.create_internal_lb
  lb_nodes = local.lb_enabled ? {
    for k, v in local.nodes : k => v if v.region == var.internal_lb_region
  } : {}
  lb_zones = local.lb_enabled ? toset([for k, v in local.lb_nodes : v.zone]) : toset([])
}

resource "google_compute_health_check" "sql" {
  count = local.lb_enabled ? 1 : 0
  name  = "${var.network_name}-sql-hc"

  tcp_health_check {
    port = 26257
  }

  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

# Per-zone unmanaged instance group; backend service references one per zone.
resource "google_compute_instance_group" "lb_zone" {
  for_each = local.lb_zones
  name     = "${var.network_name}-lb-${each.value}"
  zone     = each.value
  network  = google_compute_network.crdb.id

  instances = [
    for k, v in local.lb_nodes :
    google_compute_instance.crdb[k].self_link
    if v.zone == each.value
  ]

  named_port {
    name = "sql"
    port = 26257
  }
}

resource "google_compute_region_backend_service" "sql" {
  count                 = local.lb_enabled ? 1 : 0
  name                  = "${var.network_name}-sql-bes"
  region                = var.internal_lb_region
  protocol              = "TCP"
  load_balancing_scheme = "INTERNAL"
  health_checks         = [google_compute_health_check.sql[0].id]

  dynamic "backend" {
    for_each = google_compute_instance_group.lb_zone
    content {
      group = backend.value.self_link
    }
  }
}

resource "google_compute_forwarding_rule" "sql" {
  count                 = local.lb_enabled ? 1 : 0
  name                  = "${var.network_name}-sql-fr"
  region                = var.internal_lb_region
  load_balancing_scheme = "INTERNAL"
  ip_protocol           = "TCP"
  ports                 = ["26257"]
  network               = google_compute_network.crdb.id
  subnetwork = (
    var.internal_lb_subnetwork != ""
    ? var.internal_lb_subnetwork
    : google_compute_subnetwork.crdb[var.internal_lb_region].id
  )
  backend_service = google_compute_region_backend_service.sql[0].id
  # Multi-region clusters typically need clients in other regions to reach
  # the LB. Without this, only same-region clients can connect to the VIP.
  allow_global_access = true

  lifecycle {
    precondition {
      condition     = !local.lb_enabled || contains([for k, v in var.topology : v.region], var.internal_lb_region)
      error_message = "internal_lb_region (${var.internal_lb_region}) must be one of var.topology[*].region."
    }
  }
}

# GCP health-check probers come from these well-known ranges; allow them to
# reach the SQL port. Unrelated to allow-internal which only opens between
# cluster subnets.
resource "google_compute_firewall" "lb_health_check" {
  count       = local.lb_enabled ? 1 : 0
  name        = "${var.network_name}-allow-lb-hc"
  network     = google_compute_network.crdb.name
  description = "Allow GCP health-check probers to reach SQL port for the internal LB."

  allow {
    protocol = "tcp"
    ports    = ["26257"]
  }

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["crdb"]
}
