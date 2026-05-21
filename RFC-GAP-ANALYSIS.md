# RFC Compatibility — Gap Analysis

Comparison of this repo's `terraform/gcp/` against the conventions used by [`cockroachlabs-field/roach-fleet-commander`](https://github.com/cockroachlabs-field/roach-fleet-commander) (RFC = Roach Fleet Commander), produced by reading RFC's `terraform/aws/` and `terraform/monitoring/` stacks. Use this to decide which of RFC's conventions to adopt if you want this GCP stack to slot in as RFC's GCP module.

## RFC's conventions (reverse-engineered)

**File layout per stack** (one directory = one apply-able unit):

```
terraform/<cloud>/
├── main.tf              # provider, terraform block, VPC + subnets, data sources
├── variables.tf
├── outputs.tf
├── instances.tf         # compute + data volumes
├── nlb.tf               # mandatory load balancer
├── security.tf          # security group + ingress/egress rules
├── peering.tf           # optional monitoring-VPC peering hooks
├── cluster.sh           # plan/apply/destroy wrapper that drives `terraform workspace`
├── terraform.tfvars     # example/default values committed at root
└── .terraform.lock.hcl
```

**Multi-cluster via Terraform workspaces.** `cluster.sh apply my-crdb` does `terraform workspace select my-crdb`, then `terraform apply -var-file=clusters/my-crdb/terraform.tfvars`. State is per-workspace; each cluster is independent.

**Single-region by design.** RFC's "cluster" = N nodes in one region across multiple AZs. Multi-region is not a thing in a single stack — you'd deploy multiple RFC clusters.

**Naming + tagging.** `cluster_name` is required, threaded through every `Name` tag (`${var.cluster_name}-vpc`, `${var.cluster_name}-node-${i}`, etc.). Provider sets default tags `{ deployment = "rfc", application = "cockroachdb", cluster = var.cluster_name }`.

**BYO-VPC toggle.** `create_vpc = true|false` with `vpc_id` + `subnet_ids` for the false branch.

**Ansible inventory output.** One `output "ansible_inventory"` that `jsonencode`s a blob with `nodes[]`, `ssh_user`, `ssh_key_name`, `cluster_name`, `region`, `architecture`, `nlb_dns_name`, `sql_endpoint`, `admin_ui_url`. RFC's TUI / REST API consumes this.

**LB is mandatory.** Always created. Listens on 26257 (SQL, TCP health) + 8080 (admin UI, HTTP `/health` health). Backends = all nodes.

**Monitoring hooks built in.** Three variables (`monitoring_vpc_id`, `monitoring_vpc_cidr`, `monitoring_route_table_id`) flip `peering.tf` on. Separate `terraform/monitoring/` stack stands up VictoriaMetrics + VictoriaLogs and is peered in.

**`crdb_version` is a Terraform variable** passed into Ansible (not buried in Ansible defaults).

**Architecture variable** (`amd64`/`arm64`) with validation, drives AMI selection.

**No remote backend configured.** State is local per workspace.

## Side-by-side

