# Testing the Cluster: Six Tiers, From Free to ~$36/day

Self-hosted multi-region CockroachDB has a lot of surface area to get wrong: the Terraform itself, the zone-config SQL, the GCP-side IAM and quotas, the actual cluster behavior under failure. There's no single test that catches all of it — but there's a sensible escalation order that finds the cheap bugs first and only spends money on what the cheap tests can't catch.

This document walks through that order. Each tier costs more than the last (in time, in dollars, or both) and catches a different class of bug. Don't pay for tier N+1 until tier N is green.

## Tier 1 — static checks (zero cost, ~30 sec)

The cheapest tests catch the most embarrassing bugs: unbalanced braces, references to resources that don't exist, provider-version drift.

```bash
cd ~/scripts/terraform-crdb-gcp
brew install terraform tflint        # if not already

terraform fmt -check -recursive       # formatting
terraform init                        # provider downloads parse
terraform validate                    # schema + reference checks
tflint --recursive                    # extra lint rules (optional)
```

What this catches: typos in resource refs, missing/wrong attributes, bad `for_each` keys, provider version mismatches, unformatted code. What it misses: anything semantic. `terraform validate` will happily approve a config that points to a project that doesn't exist or a region you don't have quota for.

## Tier 2 — SQL sanity check against a local CRDB (zero cost, ~2 min)

The zone-config SQL is the easiest thing to break and the hardest to spot at apply time — Terraform will dutifully ship a broken `ALTER ZONE` statement to the cluster and only fail when `cockroach sql --file=...` runs at the very end of a 15-minute apply. Catch it locally instead.

The constraint references locality labels (`region=us-central`, `region=us-east-1`, `region=us-east-2`), and CRDB validates that those labels actually exist on cluster nodes — so a single-node demo will reject the constraint immediately. Use `--demo-locality` to give the demo nodes the matching labels:

```bash
cockroach demo --insecure --no-example-database --nodes=5 \
  --demo-locality 'region=us-central:region=us-central:region=us-east-1:region=us-east-1:region=us-east-2' \
  --execute "$(cat sql/zone-configs.sql)"
```

You should see one `CONFIGURE ZONE` line per `ALTER` statement (13 total with the current SQL — the Antigena-rewritten line is commented out). Parse errors, unknown identifiers, or unsatisfiable constraints fail immediately.

## Tier 3 — `terraform plan` against a real GCP project (zero infra cost, ~30 sec)

Plan is free. You don't pay until you `apply`. So run plan against your actual target project to catch the GCP-side bugs that local validation can't:

```bash
cp terraform.tfvars.example terraform.tfvars
# fill in project_id and admin_cidrs

terraform plan -out=plan.tfplan
```

What this catches: project ID typos, IAM/API gaps (Compute API not enabled, ADC not authed), region/zone names invalid for your project, machine-type quota you don't actually have, name collisions with existing resources. Plan will *resolve* every data source and every resource attribute against the live GCP API — anything that requires a real API call will surface here.

## Tier 4 — real apply in a throwaway project (~$1.50/hr while running)

This is the only way to test the bring-up sequence end-to-end: cert generation, distribution, init order, the systemd `ConditionPathExists` gate, the zone-config apply on a real cluster.

Cost math: 5× n2-standard-4 + 5× 250 GB pd-ssd + 5 external IPs ≈ **$1.50/hr (~$36/day)**. Stand it up, run the checks, tear it down.

```bash
terraform apply -auto-approve
# ~15 min: VMs boot, certs distribute, init runs, zone configs apply

N1=$(terraform output -json node_external_ips | jq -r '.n1')

# Check 1: cluster came up, all 5 nodes live with three localities
ssh crdb@$N1 'sudo -u cockroach /usr/local/bin/cockroach node status \
  --certs-dir=/var/lib/cockroach/certs --host=localhost'

# Check 2: localities wired correctly via --locality at start time
cockroach sql --certs-dir=./certs --host=$N1:26257 -e \
  "SELECT node_id, locality FROM crdb_internal.kv_node_status ORDER BY node_id"
# expect: 2× region=us-central, 2× region=us-east-1, 1× region=us-east-2

# Check 3: the SQL we wrote actually landed
cockroach sql --certs-dir=./certs --host=$N1:26257 -e \
  "SHOW ZONE CONFIGURATION FROM RANGE default"
# expect: voter_constraints + lease_preferences match sql/zone-configs.sql verbatim

# Check 4: the constraint produced the expected replica placement
cockroach sql --certs-dir=./certs --host=$N1:26257 -e \
  "SELECT range_id, replicas, replica_localities, lease_holder
   FROM [SHOW RANGES FROM DATABASE defaultdb WITH DETAILS] LIMIT 5"
# expect: 5 replicas each, 2/2/1 spread, lease in us-central

# Check 5: TLS is properly verifying (not just accepting any cert)
cockroach sql --certs-dir=./certs --host=$N1:26257 \
  --url="postgresql://root@$N1:26257?sslmode=verify-full&sslrootcert=./certs/ca.crt&sslcert=./certs/client.root.crt&sslkey=./certs/client.root.key" \
  -e "SELECT 1"

# Check 6: admin UI reachable from your admin_cidr
open "$(terraform output -raw admin_ui_url)"

# Check 7: idempotency — second apply should be a no-op
terraform apply
# expect: "No changes. Your infrastructure matches the configuration."

terraform destroy -auto-approve
```

