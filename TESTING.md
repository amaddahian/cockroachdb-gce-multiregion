# Testing the Cluster: Six Tiers, From Free to ~$36/day

Self-hosted multi-region CockroachDB has a lot of surface area to get wrong: the Terraform itself, the zone-config SQL, the GCP-side IAM and quotas, the actual cluster behavior under failure. There's no single test that catches all of it — but there's a sensible escalation order that finds the cheap bugs first and only spends money on what the cheap tests can't catch.

This document walks through that order. Each tier costs more than the last (in time, in dollars, or both) and catches a different class of bug. Don't pay for tier N+1 until tier N is green.

## Tier 1 — static checks (zero cost, ~30 sec)

The cheapest tests catch the most embarrassing bugs: unbalanced braces, references to resources that don't exist, provider-version drift, malformed YAML, undefined Ansible variables.

```bash
cd ~/scripts/terraform-crdb-gcp
brew install terraform tflint ansible    # if not already
pip install ansible-lint                  # for the lint step

# Terraform (all .tf lives under terraform/gcp/)
terraform -chdir=terraform/gcp fmt -check -recursive
terraform -chdir=terraform/gcp init
terraform -chdir=terraform/gcp validate
tflint --recursive --chdir=terraform/gcp  # optional

# Ansible
cd ansible && ansible-lint                # role + playbook lint
# syntax-check requires an inventory; once you've run terraform apply:
ansible-playbook -i inventory/hosts.yml playbooks/site.yml --syntax-check
```

Or all of the above via `make verify` (after the inventory exists).

What this catches: typos in resource refs, missing/wrong attributes, bad `for_each` keys, provider version mismatches, malformed Jinja, undefined Ansible variables, unformatted code. What it misses: anything semantic. `terraform validate` will happily approve a config that points to a project that doesn't exist or a region you don't have quota for; `ansible-lint` won't catch a wrong `become_user` for the actual remote user.

**Backwards-compat invariant (whenever you touch `var.topology` or `local.nodes`)**: with default vars on a fresh state, `terraform plan` should show **28 resources to add** — VPC + 3 subnets + 4 firewall rules + 5 internal IPs + 5 external IPs + 5 disks + 5 instances. The opt-in DNS and LB resources only appear when their gating variables are set. Any unintended diff against this count means the topology derivation has drifted.

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
cp terraform/gcp/terraform.tfvars.example terraform/gcp/terraform.tfvars
# fill in project_id and admin_cidrs

terraform -chdir=terraform/gcp plan -out=plan.tfplan
```

What this catches: project ID typos, IAM/API gaps (Compute API not enabled, ADC not authed), region/zone names invalid for your project, machine-type quota you don't actually have, name collisions with existing resources. Plan will *resolve* every data source and every resource attribute against the live GCP API — anything that requires a real API call will surface here.

## Tier 4 — real apply in a throwaway project (~$1.50/hr while running)

This is the only way to test the bring-up sequence end-to-end: VM boot, the storage/install role, cert generation and distribution, the systemd `ConditionPathExists` gate, cluster init, and the zone-config apply on a real cluster.

Cost math: 5× n2-standard-4 + 5× 250 GB pd-ssd + 5 external IPs ≈ **$1.50/hr (~$36/day)**. Stand it up, run the checks, tear it down.

```bash
make deploy
# ~10 min terraform apply (mostly VM boot) + ~5 min ansible-playbook
# (storage format, chrony+cockroach install, certs, systemd, init, zone configs).

N1=$(terraform -chdir=terraform/gcp output -json node_external_ips | jq -r '.n1')
NODE_SQL='sudo -u cockroach /usr/local/bin/cockroach sql --certs-dir=/var/lib/cockroach/certs --host=localhost'

# Check 1: cluster came up, all 5 nodes live with three localities
ssh crdb@$N1 'sudo -u cockroach /usr/local/bin/cockroach node status \
  --certs-dir=/var/lib/cockroach/certs --host=localhost'

