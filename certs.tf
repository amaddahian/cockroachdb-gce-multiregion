# --- generate the cluster CA + per-node + root client certs locally ----
# Requires the `cockroach` CLI to be on PATH on the machine running terraform.
# Outputs land in ./certs (gitignored). Per-node certs are renamed to
# certs/node.<id>.{crt,key} so distribute_certs can pick the right pair.
resource "null_resource" "certs" {
  triggers = {
    node_addresses = jsonencode({
      for k, _ in local.nodes : k => {
        internal = google_compute_address.internal[k].address
        external = google_compute_address.external[k].address
      }
    })
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      cd "${path.module}"

      rm -rf certs ca-key
      mkdir -p certs ca-key

      cockroach cert create-ca \
        --certs-dir=certs \
        --ca-key=ca-key/ca.key

      %{for k, v in local.nodes~}
      cockroach cert create-node \
        ${google_compute_address.internal[k].address} \
        ${google_compute_address.external[k].address} \
        crdb-${k} \
        localhost \
        127.0.0.1 \
        --certs-dir=certs \
        --ca-key=ca-key/ca.key
      mv certs/node.crt certs/node.${k}.crt
      mv certs/node.key certs/node.${k}.key
      %{endfor~}

      cockroach cert create-client root \
        --certs-dir=certs \
        --ca-key=ca-key/ca.key
    EOT
  }
}

# --- distribute per-node certs to each VM and start cockroach ----------
# Blocks until SSH is reachable. The startup script's systemd unit has
# ConditionPathExists=node.crt, so once the cert lands we explicitly
# `systemctl start` to bring the node up.
resource "null_resource" "distribute_certs" {
  for_each = local.nodes

  depends_on = [
    null_resource.certs,
    google_compute_instance.crdb,
  ]

  triggers = {
    instance_id = google_compute_instance.crdb[each.key].instance_id
    cert_run    = null_resource.certs.id
  }

  connection {
    type        = "ssh"
    host        = google_compute_address.external[each.key].address
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_privkey_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "until [ -d /var/lib/cockroach/certs ]; do sleep 2; done",
      "sudo chown -R ${var.ssh_user}:${var.ssh_user} /var/lib/cockroach/certs",
    ]
  }

  provisioner "file" {
    source      = "${path.module}/certs/ca.crt"
    destination = "/var/lib/cockroach/certs/ca.crt"
  }

  provisioner "file" {
    source      = "${path.module}/certs/node.${each.key}.crt"
    destination = "/var/lib/cockroach/certs/node.crt"
  }

  provisioner "file" {
    source      = "${path.module}/certs/node.${each.key}.key"
    destination = "/var/lib/cockroach/certs/node.key"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo chown -R cockroach:cockroach /var/lib/cockroach/certs",
      "sudo chmod 700 /var/lib/cockroach/certs",
      "sudo chmod 600 /var/lib/cockroach/certs/node.key",
      "sudo chmod 644 /var/lib/cockroach/certs/node.crt /var/lib/cockroach/certs/ca.crt",
      "sudo systemctl restart cockroach.service",
    ]
  }
}
