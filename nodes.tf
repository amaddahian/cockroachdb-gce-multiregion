locals {
  nodes = {
    n1 = { region = "us-central1", zone = "us-central1-a", locality = "us-central" }
    n2 = { region = "us-central1", zone = "us-central1-b", locality = "us-central" }
    n3 = { region = "us-east4", zone = "us-east4-a", locality = "us-east-1" }
    n4 = { region = "us-east4", zone = "us-east4-b", locality = "us-east-1" }
    n5 = { region = "us-east5", zone = "us-east5-a", locality = "us-east-2" }
  }

  join_string = join(",", [
    for k, _ in local.nodes : "${google_compute_address.internal[k].address}:26257"
  ])
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

  metadata_startup_script = templatefile("${path.module}/scripts/node-startup.sh.tpl", {
    crdb_version   = var.crdb_version
    locality_label = each.value.locality
    gce_zone       = each.value.zone
    join_string    = local.join_string
    ssh_user       = var.ssh_user
  })

  service_account {
    scopes = ["cloud-platform"]
  }

  allow_stopping_for_update = true
}