| Dimension | RFC (`terraform/aws/`) | This repo (`terraform/gcp/`) |
|---|---|---|
| **Topology** | Single-region, `node_count` + auto-AZ spread | Multi-region, nested `topology` map (region → zones → count) |
| **Multi-cluster model** | Terraform workspaces + `clusters/<name>/terraform.tfvars` | Single cluster per stack (GCS state); no workspace usage |
| **State backend** | Local per workspace | GCS remote backend (`backend.hcl`) |
| **Entry point** | `cluster.sh plan\|apply\|destroy <cluster>` | `make plan/apply/deploy/destroy` from repo root |
| **Cluster name** | `var.cluster_name` (required, threaded everywhere) | `var.network_name = "crdb"` (prefix only, no per-cluster scope) |
| **Default tags** | Provider `default_tags { deployment, application, cluster }` | None on `google` provider |
| **VPC creation** | `create_vpc` toggle + `vpc_id`/`subnet_ids` for BYO | Always creates |
| **Files** | `main.tf` `variables.tf` `outputs.tf` `instances.tf` `nlb.tf` `security.tf` `peering.tf` `cluster.sh` `terraform.tfvars` | `network.tf` `nodes.tf` `lb.tf` `lb_external.tf` `dns.tf` `outputs.tf` `variables.tf` `providers.tf` `versions.tf` `backend.hcl` |
| **CRDB version** | `var.crdb_version` (Terraform → output → Ansible) | Hard-coded in `ansible/roles/cockroachdb/defaults/main.yml` |
| **Architecture** | `var.architecture` amd64/arm64 → AMI filter | N/A (pins `ubuntu-os-cloud/ubuntu-2204-lts`) |
| **Load balancer** | Mandatory NLB, SQL + admin on different listeners | Two opt-in NLBs (`create_internal_lb`, `create_external_lb`); external puts both ports on one VIP |
| **Health checks** | TCP on 26257 + HTTP `/health` on 8080 | TCP on 26257 only (no admin-UI HC because GCP probers don't trust our self-signed CA) |
| **DNS** | Not in scope | `dns.tf` opt-in via `dns_managed_zone` |
| **DB Console admin user** | Not in scope (TUI-side concern) | `crdb_admin_user` + `crdb_admin_password` Terraform vars |
| **Ansible-inventory contract** | Single `output "ansible_inventory"` (jsonencoded blob) | Multiple typed outputs (`nodes`, `ansible_group_vars`, `internal_lb_ip`, `external_lb_ip`, `dns_records`, `node_*_ips`, ...) consumed by `render.sh` |
| **Monitoring peering** | `var.monitoring_vpc_*` → conditional `peering.tf` | None |
| **TLS cert SAN flow** | Inventory blob — Ansible figures it out | `ansible_group_vars` includes `crdb_lb_ip` + `crdb_external_lb_ip` so cert SANs include LB VIPs |
| **Tests in repo** | `test/` directory with its own jumphost terraform | `TESTING.md` doc only |

## Punch list — what to change to fit RFC

### Cheap / mechanical

1. Add `var.cluster_name` (required, no default) and thread it through every resource `name` and label. Drop the fixed `"crdb-"` prefix.
2. Add `default_labels` to the `google` provider in `providers.tf` (GCP's equivalent of `default_tags`): `{ deployment = "rfc", application = "cockroachdb", cluster = var.cluster_name }`.
3. Promote CRDB version out of `ansible/roles/cockroachdb/defaults/main.yml` into `var.crdb_version`, then surface it in the inventory output.
4. Reshape `outputs.tf` to also emit a single `output "ansible_inventory"` jsonencoded blob matching RFC's schema (`nodes[]`, `ssh_user`, `cluster_name`, `region`, `nlb_dns_name`, `sql_endpoint`, `admin_ui_url`). Keep the existing detailed outputs alongside if `render.sh` still uses them.
5. Add a `cluster.sh` wrapper in `terraform/gcp/` mirroring RFC's `plan|apply|destroy <cluster>` UX, even if it just shells into the Makefile underneath.

### Medium / structural

6. Add `create_vpc` toggle + `vpc_self_link` / `subnet_self_links` variables for the BYO branch (GCE analogs of `vpc_id` / `subnet_ids`).
7. Move from a single-cluster GCS backend assumption to Terraform workspaces (or document why you're keeping GCS — workspace state in GCS is also fine, RFC just hasn't done it).
8. Add `peering.tf` shell with `monitoring_vpc_self_link` / `monitoring_vpc_cidr` variables; default to no-op when empty.
9. Consider folding `dns.tf` and the DB Console admin user vars behind an "RFC compatibility" toggle, or splitting them into a separate file that's clearly marked as a GCP-side extension — RFC users won't expect either.

### Structural / philosophical (worth raising with the author before changing)

10. **The multi-region topology is the biggest mismatch.** RFC's model is "one cluster per region." This stack is "one cluster spanning three regions, with voter constraints baked in." Either:
    - **Conform to RFC's model**: drop the topology map, take `region` + `node_count` + `availability_zones[]`, treat multi-region as "deploy multiple RFC clusters and federate" (loses the zone-configs story).
    - **Extend RFC's model**: keep the topology map as an *optional* shape that triggers multi-region behavior, with `node_count` as the fallback single-region path. Document the extension and ask the author whether they want it upstream.
11. **LB default.** RFC always creates the NLB; `create_external_lb` here defaults to `false`. Decide whether to flip the default for RFC consumers.
12. **Admin-UI health check.** RFC does HTTP `/health` on 8080; this stack skips that because GCP's probers can't trust the self-signed CA. Worth documenting as a known divergence.

## Source pointers

- RFC repo: <https://github.com/cockroachlabs-field/roach-fleet-commander>
- RFC AWS stack: `terraform/aws/` — `main.tf`, `instances.tf`, `nlb.tf`, `security.tf`, `peering.tf`, `outputs.tf`, `variables.tf`, `cluster.sh`
- RFC monitoring stack: `terraform/monitoring/` — same shape, scoped to a single VictoriaMetrics/VictoriaLogs instance
- This repo's stack: `terraform/gcp/` — `network.tf`, `nodes.tf`, `lb.tf`, `lb_external.tf`, `dns.tf`, `outputs.tf`, `variables.tf`
