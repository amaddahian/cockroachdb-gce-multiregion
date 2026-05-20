resource "google_compute_address" "external" {
  name   = "crdb-workload-external"
  region = var.region
}

resource "google_compute_instance" "workload" {
  name         = "crdb-workload"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["crdb-workload"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = var.boot_disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = data.google_compute_subnetwork.primary.id

    access_config {
      nat_ip = google_compute_address.external.address
    }
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${file(pathexpand(var.ssh_pubkey_path))}"
  }

  allow_stopping_for_update = true
}
