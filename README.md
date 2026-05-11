# Self-Hosted CockroachDB on GCE: A Multi-Region Terraform Blueprint

> A pragmatic Terraform scaffold for a 5-node, 3-region, secure CockroachDB cluster on Google Compute Engine — wired up with the exact zone configurations you actually want in production.

## Why this project exists

If you go looking for "Terraform for self-hosted CockroachDB on GCE," you will not find much. The CockroachDB repo ships Terraform under `pkg/roachprod/vm/aws/terraform/`, but that targets AWS. The GCE side of `roachprod` is implemented in Go (`pkg/roachprod/vm/gce`) and lives behind the `roachprod` CLI — it is not a piece of infrastructure-as-code you can drop into your own pipeline. The official `cockroachdb/cockroach` Terraform provider is for **CockroachDB Cloud**, not self-hosted instances.

So if you want a self-hosted CRDB cluster on GCE, multi-region, secure-by-default, with declarative zone configs applied at apply-time — you build it. This repo is that build.

## The target topology

We want survivability across three geographic regions: Chicago-ish, Ashburn, and Ohio. GCP's nearest mappings are `us-central1` (Iowa), `us-east4` (Ashburn VA), and `us-east5` (Columbus OH). Five nodes, distributed 2/2/1, exactly matching the voter constraints in the zone config.

| Locality label (in CRDB) | GCP region | Zones used        | Nodes |
| ------------------------ | ---------- | ----------------- | ----- |
| `us-central`             | us-central1 | `us-central1-a`, `us-central1-b` | 2 |
| `us-east-1`              | us-east4    | `us-east4-a`, `us-east4-b`       | 2 |
| `us-east-2`              | us-east5    | `us-east5-a`                     | 1 |

```
                 ┌─────────────────── VPC (global) ──────────────────┐
                 │                                                    │
   us-central1   │  [n1: zone-a]   [n2: zone-b]                       │
   (us-central)  │       \\           //                               │
                 │        \\         //                                │
   us-east4      │  [n3: zone-a]   [n4: zone-b]                       │
   (us-east-1)   │              \\ //                                  │
                 │               X                                    │
   us-east5      │           [n5: zone-a]                             │
   (us-east-2)   │                                                    │
                 └────────────────────────────────────────────────────┘

   5 replicas total. Voters: 2/2/1. Lease preference: us-central > us-east-1 > us-east-2.
```

Note: the CRDB `--locality` labels (`us-central`, `us-east-1`, `us-east-2`) are deliberately distinct from the GCP region names. The zone configs key on the CRDB labels, and we wire those labels at `cockroach start` time via `--locality=cloud=gce,region=<label>,zone=<gce-zone>`.

## Design decisions and the trade-offs behind them

**Region choice.** `us-central1` is the closest GCP region to Chicago (Council Bluffs, Iowa is ~500km from downtown). `us-east4` is Ashburn — the obvious pick. `us-east5` is Columbus, Ohio — newer than `us-east1` but it's the only GCP region actually in Ohio. If you hit `us-east5` quota or capacity issues, `us-east1` (Moncks Corner SC) is a reasonable fallback at the cost of a bit more inter-region latency.

**Why exactly 5 nodes.** With 5 replicas split 2/2/1 across regions, 5 nodes is the minimum that the voter constraint can satisfy. It is not the most resilient — losing any single node in `us-central` or `us-east-1` costs you a voter — but it is the cheapest correct configuration. Scale to 3 nodes per region (9 total) when you want headroom for rolling restarts and zone failures without losing voters.

**Secure by default.** Insecure mode is fine for ten-minute repros, but a multi-region cluster traversing the public internet between GCE regions is not the place to skip TLS. We generate a CA, per-node certs, and a root client cert locally with the `cockroach cert` CLI, then SCP them onto each VM before `cockroach start` is allowed to begin.

**Machine sizing baseline.** `n2-standard-4` with a 250GB `pd-ssd` boot disk matches what `roachprod` reaches for as a sane default (`pkg/roachprod/vm/gce/gcloud.go`). It's enough to run the full `tpcc` workload at low warehouse counts and exercise the cluster for correctness work. Bump to `n2-standard-8`/`n2-standard-16` and 1TB+ for sustained production load — both are single variable changes.

**No load balancer.** We expose per-node IPs as Terraform outputs and let you wire the connection string yourself. A regional internal TCP LB is the right answer once you have a real application topology and care about not pinning clients to specific nodes — but it adds resources, an interaction with health checks, and another knob to tune. Start without; add when you need it.

## Architecture walkthrough

The cluster brings itself up in this order:

