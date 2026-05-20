# --- External regional load balancer (opt-in) -----------------------------
# Created when var.create_external_lb = true. Public VIP fronting both the
# SQL port (26257) and the admin UI (8080). Single forwarding rule with
# both ports keeps backend selection unified — clients hit the same LB IP
# for either protocol.
#
# Source restriction: the existing allow-sql-external + allow-admin-ui
# firewall rules already gate 26257/8080 to var.admin_cidrs at the
# instance level. GCP NLBs are pass-through (no source NAT) so backends
# see the real client IP, and that restriction works through the LB.
# Per the operator's choice, those per-node rules are NOT removed when
# the external LB is enabled — public surface stays at 5 per-node IPs
# plus the LB VIP. To minimize public surface, drop the per-node SQL
# and admin UI firewall rules in network.tf manually.

locals {
  ext_lb_enabled = var.create_external_lb
  ext_lb_nodes = local.ext_lb_enabled ? {
    for k, v in local.nodes : k => v if v.region == var.external_lb_region
  } : {}
  ext_lb_zones = local.ext_lb_enabled ? toset([for k, v in local.ext_lb_nodes : v.zone]) : toset([])
}

resource "google_compute_address" "external_lb" {
  count        = local.ext_lb_enabled ? 1 : 0
  name         = "${var.network_name}-ext-lb-ip"
  region       = var.external_lb_region
  address_type = "EXTERNAL"
}

# TCP health check on 26257 (SQL). We don't run an HTTPS health check
# on 8080 because GCP's HTTPS probers don't trust unknown CAs, and our
# CA is self-signed. Single TCP-on-SQL check is sufficient: if CRDB's
# SQL listener is alive, the node is healthy enough to also serve the
# admin UI on 8080.
resource "google_compute_region_health_check" "ext" {
  count  = local.ext_lb_enabled ? 1 : 0
  name   = "${var.network_name}-ext-lb-hc"
  region = var.external_lb_region

  tcp_health_check {
    port = 26257
  }

  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

# Per-zone unmanaged instance groups. Backends to the BES below.
resource "google_compute_instance_group" "ext_lb_zone" {
  for_each = local.ext_lb_zones
  name     = "${var.network_name}-ext-lb-${each.value}"
  zone     = each.value
  network  = google_compute_network.crdb.id

  instances = [
    for k, v in local.ext_lb_nodes :
    google_compute_instance.crdb[k].self_link
    if v.zone == each.value
  ]

  named_port {
    name = "sql"
    port = 26257
  }
  named_port {
    name = "admin"
    port = 8080
  }
}

resource "google_compute_region_backend_service" "ext" {
  count                 = local.ext_lb_enabled ? 1 : 0
  name                  = "${var.network_name}-ext-lb-bes"
  region                = var.external_lb_region
  protocol              = "TCP"
  load_balancing_scheme = "EXTERNAL"
  health_checks         = [google_compute_region_health_check.ext[0].id]

  dynamic "backend" {
    for_each = google_compute_instance_group.ext_lb_zone
    content {
      group = backend.value.self_link
    }
  }
}

# One forwarding rule listening on both ports — same VIP serves SQL and
# admin UI. Backends receive traffic on the original port (26257 or 8080)
# because GCP NLBs don't translate ports.
resource "google_compute_forwarding_rule" "ext" {
  count                 = local.ext_lb_enabled ? 1 : 0
  name                  = "${var.network_name}-ext-lb-fr"
  region                = var.external_lb_region
  load_balancing_scheme = "EXTERNAL"
  ip_protocol           = "TCP"
  ports                 = ["26257", "8080"]
  ip_address            = google_compute_address.external_lb[0].address
  backend_service       = google_compute_region_backend_service.ext[0].id

  lifecycle {
    precondition {
      condition     = !local.ext_lb_enabled || contains([for k, v in var.topology : v.region], var.external_lb_region)
      error_message = "external_lb_region (${var.external_lb_region}) must be one of var.topology[*].region."
    }
  }
}

# GCP health-check probers come from these well-known ranges. The
# existing allow-lb-hc firewall (in lb.tf) only opens 26257 and is
# gated on the internal LB; we need a separate rule that includes
# 8080 and is gated on the external LB. When both LBs are enabled,
# both rules exist; the overlap on 26257 is harmless.
resource "google_compute_firewall" "ext_lb_health_check" {
  count       = local.ext_lb_enabled ? 1 : 0
  name        = "${var.network_name}-allow-ext-lb-hc"
  network     = google_compute_network.crdb.name
  description = "Allow GCP external-LB health-check probers to reach SQL + admin UI."

  allow {
    protocol = "tcp"
    ports    = ["26257", "8080"]
  }

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["crdb"]
}
