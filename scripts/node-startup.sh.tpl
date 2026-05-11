#!/usr/bin/env bash
# Startup script rendered by Terraform's templatefile().
#   ${"$"}{crdb_version}   - CRDB release tag (e.g. v25.4.0)
#   ${"$"}{locality_label} - CRDB locality region label (us-central, us-east-1, us-east-2)
#   ${"$"}{gce_zone}       - GCP zone (us-central1-a, etc.)
#   ${"$"}{join_string}    - comma-separated host:port list of all cluster nodes
#   ${"$"}{ssh_user}       - SSH user provisioned for Terraform
set -euxo pipefail

CRDB_VERSION="${crdb_version}"
LOCALITY_LABEL="${locality_label}"
GCE_ZONE="${gce_zone}"
JOIN_STRING="${join_string}"
SSH_USER="${ssh_user}"

PRIVATE_IP=$(curl -fsS -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)

# --- packages -----------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends curl ca-certificates wget tar e2fsprogs

# --- ssh user -----------------------------------------------------------
if ! id "$SSH_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$SSH_USER"
  echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-$SSH_USER
  chmod 0440 /etc/sudoers.d/90-$SSH_USER
fi

# --- format and mount the data disk ------------------------------------
DATA_DEVICE="/dev/disk/by-id/google-crdb-data"
for _ in $(seq 1 30); do
  [ -b "$DATA_DEVICE" ] && break
  sleep 2
done

if ! blkid "$DATA_DEVICE" >/dev/null 2>&1; then
  mkfs.ext4 -F -E lazy_itable_init=0,lazy_journal_init=0,discard "$DATA_DEVICE"
fi

mkdir -p /mnt/data1
if ! grep -q "/mnt/data1" /etc/fstab; then
  echo "$DATA_DEVICE /mnt/data1 ext4 discard,defaults,nofail 0 2" >> /etc/fstab
fi
mount -a

# --- cockroach user + dirs ---------------------------------------------
if ! id cockroach >/dev/null 2>&1; then
  useradd -r -s /bin/false -d /var/lib/cockroach cockroach
fi
mkdir -p /var/lib/cockroach /var/lib/cockroach/certs
chown -R cockroach:cockroach /mnt/data1 /var/lib/cockroach

# --- cockroach binary ---------------------------------------------------
if [ ! -x /usr/local/bin/cockroach ]; then
  cd /tmp
  TARBALL="cockroach-$${CRDB_VERSION}.linux-amd64"
  wget -q "https://binaries.cockroachdb.com/$${TARBALL}.tgz"
  tar -xzf "$${TARBALL}.tgz"
  install -m 0755 "$${TARBALL}/cockroach" /usr/local/bin/cockroach
fi

# --- systemd unit (held off by ConditionPathExists until certs land) ---
cat > /etc/systemd/system/cockroach.service <<UNIT
[Unit]
Description=CockroachDB
Requires=network-online.target
After=network-online.target
ConditionPathExists=/var/lib/cockroach/certs/node.crt

[Service]
Type=notify
User=cockroach
Group=cockroach
WorkingDirectory=/var/lib/cockroach
ExecStart=/usr/local/bin/cockroach start \\
  --certs-dir=/var/lib/cockroach/certs \\
  --store=/mnt/data1 \\
  --listen-addr=0.0.0.0:26257 \\
  --http-addr=0.0.0.0:8080 \\
  --advertise-addr=$${PRIVATE_IP}:26257 \\
  --locality=cloud=gce,region=$${LOCALITY_LABEL},zone=$${GCE_ZONE} \\
  --join=$${JOIN_STRING} \\
  --cache=.25 --max-sql-memory=.25
TimeoutStopSec=300
Restart=always
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable cockroach.service
# Do not start here — Terraform's distribute_certs step starts the service
# explicitly once node.crt is in place. ConditionPathExists keeps the unit
# inert if it tries to fire on its own.