If any of these fail, the bug is real and the fix needs to land before the next apply. The single most common class of failure here is a chicken-and-egg in the cert-distribution flow: if a node's startup script hasn't reached the `systemctl enable` step before `distribute_certs` tries to SSH in, the SSH provisioner will retry but the eventual `systemctl restart cockroach.service` will fail because the unit doesn't exist yet. The implementation accounts for this with timeouts and remote-exec waits — but it's worth watching the apply log the first time.

## Tier 5 — failure injection (the test that actually validates the design)

Once Tier 4 passes, the *interesting* tests are about whether the topology survives what it's designed to survive. With 5 voters and a majority-of-5 quorum (3 voters needed), the cluster can tolerate losing any 2 of 5 nodes; it loses quorum only when 3 of 5 are down.

The four tests below probe the boundary deliberately — each adds one more failure than the last.

```bash
N3=$(terraform output -json node_external_ips | jq -r '.n3')

# --- Test A: lose 1 node in us-central (4/5 voters → quorum) ---
gcloud compute instances stop crdb-n1 --zone=us-central1-a --quiet
cockroach sql --certs-dir=./certs --host=$N3:26257 -e \
  "CREATE DATABASE IF NOT EXISTS tier5;
   CREATE TABLE IF NOT EXISTS tier5.t (id INT PRIMARY KEY, region STRING);
   INSERT INTO tier5.t VALUES (1, 'wrote-after-n1-down');
   SELECT * FROM tier5.t"
# Expect: write succeeds, table shows row 1.

# --- Test B: also lose n2 (entire us-central down → 3/5 voters → quorum) ---
gcloud compute instances stop crdb-n2 --zone=us-central1-b --quiet
sleep 15  # give liveness time to update
cockroach sql --certs-dir=./certs --host=$N3:26257 -e \
  "INSERT INTO tier5.t VALUES (2, 'wrote-after-us-central-down')"
# Expect: write succeeds. Lease for system ranges has migrated to us-east-1
# per lease_preferences. Verify with:
cockroach sql --certs-dir=./certs --host=$N3:26257 -e \
  "SELECT range_id, lease_holder
   FROM [SHOW RANGES FROM TABLE system.public.replication_constraint_stats WITH DETAILS]"

# --- Test C: also lose n5 (us-east-2 down → 2/5 voters → no quorum) ---
gcloud compute instances stop crdb-n5 --zone=us-east5-a --quiet
sleep 60  # leaderless detection takes ~1 min
cockroach sql --certs-dir=./certs --host=$N3:26257 -e \
  "INSERT INTO tier5.t VALUES (3, 'wrote-after-quorum-loss')"
# Expect: explicit error, NOT infinite hang:
#   ERROR: replica unavailable: ... lost quorum (down: ...) ...
#          replica has been leaderless for 1m0s

# --- Test D: restart n1, verify recovery ---
gcloud compute instances start crdb-n1 --zone=us-central1-a --quiet
sleep 60
cockroach sql --certs-dir=./certs --host=$N3:26257 -e \
  "INSERT INTO tier5.t VALUES (4, 'wrote-after-recovery'); SELECT * FROM tier5.t ORDER BY id"
# Expect: write succeeds. Table shows rows 1, 2, 4 — id=3 from Test C's
# lost-quorum attempt correctly never persisted, demonstrating that CRDB
# preserved transactional atomicity through the failure window.

# Cleanup: restart all stopped nodes before destroy.
gcloud compute instances start crdb-n2 --zone=us-central1-b --quiet
gcloud compute instances start crdb-n5 --zone=us-east5-a --quiet
```

The three things this sequence actually validates: (1) the quorum math (any 2-of-5 tolerable, 3-of-5 not); (2) lease-preferences are honored under failure (leases move *out* of us-central when us-central goes away); (3) atomicity holds across quorum loss (no half-written row from the failed Test C write).

## Tier 6 — automation (only if we'll do this often)

Tiers 1–3 take under a minute combined and have zero ongoing cost. They are an obvious fit for a `scripts/test-static.sh` and a GitHub Actions workflow on every push.

Tier 4 is harder to automate cleanly — it needs a real GCP project and a stable budget. The cheapest automated version is a nightly workflow that picks a `${{ github.run_id }}-test` project, applies, runs Checks 1–7, and destroys. With proper teardown on failure, the cost stays bounded.

Tier 5 is too cluster-state-dependent for unsupervised automation. Run it manually after meaningful topology changes — different region set, different node count, different replica/voter math.

## What to run, and when

