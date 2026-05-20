# Self-Hosted CockroachDB on GCE: A Multi-Region Terraform Blueprint

> A pragmatic Terraform scaffold for a 5-node, 3-region, secure CockroachDB cluster on Google Compute Engine — wired up with the exact zone configurations you actually want in production.

## Why this project exists

If you go looking for "Terraform for self-hosted CockroachDB on GCE," you will not find much. The CockroachDB repo ships Terraform under `pkg/roachprod/vm/aws/terraform/`, but that targets AWS. The GCE side of `roachprod` is implemented in Go (`pkg/roachprod/vm/gce`) and lives behind the `roachprod` CLI — it is not a piece of infrastructure-as-code you can drop into your own pipeline. The official `cockroachdb/cockroach` Terraform provider is for **CockroachDB Cloud**, not self-hosted instances.

So if you want a self-hosted CRDB cluster on GCE, multi-region, secure-by-default, with declarative zone configs applied at apply-time — you build it. This repo is that build.

### When to use this — and when not to

**Good fit:**
- **Learning multi-region CRDB.** The voter constraints, lease preferences, and locality wiring are explicit and inspectable. Stand it up, break it, see what happens.
- **Reference / blueprint for self-hosted deployments.** Fork it, adjust topology, move it to your own project.
- **Dev or research clusters that need real failure-domain spread.** A 5-node cluster across 3 GCP regions costs ~$1.50/hr; cheap enough to spin up and tear down per experiment.
- **A starting point for a more opinionated platform** (your own load balancer story, your own backup story, your own observability stack — see Roadmap below).

**Probably not a fit:**
- **A production OLTP cluster you'll depend on.** No backup automation, no monitoring stack, no alerting, no on-call playbook, no automated recovery, no formal multi-tenant or RBAC strategy. Add those — or use [CockroachDB Cloud](https://cockroachlabs.cloud/) for managed.
- **Cloud-native deployments on Kubernetes.** The CRDB Operator (`cockroach-operator`) is the right tool for K8s; this project is for IaaS.
- **Single-region clusters.** You can shrink `var.topology` to one region, but most of the value of this scaffold (multi-region zone configs, locality plumbing) becomes dead weight.
- **Highly regulated / locked-down environments.** No IAP/OS Login by default, no HSM-backed CA, no Vault integration. Treat the trust model as "operator's laptop is trusted" — fine for research, not for compliance-bound workloads.

## The target topology

We want survivability across three geographic regions: Chicago-ish, Ashburn, and Ohio. GCP's nearest mappings are `us-central1` (Iowa), `us-east4` (Ashburn VA), and `us-east5` (Columbus OH). Five nodes, distributed 2/2/1, exactly matching the voter constraints in the zone config.

| Locality label (in CRDB) | GCP region | Zones used        | Nodes |
| ------------------------ | ---------- | ----------------- | ----- |
| `us-central`             | us-central1 | `us-central1-a`, `us-central1-b` | 2 |
| `us-east-1`              | us-east4    | `us-east4-a`, `us-east4-b`       | 2 |
| `us-east-2`              | us-east5    | `us-east5-a`                     | 1 |

![CockroachDB multi-region topology on GCE](./CRDB-Diagram.png)

Note: the CRDB `--locality` labels (`us-central`, `us-east-1`, `us-east-2`) are deliberately distinct from the GCP region names. The zone configs key on the CRDB labels, and we wire those labels at `cockroach start` time via `--locality=cloud=gce,region=<label>,zone=<gce-zone>`.

## Design decisions and the trade-offs behind them

**Region choice.** `us-central1` is the closest GCP region to Chicago (Council Bluffs, Iowa is ~500km from downtown). `us-east4` is Ashburn — the obvious pick. `us-east5` is Columbus, Ohio — newer than `us-east1` but it's the only GCP region actually in Ohio. If you hit `us-east5` quota or capacity issues, `us-east1` (Moncks Corner SC) is a reasonable fallback at the cost of a bit more inter-region latency.

**Why exactly 5 nodes.** With 5 replicas split 2/2/1 across regions, 5 nodes is the minimum that the voter constraint can satisfy. It is not the most resilient — losing any single node in `us-central` or `us-east-1` costs you a voter — but it is the cheapest correct configuration. Scale to 3 nodes per region (9 total) when you want headroom for rolling restarts and zone failures without losing voters.

**Secure by default.** Insecure mode is fine for ten-minute repros, but a multi-region cluster traversing the public internet between GCE regions is not the place to skip TLS. We generate a CA, per-node certs, and a root client cert locally with the `cockroach cert` CLI, then SCP them onto each VM before `cockroach start` is allowed to begin.

**Machine sizing baseline.** `n2-standard-4` with a 250GB `pd-ssd` boot disk matches what `roachprod` reaches for as a sane default (`pkg/roachprod/vm/gce/gcloud.go`). It's enough to run the full `tpcc` workload at low warehouse counts and exercise the cluster for correctness work. Bump to `n2-standard-8`/`n2-standard-16` and 1TB+ for sustained production load — both are single variable changes.

**Load balancers are opt-in at the Terraform layer.** Per-node internal + external IPs are always created and exposed as outputs so you can wire connection strings directly. Two LBs are available behind feature flags: a regional internal TCP NLB (`var.create_internal_lb`) for in-VPC clients, and a regional external NLB (`var.create_external_lb`) for a single public VIP fronting both SQL and admin UI. They add resources, health-check interactions, and another knob to tune — keep them off when you don't need them. `quickstart.sh` flips its own default to `--lb on` for the external LB (overrideable with `--lb off`) since the most common reason to spin this cluster up at all is "I want to hit it from my laptop"; the manual `make deploy` flow leaves both LBs off unless you set the tfvars.

