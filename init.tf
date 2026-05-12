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
      # `set -o pipefail` is bash-only; remote-exec runs through dash on Ubuntu.
      "set -eu",
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
#
# `cluster_init` exits as soon as n1 bootstraps the cluster, but the other
# nodes can take a few more seconds to register. If we apply the zone configs
# before all nodes are visible, ALTER ... CONFIGURE ZONE fails with
# `constraint "+region=X" matches no existing nodes`. So we wait for the
# expected node count to register before applying.
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

      EXPECTED=${length(local.nodes)}
      HOST=${google_compute_address.external["n1"].address}:26257

      echo "waiting for all $EXPECTED nodes to register with the cluster..."
      for i in $(seq 1 60); do
        COUNT=$(cockroach sql --certs-dir=certs --host=$HOST \
          -e "SELECT count(*) FROM crdb_internal.kv_node_status" \
          --format=tsv 2>/dev/null | tail -n +2 || echo 0)
        if [ "$COUNT" = "$EXPECTED" ]; then
          echo "all $EXPECTED nodes registered"
          break
        fi
        echo "  $COUNT/$EXPECTED registered, waiting..."
        sleep 2
      done

      if [ "$COUNT" != "$EXPECTED" ]; then
        echo "ERROR: only $COUNT/$EXPECTED nodes registered after 2 minutes" >&2
        exit 1
      fi

      cockroach sql \
        --certs-dir=certs \
        --host=$HOST \
        --file=sql/zone-configs.sql
    EOT
  }
}
