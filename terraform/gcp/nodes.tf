locals {
  # Walk topology in sorted-key order so n1..nN numbering is stable across
  # re-applies. Each region's nodes are spread round-robin over its zones.
  _topology_keys = sort(keys(var.topology))

  _nodes_list = flatten([
    for locality_key in local._topology_keys : [
      for i in range(var.topology[locality_key].node_count) : {
        region   = var.topology[locality_key].region
        zone     = var.topology[locality_key].zones[i % length(var.topology[locality_key].zones)]
        locality = var.topology[locality_key].locality_label
      }
    ]
  ])

  nodes = {
    for i, n in local._nodes_list : "n${i + 1}" => n
  }
}

resource "google_compute_address" "internal" {
  for_each     = local.nodes
  name         = "crdb-${each.key}-internal"
  subnetwork   = google_compute_subnetwork.crdb[each.value.region].id
  address_type = "INTERNAL"
  region       = each.value.region
}

resource "google_compute_address" "external" {
  for_each = local.nodes
  name     = "crdb-${each.key}-external"
  region   = each.value.region
}

resource "google_compute_disk" "data" {
  for_each = local.nodes
  name     = "crdb-${each.key}-data"
  type     = "pd-ssd"
  zone     = each.value.zone
  size     = var.data_disk_size_gb
}

resource "google_compute_instance" "crdb" {
  for_each     = local.nodes
  name         = "crdb-${each.key}"
  machine_type = var.machine_type
  zone         = each.value.zone
  tags         = ["crdb"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = var.boot_disk_size_gb
      type  = "pd-balanced"
    }
  }

  attached_disk {
    source      = google_compute_disk.data[each.key].self_link
    device_name = "crdb-data"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.crdb[each.value.region].id
    network_ip = google_compute_address.internal[each.key].address

    access_config {
      nat_ip = google_compute_address.external[each.key].address
    }
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${file(pathexpand(var.ssh_pubkey_path))}"
  }

  allow_stopping_for_update = true
}