## Architecture walkthrough

Two halves with a clean seam:

- **Terraform** owns infra: VPC, subnets, firewalls, static IPs, data disks, VMs. That's it.
- **Ansible** owns everything inside the VMs: storage formatting, CRDB install, TLS certs, systemd, cluster init, zone-config apply.

![Deployment pipeline — infrastructure & configuration lifecycle](./Deployment-Pipeline.png)

The five tiers above:

1. **Entry points & initiation** — `make deploy` is the single operator entry point; the Makefile fans out to terraform, render.sh, and ansible-playbook in sequence. Push or PR triggers GitHub Actions CI for static checks.
2. **Provisioning & infrastructure** — Terraform creates the GCP infrastructure (VPC, subnets, firewall rules, 5 GCE VMs, pd-ssd disks, static IPs); state lives in a versioned GCS bucket. `dns.tf` and `lb.tf` add Cloud DNS records and a regional internal NLB when their gating variables are set.
3. **Inventory rendering** — `ansible/inventory/render.sh` reads Terraform outputs and emits the Ansible inventory (`hosts.yml`) plus `group_vars/all.yml` (carrying `crdb_topology`, `crdb_cache`, `crdb_lb_ip`, `crdb_dns_name`).
4. **Deployment & configuration** — the `cockroachdb` Ansible role runs storage → install → certs → service → init → zone_configs against the inventory.
5. **Target cluster & persistent state** — a 5-node multi-region cluster with the topology-driven zone configs, TLS verify-full, and chrony for clock skew.

The same flow as a Mermaid diagram (kept editable in the README source — GitHub renders it natively):

```mermaid
flowchart TD
    classDef opt stroke-dasharray:5 5,fill:#fff8e1,color:#000
    classDef store fill:#e8eaf6,stroke:#3949ab,color:#000
    classDef cluster fill:#e1f5fe,stroke:#0277bd,color:#000

    OP([Operator])
    MK[Makefile<br/>init · apply · inventory · provision · deploy · destroy]

    OP -->|"make deploy"| MK

    MK -->|"1\. terraform apply"| TF[Terraform<br/>network · nodes · outputs<br/>+ dns.tf · lb.tf opt-in]
    MK -->|"2\. ansible/inventory/render.sh"| BR[render.sh<br/>terraform output → YAML]
    MK -->|"3\. ansible-playbook"| ANS[Ansible role: cockroachdb<br/>storage · install · certs ·<br/>service · init · zone_configs]

    TF <-->|state| GCS[("GCS bucket<br/>versioned state<br/>+ rollback tags")]:::store

    TF -->|creates| GCP[GCP infrastructure<br/>VPC · 3 subnets · 4 firewall rules<br/>5 × GCE n2-standard-4<br/>5 × pd-ssd · 10 static IPs<br/><i>opt:</i> Cloud DNS A records<br/><i>opt:</i> regional internal NLB]:::opt

    TF -->|"outputs:<br/>nodes, ansible_group_vars,<br/>internal_lb_ip, dns_records"| BR
    BR -->|"hosts.yml + group_vars/all.yml<br/>(crdb_topology, crdb_cache,<br/>crdb_lb_ip, crdb_dns_name)"| ANS

    ANS -->|configures + bootstraps| CLUSTER[5-node multi-region CockroachDB<br/>2/2/1 voters · lease pref us-central<br/>TLS verify-full · chrony<br/>zone configs templated from topology]:::cluster
    GCP -.provides VMs.-> CLUSTER

    OP -.push or PR.-> CI[GitHub Actions CI<br/>terraform fmt + validate<br/>ansible-lint + syntax-check]
```

Bring-up order:

1. **Network** (`terraform apply`): a global VPC with auto-subnets disabled, one `/24` subnet per region, and four firewall rules:
   - `allow-internal`: `26257` + `8080` between the three regional CIDRs (gossip + cross-region admin UI)
   - `allow-ssh`: `22` from `var.admin_cidrs` (Ansible needs SSH)
   - `allow-admin-ui`: `8080` from `var.admin_cidrs`
   - `allow-sql-external`: `26257` from `var.admin_cidrs` — optional now (Ansible runs SQL on the first node), kept so you can still drive `cockroach sql` from your laptop if you want.
2. **Static IPs** (`terraform apply`): 5 internal + 5 external `google_compute_address` reservations created *before* the VMs, so Ansible can build the `--join` string deterministically.
3. **VMs** (`terraform apply`): five `google_compute_instance` resources via `for_each` over a node map (region, zone, locality label). Each gets a 250 GB `pd-ssd` data disk. No startup script — the GCE guest agent provisions the SSH user from instance metadata, and Ansible takes over from there.
4. **Inventory render** (`make inventory`): `ansible/inventory/render.sh` reads `terraform output -json nodes` and emits `ansible/inventory/hosts.yml` with one entry per node, carrying `ansible_host` (external IP), `private_ip`, `crdb_locality_label`, and `crdb_gce_zone`.
5. **Storage + install** (`make provision` → role tasks `storage.yml`, `install.yml`): formats `/dev/disk/by-id/google-crdb-data` if needed, mounts at `/mnt/data1`, installs `chrony` (CRDB requires <500ms clock skew), creates the `cockroach` user, downloads the pinned CRDB tarball, installs the binary to `/usr/local/bin/cockroach`.
6. **Certs** (role task `certs.yml`): on the first node, generates a CA via `cockroach cert create-ca`; fetches `ca.crt` + `ca.key` back to the controller (`ansible/certs/`, gitignored) as the durable source of truth. Pushes the CA to every node, generates per-node certs in place (SANs: internal IP, external IP, `crdb-<id>`, `localhost`, `127.0.0.1`), generates the root client cert on the first node and distributes it. Removes the CA key from non-first nodes. **Mismatch guard**: if the controller CA is missing but any node already has a `node.crt`, the play aborts loudly rather than silently rotating to a new CA that would break TLS on the next restart.
7. **Service** (role task `service.yml`): renders `cockroach.service` from a Jinja template (with `--locality=cloud=gce,region=<label>,zone=<gce-zone>` per host, `ConditionPathExists=node.crt`, `--join` built from inventory), enables and starts it, waits for the SQL port to accept connections.
8. **Init** (role task `init.yml`): runs `cockroach init` once on the first node, idempotent via the `/var/lib/cockroach/.bootstrapped` marker file plus a substring match on the "already initialized" stderr in case the marker is missing.
9. **Zone configs** (role task `zone_configs.yml`): waits for all expected nodes to register (polls `count(*) FROM crdb_internal.kv_node_status`), renders `sql/zone-configs.sql.j2` from `crdb_topology` (sourced from `terraform output ansible_group_vars`) so `num_replicas`, `voter_constraints`, and `lease_preferences` track the live topology, then runs `cockroach sql --file=…` against the rendered file. All `ALTER … CONFIGURE ZONE` statements are idempotent.