1. **Network**: a single global VPC with auto-subnets disabled, plus one `/24` subnet per region. Four firewall rules:
   - `allow-internal`: `26257` + `8080` between the three regional CIDRs (so the cluster gossips and the admin UI is reachable cross-region)
   - `allow-ssh`: `22` from `var.admin_cidrs`
   - `allow-admin-ui`: `8080` from `var.admin_cidrs`
   - `allow-sql-external`: `26257` from `var.admin_cidrs`, so the local `cockroach sql` CLI can apply zone configs.
2. **Static IPs**: 5 internal + 5 external `google_compute_address` reservations, created *before* the VMs. This lets the `--join` string be computed at plan time rather than chasing dynamic addresses post-boot.
3. **VMs**: five `google_compute_instance` resources via `for_each` over a node map (region, zone, locality label). Each gets a 250 GB `pd-ssd` data disk mounted at `/mnt/data1` and a `metadata_startup_script` rendered from `scripts/node-startup.sh.tpl`. The startup script formats the disk, installs the CRDB tarball, and writes a `cockroach.service` systemd unit gated on `ConditionPathExists=/var/lib/cockroach/certs/node.crt` — so the unit stays inert until certs land.
4. **Cert generation**: a `null_resource.certs` runs `cockroach cert create-ca`, then `create-node <internal-ip> <external-ip> crdb-<id> localhost 127.0.0.1` per VM (renaming each pair to `node.<id>.{crt,key}`), then `create-client root`. Output lands in `./certs/` (gitignored).
5. **Cert distribution**: `null_resource.distribute_certs` (one per node) SSHes to each VM, SCPs the matching cert pair plus the CA into `/var/lib/cockroach/certs`, fixes ownership/perms, and runs `systemctl restart cockroach.service` — at which point `ConditionPathExists` is satisfied and CRDB starts.
6. **Cluster init**: `null_resource.cluster_init` SSHes to n1, waits for `nc -z localhost 26257`, and runs `cockroach init` once. A marker file at `/var/lib/cockroach/.bootstrapped` makes this idempotent across re-applies.
7. **Zone configs**: `null_resource.zone_configs` runs `cockroach sql --certs-dir=./certs --host=<n1-external-ip> --file=sql/zone-configs.sql` from your laptop, applying the constraints, voter constraints, and lease preferences described below. Triggered on `filemd5(sql/zone-configs.sql)`, so editing the SQL re-applies on the next `terraform apply`.

## Repo layout

```
terraform-crdb-gcp/
├── README.md                # this file
├── .gitignore               # excludes state, *.tfvars, ./certs, ./ca-key
├── versions.tf              # terraform + google + null + local provider pins
├── providers.tf             # google provider, project from var.project_id
├── variables.tf             # project_id, admin_cidrs, crdb_version, machine_type, ...
├── network.tf               # VPC, 3 regional subnets, 4 firewall rules
├── nodes.tf                 # static IPs + data disks + 5 google_compute_instance
├── certs.tf                 # cockroach cert generation + per-node distribution
├── init.tf                  # cockroach init + zone-config apply
├── outputs.tf               # node IPs, admin UI URL, root SQL connection string
├── terraform.tfvars.example # template — copy to terraform.tfvars
├── scripts/
│   └── node-startup.sh.tpl  # formats /mnt/data1, installs CRDB, writes systemd unit
└── sql/
    └── zone-configs.sql     # the multi-region zone configs (Antigena line is TODO)
```

## The zone configs

The whole reason this repo is shaped the way it is. After init, we apply the following SQL — these are the configs that produce the 2/2/1 voter layout with `us-central` holding the lease preference:

```sql
ALTER DATABASE system CONFIGURE ZONE USING
    range_min_bytes = 134217728,
    range_max_bytes = 536870912,
    gc.ttlseconds = 90000,
    num_replicas = 5,
    num_voters = 5;

ALTER RANGE default CONFIGURE ZONE USING
    range_min_bytes = 134217728,
    range_max_bytes = 536870912,
    gc.ttlseconds = 14400,
    num_replicas = 5,
    num_voters = 5,
    constraints = '{+region=us-central: 2, +region=us-east-1: 2, +region=us-east-2: 1}',
    voter_constraints = '{+region=us-central: 2, +region=us-east-1: 2, +region=us-east-2: 1}',
    lease_preferences = '[[+region=us-central], [+region=us-east-1], [+region=us-east-2]]';

ALTER RANGE liveness CONFIGURE ZONE USING
    range_min_bytes = 134217728, range_max_bytes = 536870912,
    gc.ttlseconds = 600, num_replicas = 5, num_voters = 5;

ALTER RANGE meta CONFIGURE ZONE USING
    range_min_bytes = 134217728, range_max_bytes = 536870912,
    gc.ttlseconds = 3600, num_replicas = 5, num_voters = 5;

ALTER RANGE system CONFIGURE ZONE USING
    range_min_bytes = 134217728, range_max_bytes = 536870912,
    gc.ttlseconds = 90000, num_replicas = 5, num_voters = 5;

ALTER RANGE timeseries CONFIGURE ZONE USING gc.ttlseconds = 14400;

-- TODO: the original ALTER TABLE statement here had its identifier rewritten
-- by an Antigena URL proxy. Replace with the real table name before applying.
-- ALTER TABLE <real.table.name> CONFIGURE ZONE USING gc.ttlseconds = 3600;

ALTER TABLE system.public.replication_constraint_stats CONFIGURE ZONE USING
    range_min_bytes = 134217728, range_max_bytes = 536870912,
    gc.ttlseconds = 600, num_replicas = 5, num_voters = 5;

ALTER TABLE system.public.replication_stats CONFIGURE ZONE USING
    range_min_bytes = 134217728, range_max_bytes = 536870912,
    gc.ttlseconds = 600, num_replicas = 5, num_voters = 5;

ALTER TABLE system.public.span_stats_tenant_boundaries CONFIGURE ZONE USING gc.ttlseconds = 3600;
ALTER TABLE system.public.statement_activity         CONFIGURE ZONE USING gc.ttlseconds = 3600;
ALTER TABLE system.public.statement_statistics       CONFIGURE ZONE USING gc.ttlseconds = 3600;
ALTER TABLE system.public.transaction_activity       CONFIGURE ZONE USING gc.ttlseconds = 3600;
ALTER TABLE system.public.transaction_statistics     CONFIGURE ZONE USING gc.ttlseconds = 3600;
```

> One of the `ALTER TABLE` statements in the source had its identifier replaced by a security-proxy rewriting URL (`https://us01.l.antigena.com/...`). It is left commented out with a TODO — restore the real table name before running for real.

## Quickstart

Prerequisites (all must be on the machine running `terraform apply`):

- `terraform` >= 1.6
- `cockroach` CLI on `PATH` — used by Terraform's `local-exec` for both cert generation and zone-config apply: `brew install cockroachdb/tap/cockroach`
- `gcloud` CLI authenticated with Application Default Credentials: `gcloud auth application-default login`
- A GCP project with billing enabled and the Compute Engine API turned on (`gcloud services enable compute.googleapis.com`)
- An SSH keypair (defaults to `~/.ssh/id_ed25519` / `~/.ssh/id_ed25519.pub`)

Run:

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: project_id, admin_cidrs (your /32 at minimum), ssh_pubkey_path

terraform init
terraform apply
```

What `apply` produces:

- VPC + 3 regional subnets + 4 firewall rules
- 5 static internal + 5 static external IPs
- 5 GCE VMs, each with a 250 GB pd-ssd data disk
- Local `./certs/` directory containing CA + per-node + root client certs
- A live, initialized 5-node multi-region cluster with the zone configs applied

When `apply` finishes, grab the outputs:

```bash
terraform output node_external_ips
terraform output node_internal_ips
terraform output admin_ui_url
terraform output -raw sql_connection_string_root   # marked sensitive
```

## Verification

> For a fuller testing strategy — static checks, SQL sanity tests, plan-time checks, real-apply verification, failure-injection — see [TESTING.md](./TESTING.md).

```bash
N1=$(terraform output -json node_external_ips | jq -r '.n1')

# 5 nodes live, three distinct localities (us-central / us-east-1 / us-east-2)
ssh crdb@$N1 "sudo -u cockroach /usr/local/bin/cockroach node status \
  --certs-dir=/var/lib/cockroach/certs --host=localhost"

# Confirm the zone config landed correctly
cockroach sql --certs-dir=./certs --host=$N1:26257 \
  -e "SHOW ZONE CONFIGURATION FROM RANGE default"

# Quick functional smoke test
URL="postgresql://root@$N1:26257?sslmode=verify-full&sslrootcert=./certs/ca.crt&sslcert=./certs/client.root.crt&sslkey=./certs/client.root.key"
cockroach workload init kv "$URL"
cockroach workload run  kv --duration=30s "$URL"
```

## Roadmap / out of scope

What this repo intentionally does **not** do today:

- No load balancer (per-node IPs only)
- No backup schedule or `BACKUP` configuration
- No Prometheus / Datadog / metrics scraping
- No DNS records — node IPs are ephemeral across recreates
- No tenant / serverless setup
- No autoscaling (CRDB doesn't scale that way anyway, but no group-managed instance group is created either)

Reasonable next steps: regional internal TCP load balancers, a `BACKUP INTO ...` cron, a Prometheus node-exporter sidecar, and a `google_dns_record_set` per region for stable client endpoints.

## License & contributing

Apache-2.0. Pull requests welcome — keep them focused, include the rationale, and please run `terraform fmt` and `terraform validate` before opening.