# Check 2: localities wired correctly via --locality at start time
ssh crdb@$N1 "$NODE_SQL -e \
  'SELECT node_id, locality FROM crdb_internal.kv_node_status ORDER BY node_id'"
# expect: 2× region=us-central, 2× region=us-east-1, 1× region=us-east-2

# Check 3: the SQL we wrote actually landed
ssh crdb@$N1 "$NODE_SQL -e 'SHOW ZONE CONFIGURATION FROM RANGE default'"
# expect: voter_constraints + lease_preferences match sql/zone-configs.sql verbatim

# Check 4: the constraint produced the expected replica placement
ssh crdb@$N1 "$NODE_SQL -e \
  'SELECT range_id, replicas, replica_localities, lease_holder
   FROM [SHOW RANGES FROM DATABASE defaultdb WITH DETAILS] LIMIT 5'"
# expect: 5 replicas each, 2/2/1 spread, lease in us-central

# Check 5: TLS verify-full works against the live admin UI
curl --cacert ansible/certs/ca.crt -fsS "$(terraform -chdir=terraform/gcp output -raw admin_ui_url)/health" && echo OK

# Check 6: admin UI reachable from your admin_cidr in a browser
open "$(terraform -chdir=terraform/gcp output -raw admin_ui_url)"

# Check 7: terraform idempotency — second apply should be a no-op
terraform -chdir=terraform/gcp apply
# expect: "No changes. Your infrastructure matches the configuration."

# Check 8: ansible idempotency — second provision should report all ok/skipped, no changed
make provision
# expect: PLAY RECAP shows changed=0 across every host

# Check 9: cert-mismatch guard — simulate lost controller CA, expect a clean abort
mv ansible/certs ansible/certs.bak
make provision
# expect: play fails with "Existing node.crt found ... but the controller-side CA ... is missing"
mv ansible/certs.bak ansible/certs

# Check 10: workload runs cleanly against all 3 regions (adds the workload VM, ~$0.20/hr)
./workload.sh
# expect: 60s `cockroach workload run kv` finishes with non-zero ops/sec and finite p99.
# Catches: TLS misconfiguration, SQL listener regressions, intra-VPC firewall
# drift, and any change that breaks write throughput. The script installs
# the cockroach binary + scps certs idempotently on the first run.

make destroy
./workload.sh down   # tear down the workload VM separately (its state is independent)
```

If any of these fail, the bug is real and needs to land before the next apply. Watch the first run's Ansible output carefully — most issues surface in the certs role (SAN mismatches, ownership) or service role (missing locality vars in inventory).

## Tier 5 — failure injection (the test that actually validates the design)

Once Tier 4 passes, the *interesting* tests are about whether the topology survives what it's designed to survive. With 5 voters and a majority-of-5 quorum (3 voters needed), the cluster can tolerate losing any 2 of 5 nodes; it loses quorum only when 3 of 5 are down.

The four tests below probe the boundary deliberately — each adds one more failure than the last.

```bash
N3=$(terraform -chdir=terraform/gcp output -json node_external_ips | jq -r '.n3')

# Helper: run cockroach sql on n3 with a SQL string. Avoids quoting headaches.
crdb_sql() {
  ssh crdb@"$N3" "sudo -u cockroach /usr/local/bin/cockroach sql \
    --certs-dir=/var/lib/cockroach/certs --host=localhost -e \"$1\""
}

# --- Test A: lose 1 node in us-central (4/5 voters → quorum) ---
gcloud compute instances stop crdb-n1 --zone=us-central1-a --quiet
crdb_sql "CREATE DATABASE IF NOT EXISTS tier5; \
          CREATE TABLE IF NOT EXISTS tier5.t (id INT PRIMARY KEY, region STRING); \
          INSERT INTO tier5.t VALUES (1, 'wrote-after-n1-down'); \
          SELECT * FROM tier5.t"
# Expect: write succeeds, table shows row 1.