## Repo layout

```
terraform-crdb-gcp/
├── README.md                # this file
├── TESTING.md               # tiered testing strategy
├── Makefile                 # init/plan/apply/inventory/provision/deploy/destroy/clean
├── quickstart.sh            # one-command bring-up wrapper (preflight + deploy + verify)
├── .gitignore
├── terraform/
│   └── gcp/                 # all Terraform for the GCP CockroachDB stack
│       ├── versions.tf      # terraform + google + null + local provider pins
│       ├── providers.tf     # google provider, project from var.project_id
│       ├── variables.tf     # project_id, admin_cidrs, machine_type, disk sizes, ...
│       ├── network.tf       # VPC, 3 regional subnets, 4 firewall rules
│       ├── nodes.tf         # static IPs + data disks + 5 google_compute_instance
│       ├── dns.tf           # optional internal DNS records (per-node A records)
│       ├── lb.tf            # optional internal regional NLB (create_internal_lb)
│       ├── lb_external.tf   # optional external regional NLB (create_external_lb)
│       ├── outputs.tf       # node IPs, admin UI URL, structured `nodes` output for inventory
│       ├── terraform.tfvars.example  # template — copy to terraform.tfvars
│       └── backend.hcl.example       # template — copy to backend.hcl (GCS remote state)
├── ansible/
│   ├── ansible.cfg
│   ├── playbooks/site.yml
│   ├── inventory/
│   │   ├── render.sh        # generates hosts.yml from terraform outputs
│   │   └── hosts.yml        # generated; gitignored
│   ├── certs/               # generated CA + root client cert; gitignored
│   └── roles/cockroachdb/
│       ├── defaults/main.yml
│       ├── handlers/main.yml
│       ├── templates/cockroach.service.j2
│       └── tasks/{main,storage,install,certs,service,init,zone_configs}.yml
└── sql/
    └── zone-configs.sql     # the multi-region zone configs (Antigena line is TODO)
```

## The zone configs

The whole reason this repo is shaped the way it is. After init, the role applies multi-region zone configs to make the 2/2/1 voter layout real. The SQL is **templated from `var.topology`** at provision time (`sql/zone-configs.sql.j2`), so the constraint counts, lease preferences, and replica counts always match the live cluster shape.

For the default 5-node 2/2/1 topology, the rendered SQL contains lines like:

```sql
ALTER RANGE default CONFIGURE ZONE USING
    num_replicas = 5,
    num_voters = 5,
    constraints = '{+region=us-central: 2, +region=us-east-1: 2, +region=us-east-2: 1}',
    voter_constraints = '{+region=us-central: 2, +region=us-east-1: 2, +region=us-east-2: 1}',
    lease_preferences = '[[+region=us-central], [+region=us-east-1], [+region=us-east-2]]';
```

For a 9-node 3/3/3 topology, the same template renders `num_replicas = 9`, `+region=us-central: 3`, etc. — all derived from `var.topology` automatically. See `sql/zone-configs.sql.j2` for the full template (including `gc.ttlseconds` tuning per range, system-table-specific zone configs, etc.).

Lease-preference order follows sorted topology keys. Default keys (`us-central`, `us-east-1`, `us-east-2`) sort alphabetically into the priority you'd want; rename keys if you want a different order.

> The template still has one commented-out `ALTER TABLE` line for a system table whose identifier was URL-rewritten by an Antigena security proxy in the original source. It's left as a TODO — restore the real table name before applying for real if you need that table's TTL configured.

## Quickstart

Prerequisites (all on the machine running `make deploy`):

- `terraform` >= 1.6
- `ansible` >= 2.15 (`pip install ansible` or `brew install ansible`)
- `jq` (used by `inventory/render.sh`)
- `gcloud` CLI authenticated with Application Default Credentials: `gcloud auth application-default login`
- A GCP project with billing enabled and the Compute Engine API turned on (`gcloud services enable compute.googleapis.com`)
- An SSH keypair (defaults to `~/.ssh/id_ed25519` / `~/.ssh/id_ed25519.pub`)
- **No `cockroach` CLI required** on the operator machine — Ansible runs cert generation and SQL on the first node.

### Single-command deploy (recommended)

`quickstart.sh` wraps the full bring-up in one command, with pre-flight checks (terraform/ansible/jq/gcloud installed, ADC ready, SSH key present), auto-detection of your external IP for `admin_cidrs`, idempotent state-bucket bootstrap, and end-to-end verify:

