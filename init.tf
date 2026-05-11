# --- one-shot cluster init ---------------------------------------------
# Runs `cockroach init` on n1, idempotent via /var/lib/cockroach/.bootstrapped.
resource "null_resource" "cluster_init" {
  depends_on = [null_resource.distribute_certs]

  triggers = {
    n1_instance_id = google_compute_instance.crdb["n1"].instance_id
  }

  connection {
    type        = "ssh"
    host        = google_compute_address.external["n1"].address
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_privkey_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      # wait for the listener to come up
      "for i in $(seq 1 60); do nc -z localhost 26257 && break || sleep 2; done",
      "if [ ! -f /var/lib/cockroach/.bootstrapped ]; then",
      "  sudo -u cockroach /usr/local/bin/cockroach init --certs-dir=/var/lib/cockroach/certs --host=localhost:26257",
      "  sudo touch /var/lib/cockroach/.bootstrapped",
      "fi",
    ]
  }
}

# --- apply the multi-region zone configs -------------------------------
# Re-applies whenever the SQL file changes (via filemd5 trigger).
resource "null_resource" "zone_configs" {
  depends_on = [null_resource.cluster_init]

  triggers = {
    sql_hash = filemd5("${path.module}/sql/zone-configs.sql")
    init_id  = null_resource.cluster_init.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      cd "${path.module}"
      cockroach sql \
        --certs-dir=certs \
        --host=${google_compute_address.external["n1"].address}:26257 \
        --file=sql/zone-configs.sql
    EOT
  }
}
