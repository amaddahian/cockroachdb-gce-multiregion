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

The zone-config SQL is the easiest thing to break and the hardest to spot at apply time — Terraform will dutifully ship a broken `ALTER ZONE` statement to the cluster and only fail when `cockroach sql --file=...` runs at the very end of a 15-minute apply. Catch it locally instead:

```bash
cockroach demo --insecure --no-example-database --nodes=1 \
  --execute "$(cat sql/zone-configs.sql)"
```

This spins up an in-process single-node cluster and applies the SQL. Parse errors and unknown identifiers fail immediately. (A few `ALTER TABLE` statements on system tables behave slightly differently on a single-node demo than on a multi-region cluster; that's fine — we're just looking for syntax problems here, not validating constraint semantics.)

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

Once Tier 4 passes, the *interesting* tests are about whether the topology survives what it's designed to survive. The whole point of 5 voters split 2/2/1 with lease preferences in us-central is to tolerate specific failures — let's verify it does.

```bash
# Survive losing one node in us-central (still 4/5 voters → quorum)
gcloud compute instances stop crdb-n1 --zone=us-central1-a
# Verify writes still succeed via a non-failing region:
N3=$(terraform output -json node_external_ips | jq -r '.n3')
cockroach sql --certs-dir=./certs --host=$N3:26257 -e \
  "CREATE TABLE t (id INT PRIMARY KEY); INSERT INTO t VALUES (1); SELECT * FROM t"

# Survive losing all of us-east5 (still 4/5 voters in central+east-1 → quorum)
gcloud compute instances stop crdb-n5 --zone=us-east5-a
# Cluster should still serve reads and writes; lease for default range
# should still be in us-central per lease_preferences.

# Lose all of us-central (only 3/5 voters left → quorum loss on default range)
gcloud compute instances stop crdb-n1 --zone=us-central1-a
gcloud compute instances stop crdb-n2 --zone=us-central1-b
# Expect: writes hang. This is correct — it's exactly what the topology
# promises. Restart and watch recovery.
gcloud compute instances start crdb-n1 --zone=us-central1-a
gcloud compute instances start crdb-n2 --zone=us-central1-b
```

If any of these *don't* match expectations, either the zone config didn't land the way we think it did, or our mental model of CRDB quorum behavior is wrong — both worth knowing.

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