```bash
PROJECT_ID=my-project ./quickstart.sh                        # deploy + verify (external LB ON by default)
PROJECT_ID=my-project ./quickstart.sh deploy --lb off        # deploy without the external LB
PROJECT_ID=my-project ./quickstart.sh deploy --lb-region us-east4  # LB in a non-default region
PROJECT_ID=my-project ./quickstart.sh destroy                # tear down
PROJECT_ID=my-project ./quickstart.sh redeploy --lb off      # destroy + redeploy without LB
```

**Flags** (apply to `deploy` and `redeploy`):

| Flag | Default | Description |
|---|---|---|
| `--lb on\|off` | `on` | Enable/disable the external regional NLB. Upserts `create_external_lb` in `terraform.tfvars` on every run (a `.bak` of the pre-script tfvars is kept). |
| `--lb-region NAME` | `us-central1` | Region for the external LB. Must be one of `var.topology[*].region`. |

Optional env overrides: `SSH_KEY_PATH` (default auto-detects `~/.ssh/id_*.pub`), `ADMIN_CIDRS` (comma-separated, default auto-detects via `checkip.amazonaws.com`), `STATE_LOCATION` (default `us-central1`).

### Step by step (manual flow)

<details>
<summary><strong>Click to expand the manual walkthrough</strong> (skip if you used the quickstart script above)</summary>

<br>

If you want to walk through it manually, in order:

**1. Variables.** Copy the example tfvars (only if it doesn't already exist — `-n` is no-clobber so re-running the quickstart won't wipe your customized file):

```bash
cp -n terraform/gcp/terraform.tfvars.example terraform/gcp/terraform.tfvars
```

Open `terraform/gcp/terraform.tfvars` and set `project_id`, `admin_cidrs` (your `/32` at minimum), and `ssh_pubkey_path` (the example default is `~/.ssh/id_ed25519.pub` — change this if your key is at a different path). The placeholders (`my-gcp-project-id`, `1.2.3.4/32`) will fail at plan time with confusing errors, so don't skip the edit.

**2. Remote state (recommended).** Create a versioned GCS bucket for Terraform state and point Terraform at it. Skip this and Terraform falls back to local state — fine for demos, risky for anything you'll come back to.

```bash
PROJECT_ID=cockroach-ali make bootstrap-state
cp -n terraform/gcp/backend.hcl.example terraform/gcp/backend.hcl
```

Open `terraform/gcp/backend.hcl` and replace `<your-project-id>` with your actual project ID. The result should look like:

```hcl
bucket = "cockroach-ali-tfstate-crdb"
prefix = "crdb-cluster"
```

**3. Deploy.**

```bash
make init
make deploy
```

`make deploy` runs `terraform apply`, renders the Ansible inventory, and runs the playbook — about 10 min on the default 5-node topology.

What `make deploy` produces:

- VPC + 3 regional subnets + 4 firewall rules
- 5 static internal + 5 static external IPs
- 5 GCE VMs with `chrony` and `cockroach` installed and a 250 GB `pd-ssd` data disk mounted at `/mnt/data1`
- `ansible/certs/` (gitignored) on the operator machine containing CA + root client cert
- `ansible/inventory/hosts.yml` (gitignored) for re-runs
- A live, initialized 5-node multi-region cluster with the zone configs applied

Useful outputs (run from the repo root):

```bash
terraform -chdir=terraform/gcp output node_external_ips
terraform -chdir=terraform/gcp output node_internal_ips
terraform -chdir=terraform/gcp output admin_ui_url
terraform -chdir=terraform/gcp output -raw sql_connection_string_root
```