| Trigger                                | Tiers       |
| -------------------------------------- | ----------- |
| Every commit                           | 1, 2        |
| Before opening a PR                    | 1, 2, 3     |
| Before merging a topology change       | 1, 2, 3, 4  |
| After merging a topology change        | 5           |
| Quarterly, or after any provider bump  | 1, 2, 3, 4  |

The pattern: cheap things constantly, expensive things deliberately.

## Findings from the first end-to-end run

A real Tier 4 + Tier 5 run against `cockroach-ali` (a permissive GCP project) and `cockroach-ephemeral` (a hardened CRL internal project) surfaced six concrete issues in the scaffold and one in the docs themselves. Documenting them here so the next person doesn't re-discover them.

### Bugs in the scaffold

1. **`set -o pipefail` in `init.tf` remote-exec broke `cluster_init`.** Terraform's `remote-exec` provisioner runs commands through the remote shell, which on Ubuntu is `/bin/sh` (dash). Dash doesn't support `set -o pipefail`. **Fixed**: `init.tf` now uses `set -eu`.

2. **Cert distribution missed `client.root.{crt,key}`.** `cockroach init` requires the root client cert to authenticate the init RPC, even when running on the node itself. The original `certs.tf` only pushed `ca.crt + node.{crt,key}`. **Fixed**: `certs.tf` now pushes `client.root.{crt,key}` too, and chowns/chmods them as the cockroach user.

3. **`zone_configs` raced node-join.** `cluster_init` exits as soon as the first node bootstraps the cluster, but the other 4 nodes may take a few more seconds to register. If `zone_configs` runs immediately, `ALTER ... CONFIGURE ZONE` can fail with `constraint "+region=X" matches no existing nodes` because not every region is represented yet. **Not yet fixed**; needs an `until cockroach node ls --certs-dir=... | wc -l == 5; do sleep 2; done` step before zone_configs runs.

4. **`metadata_startup_script` re-runs on every VM reboot.** GCE re-executes the startup script on each boot by default. Our script isn't truly idempotent on the slow path (apt mirror pulls can take 10+ min), so a spurious reboot mid-deploy can leave Terraform stuck waiting for `/var/lib/cockroach/certs/` to exist while the script is still in `apt-get update`. **Not yet fixed**; needs `--metadata-from-file user-data` style first-boot-only execution, or a marker file at the top of the script that exits early on reboot.

5. **No IAP / OS Login support.** The SSH provisioner assumes external SSH on port 22 from `var.admin_cidrs` works. In projects with `enable-oslogin = true` at the project level, metadata-based SSH keys are ignored — the `crdb` user injected via `metadata.ssh-keys` has no `~/.ssh/authorized_keys`, and SSH auth fails. **Not yet fixed**; would need either a `google_compute_firewall` rule for IAP (`35.235.240.0/20`) plus a `proxy_command`-based connection block, or a switch to OS Login users.

6. **`admin_cidrs` is brittle behind multi-layer NAT.** `ifconfig.me` and `ipify.org` reported a different IP than the one our actual TCP egress used to reach GCE. Different "what's my IP" services are not equivalent — they reflect whichever NAT egress the *HTTP request* happened to hit. The first apply timed out for 5 minutes against a firewall rule that didn't actually cover the source IP of our SSH traffic. **Workaround documented**; if SSH times out and the firewall *looks* right, cross-check your egress IP with `curl -s https://checkip.amazonaws.com` (more reliable than HTTP-side IP services). **Not yet fixed in scaffold**; could optionally auto-detect from a known-good source or accept a wider CIDR.

### Bug in this document

7. **Tier 5 had a quorum-math error.** The earlier draft claimed losing all of us-central (2 nodes) would cause writes to hang. With 5 voters, losing 2 still leaves 3 — that's quorum. Writes still succeed; only the lease holder shifts. The actual quorum-loss boundary is losing **3 of 5** voters, which corresponds to losing us-central (2) plus us-east-2 (1). The Tier 5 section above has been rewritten with the correct boundary and the four-test sequence we actually ran.

### What the run validated (Tier 4 + 5, both green on cockroach-ali)

| Tier 4 check | Result |
|---|---|
| 5 nodes joined with correct localities | ✅ 2× us-central, 2× us-east-1, 1× us-east-2 |
| Zone config matches `sql/zone-configs.sql` | ✅ verbatim |
| Replica placement | ✅ `{1,3,4,5,2}` per range, 2/2/1 spread, lease in us-central |
| TLS verify-full | ✅ root client cert authenticates |
| Idempotent re-apply | ✅ "0 added, 0 changed, 0 destroyed" |

| Tier 5 test | Result |
|---|---|
| A: 1 node down → writes succeed | ✅ |
| B: entire us-central down → writes succeed; leases moved to us-east-1 | ✅ |
| C: us-central + us-east-2 down (3 of 5) → writes fail with `lost quorum` (not infinite hang) | ✅ |
| D: restart 1 node → writes succeed; failed C-write was correctly never persisted | ✅ |