# --- Test B: also lose n2 (entire us-central down → 3/5 voters → quorum) ---
gcloud compute instances stop crdb-n2 --zone=us-central1-b --quiet
sleep 15  # give liveness time to update
crdb_sql "INSERT INTO tier5.t VALUES (2, 'wrote-after-us-central-down')"
# Expect: write succeeds. Lease for system ranges has migrated to us-east-1
# per lease_preferences. Verify with:
crdb_sql "SELECT range_id, lease_holder \
          FROM [SHOW RANGES FROM TABLE system.public.replication_constraint_stats WITH DETAILS]"

# --- Test C: also lose n5 (us-east-2 down → 2/5 voters → no quorum) ---
gcloud compute instances stop crdb-n5 --zone=us-east5-a --quiet
sleep 60  # leaderless detection takes ~1 min
crdb_sql "INSERT INTO tier5.t VALUES (3, 'wrote-after-quorum-loss')"
# Expect: explicit error, NOT infinite hang:
#   ERROR: replica unavailable: ... lost quorum (down: ...) ...
#          replica has been leaderless for 1m0s

# --- Test D: restart n1, verify recovery ---
gcloud compute instances start crdb-n1 --zone=us-central1-a --quiet
sleep 60
crdb_sql "INSERT INTO tier5.t VALUES (4, 'wrote-after-recovery'); \
          SELECT * FROM tier5.t ORDER BY id"
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

## Findings from the original null_resource scaffold

The first end-to-end runs (against `cockroach-ali` and `cockroach-ephemeral`) surfaced six issues with the original Terraform-only scaffold. The Ansible refactor either resolves them by construction or surfaces them more cleanly. Kept here as historical context — and to explain *why* the refactor.

### Resolved by the Ansible refactor

1. **`set -o pipefail` in `init.tf` remote-exec broke `cluster_init`.** Terraform's `remote-exec` runs through `/bin/sh` (dash) on Ubuntu, which doesn't support `pipefail`. **Resolved**: there is no remote-exec anymore; init runs as a regular Ansible task.

2. **Cert distribution missed `client.root.{crt,key}`.** `cockroach init` requires the root client cert. **Resolved**: the certs role distributes the root client cert to every node, with correct ownership/perms.

3. **`zone_configs` raced node-join.** The original `null_resource.zone_configs` could fire before all 5 nodes had registered, hitting `constraint "+region=X" matches no existing nodes`. **Resolved**: the `zone_configs.yml` task polls `crdb_internal.kv_node_status` until `count == groups['cockroachdb'] | length` (60 retries × 2s) before applying.

4. **`metadata_startup_script` re-ran on every VM reboot.** A GCE behavior — startup scripts execute on each boot. **Resolved**: the startup script is gone. Ansible runs only when invoked, never on boot.

### Still applicable

5. **No IAP / OS Login support.** Ansible reaches the VMs over external SSH from `admin_cidrs`. In projects with `enable-oslogin = true`, the `crdb` user injected via `metadata.ssh-keys` has no `~/.ssh/authorized_keys` and Ansible can't connect. Not yet addressed; would need an IAP firewall rule (`35.235.240.0/20`) and an `ansible_ssh_common_args` flag for IAP tunneling, or a switch to OS Login.

6. **`admin_cidrs` is brittle behind multi-layer NAT.** Different "what's my IP" services report different egress IPs depending on which NAT path the HTTP request takes. If Ansible can't SSH to the VMs after `terraform apply`, cross-check your real egress IP with `curl -s https://checkip.amazonaws.com` before assuming anything else is wrong.

### Bug in this document

7. **Tier 5 had a quorum-math error.** An earlier draft claimed losing all of us-central (2 nodes) would cause writes to hang. With 5 voters, losing 2 still leaves 3 — that's quorum. The actual quorum-loss boundary is losing 3 of 5 voters, which corresponds to losing us-central (2) plus us-east-2 (1). Tier 5 above has the corrected sequence.

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