(`sql_connection_string_root` is marked `sensitive`; that's why it needs `-raw`.)

</details>

### DB Console credentials

The Ansible role auto-creates a SQL user (default `consoleadmin`) for the web UI on first deploy. (Default isn't `admin` because `admin` is a built-in CRDB role whose password is not editable — CRDB rejects `ALTER USER admin WITH PASSWORD ...` with `cannot edit admin role`. Same for `root`.) The 24-char password is generated on the controller and stashed at `ansible/certs/admin_password.txt` (gitignored, mode 0600). The quickstart script prints the credentials at the end of `verify`. To read them later:

```bash
cat ansible/certs/admin_password.txt
```

Customize via tfvars:

```hcl
crdb_admin_user     = "alice"               # default: "admin"; set "" to skip user creation
crdb_admin_password = "use-a-real-password" # default: ""; empty = autogenerate
```

Rotate the password:

```bash
make rotate-admin-password   # only works when password is autogenerated; refuses if you set it explicitly
```

The root user (cert-only) is unaffected and continues to authenticate via `client.root.{crt,key}` for SQL CLI access.

Re-running the playbook on its own:

```bash
make provision
make provision EXTRA="--tags certs"
make provision-check
```

`make provision` runs the full role; `EXTRA` passes through to `ansible-playbook` (e.g., `--tags certs` re-runs only the cert tasks); `make provision-check` is a `--check --diff` dry-run.

## Verification

> For a fuller testing strategy — static checks, SQL sanity tests, plan-time checks, real-apply verification, failure-injection — see [TESTING.md](./TESTING.md).

```bash
N1=$(terraform -chdir=terraform/gcp output -json node_external_ips | jq -r '.n1')

# 5 nodes live, three distinct localities (us-central / us-east-1 / us-east-2)
ssh crdb@$N1 "sudo -u cockroach /usr/local/bin/cockroach node status \
  --certs-dir=/var/lib/cockroach/certs --host=localhost"

# Confirm the zone config landed correctly (run on a node — no laptop CLI needed)
ssh crdb@$N1 "sudo -u cockroach /usr/local/bin/cockroach sql \
  --certs-dir=/var/lib/cockroach/certs --host=localhost \
  -e 'SHOW ZONE CONFIGURATION FROM RANGE default'"

# Quick functional smoke test (also from the node)
ssh crdb@$N1 "sudo -u cockroach /usr/local/bin/cockroach workload init kv \
  'postgresql://root@localhost:26257?sslmode=verify-full&sslrootcert=/var/lib/cockroach/certs/ca.crt&sslcert=/var/lib/cockroach/certs/client.root.crt&sslkey=/var/lib/cockroach/certs/client.root.key'"
```

### CA lifecycle

The CA cert and key live at `ansible/certs/{ca.crt,ca.key}` on the operator machine and are the durable source of truth.

- `terraform destroy` does **not** remove them. Recreating a cluster reuses the same CA, so existing client cert material continues to work.
- `make clean-ca` deletes `ansible/certs/` and forces a fresh CA on the next `make provision`. Use this when you actually want to rotate.
- If `ansible/certs/` is missing but VMs already have node certs from a previous deploy, the certs play **aborts loudly** rather than silently regenerating a mismatched CA.

## Configuration

Defaults reproduce the canonical 5-node 2/2/1 multi-region setup. All knobs below are optional — set in `terraform.tfvars` or pass via `-var`.

### Required

| Variable | Description |
|---|---|
| `project_id` | GCP project where the cluster runs. |
| `admin_cidrs` | Source CIDRs allowed for SSH (Ansible) and admin UI access. Use a `/32` or your VPN CIDR. |

### Common (optional)

| Variable | Default | Description |
|---|---|---|
| `ssh_user` | `crdb` | Linux user provisioned via instance metadata. |
| `ssh_pubkey_path` | `~/.ssh/id_ed25519.pub` | Public key installed on each VM. |
| `machine_type` | `n2-standard-4` | GCE shape per node. |
| `boot_disk_size_gb` | `50` | OS disk size. |
| `data_disk_size_gb` | `250` | CRDB store disk (`pd-ssd`). |
| `network_name` | `crdb` | Prefix for VPC + firewall + IP names. |
| `crdb_cache` | `.25` | `--cache=` fraction of node RAM. |
| `crdb_max_sql_memory` | `.25` | `--max-sql-memory=` fraction. Sum with cache should stay ≤0.8. |

CRDB version is set in `ansible/roles/cockroachdb/defaults/main.yml` (`crdb_version: v25.4.0`). Override at provision time with `make provision EXTRA="-e crdb_version=vX.Y.Z"`.

### Topology (optional)

`var.topology` controls cluster size, region selection, and per-region zone spread. The default produces 5 nodes 2/2/1 across `us-central1`, `us-east4`, `us-east5`. To change shape, override the whole map. Node ordinals (`n1..nN`) are assigned by walking the map in sorted-key order.

```hcl
# 9-node 3/3/3 multi-region:
topology = {
  "us-central" = { region = "us-central1", cidr = "10.10.0.0/24",
                   locality_label = "us-central",
                   zones = ["us-central1-a","us-central1-b","us-central1-c"], node_count = 3 }
  "us-east-1"  = { region = "us-east4",    cidr = "10.20.0.0/24",
                   locality_label = "us-east-1",
                   zones = ["us-east4-a","us-east4-b","us-east4-c"], node_count = 3 }
  "us-east-2"  = { region = "us-east5",    cidr = "10.30.0.0/24",
                   locality_label = "us-east-2",
                   zones = ["us-east5-a","us-east5-b","us-east5-c"], node_count = 3 }
}
```

The zone-config SQL (`sql/zone-configs.sql.j2`) is a Jinja template — `num_replicas`, `num_voters`, `constraints`, `voter_constraints`, and `lease_preferences` are derived from `var.topology` at provision time. Changing the topology no longer requires hand-editing the SQL. Lease-preference order follows sorted topology keys (default: `us-central` > `us-east-1` > `us-east-2`); rename your localities if you want a different priority.

### DNS (opt-in)

Set `dns_managed_zone` to an existing `google_dns_managed_zone` in your project to get per-node A records and a round-robin `crdb-any.<zone>` record. The FQDNs are automatically added to each node's TLS cert SANs, so clients can connect with `sslmode=verify-full` against the hostname.

```hcl
dns_managed_zone     = "my-public-zone"
dns_name_template    = "crdb-{n}.cluster.example.com."   # trailing dot required
dns_use_internal_ips = false   # true for private zones
```

`terraform -chdir=terraform/gcp output dns_records` lists the FQDNs once created.

### Internal load balancer (opt-in)

A regional internal TCP NLB in front of the SQL port, backed by all nodes in a single region. Lets in-VPC clients connect to one VIP instead of pinning to a node.

```hcl
create_internal_lb = true
internal_lb_region = "us-central1"   # must be one of var.topology[*].region
```

`terraform -chdir=terraform/gcp output internal_lb_ip` exposes the VIP. From a node:

```bash
cockroach sql --certs-dir=/var/lib/cockroach/certs --host=<LB_IP>:26257 -e 'SELECT 1'
```

### External (public) load balancer (opt-in)

A regional **external** Network Load Balancer with a public IP, fronting **both** the SQL port (26257) and the admin UI (8080). Use this when you want a single public VIP reachable from your laptop or any client outside the VPC, instead of pinning to per-node IPs.

> The Terraform variable defaults to `false` (opt-in), but `quickstart.sh` defaults to `--lb on` — so a quickstart-driven deploy creates this LB unless you pass `--lb off`. The manual `make deploy` flow uses the Terraform default and requires you to enable it via `terraform.tfvars` below.

```hcl
create_external_lb = true
external_lb_region = "us-central1"   # must be one of var.topology[*].region
```

`terraform -chdir=terraform/gcp output external_lb_ip` exposes the public VIP.

Specifics:

- **Same VIP for SQL and admin UI**: one forwarding rule listens on 26257 + 8080. GCP NLBs don't translate ports — backends receive traffic on the original port.
- **TCP health check** on 26257 only. We don't run an HTTPS health check on 8080 because GCP's HTTPS probers don't trust unknown CAs (and ours is self-signed). TCP-on-SQL is sufficient: if CRDB's SQL listener is alive, the admin UI is too.
- **Source restriction**: the existing `allow-sql-external` + `allow-admin-ui` firewall rules already gate 26257/8080 to `var.admin_cidrs` at the instance level. GCP NLBs are pass-through (no source NAT), so backends see the real client IP and that restriction works through the LB. An additional firewall rule allows GCP health-check probers from `35.191.0.0/16` and `130.211.0.0/22`.
- **Cert SANs**: the public LB IP is automatically added to every node's TLS cert SAN list, so `sslmode=verify-full` works against the LB VIP from your laptop.
- **Per-node external IPs are NOT removed** when the external LB is enabled — total public surface = 5 per-node IPs + 1 LB VIP. To minimize public surface, manually drop the `allow-sql-external` and `allow-admin-ui` firewall rules in `network.tf` after the LB is up; the LB still works because its source-IP restriction comes from those rules being present at the instance level. Without them, you'd need to add equivalent rules scoped to LB-only access.

Security trade-off vs internal LB:

| Aspect | Internal LB | External LB |
|---|---|---|
| LB VIP | Private RFC1918 (e.g., `10.10.0.4`) | Public (e.g., `34.x.x.x`) |
| Reachable from your laptop | No (without VPN/peering) | Yes (subject to `admin_cidrs`) |
| Reachable from in-VPC clients | Yes | Yes |
| Net new public attack surface | None | The LB's public IP |
| TLS termination | At nodes (LB is L4 pass-through) | At nodes (LB is L4 pass-through) |
| Auth posture | Same (TLS verify-full + client cert / SQL password) | Same |

Both can be enabled simultaneously — they're independent resources.

## Operations

Common tasks against a running cluster.

### Connect to the cluster

```bash
N1=$(terraform -chdir=terraform/gcp output -json node_external_ips | jq -r '.n1')

# SSH to a node (admin shell)
ssh crdb@$N1

# SQL CLI from your laptop using the controller-side root cert
cockroach sql \
  --certs-dir=ansible/certs \
  --host=$N1:26257
```

The `cockroach` CLI on your laptop is **optional** — the role bakes the binary into every node, so `ssh crdb@$N1 'sudo -u cockroach /usr/local/bin/cockroach sql --certs-dir=/var/lib/cockroach/certs --host=localhost'` always works.

### What's reachable from where (and what "internal" means)

<details>
<summary><strong>Click to expand</strong> — connectivity matrix, why the internal LB isn't reachable from your laptop, and how to get a single VIP from anywhere</summary>

<br>

**"Internal" in GCP terminology means VPC-internal**, not "between cluster nodes." The opt-in internal NLB (`var.create_internal_lb`) creates a VIP at a private RFC1918 address (e.g., `10.10.0.4`) that is only reachable from:

1. **Other VMs inside the same VPC** — a CRDB node, a worker VM you spin up, a bastion. This is the canonical case: apps deployed alongside the cluster connect to the LB instead of pinning to a single node IP.
2. **Networks peered into the VPC** via Cloud VPN, Cloud Interconnect, or VPC peering. If you set up a VPN tunnel from your home/office router to the VPC, your laptop becomes "in" the VPC and gets a route to `10.x.x.x`.
3. **Private Service Connect** and similar Google-managed private endpoints.

Your laptop on home/office WiFi cannot reach `10.10.0.4` directly — there is no route from the public internet into RFC1918 space inside a VPC.

**Reachability matrix (from your laptop, default deploy):**

| Endpoint | Reachable? | Why |
|---|---|---|
| `34.x.x.x:26257` (per-node external IP, SQL) | ✅ Yes | Public IP; firewall opens 26257 to your `admin_cidrs` (`allow-sql-external` rule) |
| `34.x.x.x:8080` (per-node external IP, admin UI) | ✅ Yes | Public IP; `allow-admin-ui` opens 8080 to your `admin_cidrs` |
| `10.x.x.x:26257` (node internal IP) | ❌ No | Private IP, no route from public internet |
| `10.x.x.x:26257` (internal NLB VIP, if enabled) | ❌ No | Same — private IP |

**If you want a single VIP from anywhere (not per-node), pick one:**

| Option | What it gives you | Cost / complexity |
|---|---|---|
| **External NLB** (`var.create_external_lb`) | A public VIP on `34.x.x.x:26257` and `:8080` you can hit from your laptop, fronting all 5 nodes | ~$0.025/hr + a public IP. Adds public attack surface; restricted via firewall to `admin_cidrs`. See Configuration → "External (public) load balancer (opt-in)". |
| **Bastion VM in the VPC + SSH tunnel** | `ssh -L 26257:10.10.0.4:26257 bastion`, then connect locally to `localhost:26257` | One small VM (~$0.02/hr) + SSH plumbing. No new public surface. |
| **Cloud VPN to your home network** | Laptop becomes "in" the VPC; can reach `10.10.0.4` natively | Most setup, most realistic for ongoing use; on-prem-equivalent posture |
| **Status quo: per-node external IPs** | Laptop connects directly to `34.x.x.x:26257` per node | Free; what you have today. Drawback: you pin to a specific node, no LB-style failover |

The **internal NLB is still useful even when your laptop can't reach it** — it's the right answer for app servers / workers running inside the same GCP project. Your laptop typically isn't the SQL-traffic hot path; it's just the operator surface, and per-node external IPs handle that fine.

</details>

### Re-run only part of the playbook

```bash
make provision EXTRA="--tags certs"        # re-issue node certs (e.g., after adding LB IP)
make provision EXTRA="--tags admin_user"   # re-create or update the DB Console user
make provision-check                       # --check --diff dry-run, no changes
```

### Rotate the DB Console password

```bash
make rotate-admin-password                 # only when password is auto-generated
```

Refuses to run if `var.crdb_admin_password` is set explicitly (you manage it; we won't second-guess). Otherwise: deletes the cached file, re-runs the `admin_user` task, prints the new password.

### Rotate the CA

```bash
make clean-ca                              # destructive: deletes ansible/certs/
make destroy                               # remove the cluster (node certs go with it)
PROJECT_ID=… ./quickstart.sh       # fresh deploy regenerates the CA
```

### Trust the CA in your macOS keychain

So the browser stops warning on the admin UI:

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ansible/certs/ca.crt
```

To untrust later: `sudo security delete-certificate -c "Cockroach CA" -t /Library/Keychains/System.keychain`.

### Tear it all down

```bash
PROJECT_ID=… ./quickstart.sh destroy   # removes the 28 GCP resources
make clean-ca                                  # optional: also rotate the CA
gcloud storage rm -r gs://${PROJECT_ID}-tfstate-crdb   # optional: also delete state bucket
```

`terraform destroy` preserves the GCS state bucket and `ansible/certs/` so a future deploy reuses the same CA without rotating client certs. Two extra commands above to wipe each if you actually want a fresh start.

### Workload VM (opt-in)

A small adjunct stack at `terraform/workload/` provisions a single GCE VM in the cluster's primary region (default `us-central1`), on the same VPC, for running `cockroach workload run kv/tpcc/movr/...` against the cluster. It avoids the two problems with running workloads from a cluster node (the node is busy serving its own ranges) or from your laptop (egress bandwidth + cross-region latency). The stack is **completely separate** from the cluster — its own state, its own apply/destroy lifecycle — so you can spin it up only when you need it.

**One-command path** (`./workload.sh` or `make workload`) does terraform apply for the workload VM, idempotently installs the `cockroach` binary + scps certs from `ansible/certs/` (skips if already present), and runs `cockroach workload run kv` against all cluster nodes simultaneously (one URL per node so connections round-robin across all 3 regions):

```bash
# 1. Configure (one-time)
cp -n terraform/workload/terraform.tfvars.example terraform/workload/terraform.tfvars
# edit terraform/workload/terraform.tfvars: project_id + admin_cidrs
cp -n terraform/workload/backend.hcl.example terraform/workload/backend.hcl
# edit terraform/workload/backend.hcl: bucket = "<your-project-id>-tfstate-crdb" (same bucket as the cluster)

# 2. Stand it up + bootstrap + run a 60s smoke test in one shot
make workload                                          # default: 60s, concurrency 64
make workload EXTRA="--duration 5m --concurrency 128"  # longer / heavier
```

Cockroach's own per-`--display-every=10s` progress lines and the final summary (ops/sec, p50/p95/p99) are the result.

**Sub-commands** for finer control:

```bash
./workload.sh up           # terraform apply for the workload stack only
./workload.sh bootstrap    # install cockroach + scp certs (skip if present) — safe to re-run
./workload.sh test         # run cockroach workload run kv (assumes bootstrap already done)
./workload.sh redeploy     # down + up + bootstrap + test
./workload.sh down         # terraform destroy for the workload stack
```

Or via Make:

```bash
make workload-bootstrap    # idempotent install
make workload-test         # just the test (preconditions assumed)
make workload-redeploy     # full reset
make workload-destroy      # terraform destroy (no app teardown needed)
```

Tear it down when you're done — the cluster stack is unaffected:

```bash
./workload.sh down       # or: make workload-destroy
```

Cost: ~\$0.20/hr on top of the cluster's \$1.50/hr.

Notes:
- The workload VM uses the cluster's `root` client cert as a deliberate shortcut. A follow-up could provision a dedicated `workload` SQL user with its own cert if you care about audit separation.
- The cluster's `allow-internal` firewall rule already permits any VPC source to reach nodes on 26257 — the workload VM gets that access by virtue of sitting in one of the cluster's subnets. No cluster-side firewall changes were needed.
- The workload stack's `network_name` var must match the cluster stack's (default `"crdb"`); the workload stack uses `data` sources to look up the existing VPC + subnet by name.
- The `cockroach` binary installed on the workload VM is pinned to the same version (`v25.4.0`) the cluster runs, set at the top of `workload.sh`. Bump there if you rev the cluster.

## Cost

The default 5-node `n2-standard-4` topology costs roughly **\$1.50/hr** while running:

| Component | Count | ~Monthly @ 24/7 | Hourly |
|---|---|---|---|
| `n2-standard-4` VMs | 5 | ~$700 | ~$0.97 |
| `pd-ssd` 250 GB | 5 | ~$170 | ~$0.24 |
| External static IPs | 5 | ~$15 | ~$0.02 |
| Subnet egress (cross-region) | varies | varies | varies |
| GCS state bucket | 1 | <$1 | negligible |

So roughly $36/day if left running. The scaffold is built for spin-up/tear-down workflows; leave it running only as long as you're actively using it.

## Troubleshooting

Issues we've actually hit during testing, in order of how likely you are to encounter them.

### `wait_for_connection` times out on every host

Symptom: 5-minute timeout on every node from the `wait_for_connection` pre-task. Cluster IPs are reachable from a different network but not from yours.

**Cause:** your egress IP isn't in `var.admin_cidrs`. The GCE firewall (`allow-ssh`) only opens port 22 to the listed CIDRs, so SSH connections silently drop.

**Fix:** the `quickstart.sh` flow auto-detects this — it queries `checkip.amazonaws.com`, compares against the CIDRs in `terraform/gcp/terraform.tfvars`, and prepends `<your-ip>/32` if not covered (saving a backup at `terraform/gcp/terraform.tfvars.bak`). The follow-up `terraform apply` updates the firewall rule and the playbook can connect.

If you bypass the script and `make deploy` directly, fix manually:

```bash
sed -i '' "s|admin_cidrs = \[|admin_cidrs = [\"$(curl -s https://checkip.amazonaws.com)/32\", |" terraform/gcp/terraform.tfvars
terraform -chdir=terraform/gcp apply -auto-approve   # ~30s, only firewall rules change
```

### One VM unreachable, others fine

Symptom: 4 of 5 nodes succeed, one (often n2 in us-central1-b) is `UNREACHABLE`. Without the `wait_for_connection` fix the play used to continue without it and the cluster came up 4-of-5; with the fix in place, the slow VM gets up to 5 minutes to come online.

**Cause:** GCE VM boot times vary by zone; the slowest VM occasionally takes ~60–90s to be reachable on SSH.

**Fix:** `wait_for_connection` already handles this in normal cases. If a VM is *genuinely* stuck (e.g., 5 min and still unreachable), reset it: `gcloud compute instances reset crdb-n2 --zone=us-central1-b --project=$PROJECT_ID`, then re-run `make provision`.

### GCE capacity stockout in a region

Symptom: `terraform apply` fails with `STOCKOUT, sub-state:STOCKOUT, resource type:compute` for `n2-standard-4 VM instance is currently unavailable in zone X`.

**Cause:** GCP capacity in that specific zone is exhausted. Common in smaller regions like `us-east5`.

**Fix:** override `var.topology` to use a different zone. Example: `us-east5-a` is full → switch to `us-east5-b` or `us-east5-c`, or fall back to `us-east1` entirely. The variable lets you swap without code changes:

```hcl
topology = {
  # ... us-central, us-east-1 unchanged ...
  "us-east-2" = {
    region         = "us-east1"          # was us-east5
    cidr           = "10.30.0.0/24"
    locality_label = "us-east-2"
    zones          = ["us-east1-b"]
    node_count     = 1
  }
}
```

Then `terraform apply` again. The locality label stays `us-east-2`, so `sql/zone-configs.sql.j2` still works without edits.

### Browser warns "Connection is not private" on the admin UI

Symptom: Chrome/Safari shows `NET::ERR_CERT_AUTHORITY_INVALID` on `https://<node-ip>:8080`.

**Cause:** the admin UI cert is signed by our self-signed CA (`ansible/certs/ca.crt`), which isn't in your browser's trust store.

**Fix:** import the CA into macOS Keychain (see Operations → "Trust the CA in your macOS keychain"). One-time. Or just click through the warning for ad-hoc access — the connection is still TLS-encrypted, you're just acknowledging the CA isn't system-trusted.

### `cannot edit admin role` from the admin_user task

Symptom: Ansible's `Create or update DB Console admin user` task fails (often censored by `no_log: true`).

**Cause:** you set `var.crdb_admin_user = "admin"` (or `"root"`). Both are built-in CRDB roles whose passwords are not editable; CRDB rejects `ALTER USER <them> WITH PASSWORD '...'` with `ERROR: cannot edit admin role` (SQLSTATE 42501).

**Fix:** Terraform variable validation now rejects these at plan time. If you somehow get past it, change to anything else (default is `consoleadmin`).

### Mismatched host keys after recreate

Symptom: `ssh` to a node IP errors with `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` and refuses to connect.

**Cause:** Terraform reserves external IPs by name, so destroyed-and-recreated clusters reuse the same IPs — but each new VM has a fresh SSH host key. Your `~/.ssh/known_hosts` still has the old key for that IP.

**Fix:** drop the old keys before re-deploying:

```bash
for ip in $(terraform output -json node_external_ips | jq -r '.[]'); do
  ssh-keygen -R "$ip" 2>/dev/null
done
```

Or pass `-o StrictHostKeyChecking=accept-new` to the `ssh` invocation to accept the new key without prompting.

### Stale terraform.tfvars after a fresh `cp`

Symptom: `terraform apply` errors with `no file exists at "/Users/.../.ssh/id_ed25519.pub"` or shows `project = "my-gcp-project-id"` in the plan.

**Cause:** you re-ran `cp terraform/gcp/terraform.tfvars.example terraform/gcp/terraform.tfvars` and clobbered your customized file. The example contains placeholders.

**Fix:** the README quickstart now uses `cp -n` (no-clobber) and `quickstart.sh` refuses to deploy if it detects placeholder values still in `terraform.tfvars`. If you hit this manually: re-edit your `project_id`, `admin_cidrs`, and `ssh_pubkey_path` to your real values.

## Roadmap / out of scope

What this repo intentionally does **not** do today:

- No backup schedule or `BACKUP` configuration (operator-driven for now)
- No Prometheus / Datadog / metrics scraping
- No tenant / serverless setup
- No autoscaling

Reasonable next steps: a `BACKUP INTO 'gs://...'` schedule (which would also need a dedicated VM service account with bucket write access), Prometheus node-exporter, IAP-tunneled SSH instead of `admin_cidrs` source ranges, and Cloud Armor in front of the external LB for L7 protection.

## License & contributing

Apache-2.0. Pull requests welcome — keep them focused, include the rationale, and please run `make fmt` and `make validate` before opening.
