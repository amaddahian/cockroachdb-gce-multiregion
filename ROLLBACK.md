# Rollback & Recovery

Reference for unwinding code or infrastructure state when something goes wrong. Tags are immortal on GitHub, GCS state is versioned, so every state we care about is recoverable.

## Branches

Only `main` exists (local + remote). Feature branches are deleted after merge — the merge commits on `main` plus the rollback tags below preserve every prior state.

## Rollback tags

Pushed to `origin`, so `git fetch --tags` recovers them even on a fresh clone.

| Tag | SHA | What it preserves |
|---|---|---|
| `pre-ansible-refactor` | `6276178` | The original `null_resource` scaffold — before any of the Ansible work |
| `pre-templating-ci` | `a7ef247` | After Ansible refactor, before SQL templating / GCS state / CI |

## State backup

`gs://cockroach-ali-tfstate-crdb` has object versioning enabled, so every `terraform apply` writes a new generation of `crdb-cluster/default.tfstate`. To recover an older version:

```bash
# List all generations of the state object
gsutil ls -a gs://cockroach-ali-tfstate-crdb/crdb-cluster/default.tfstate

# Copy a specific generation back to the live name
gsutil cp gs://cockroach-ali-tfstate-crdb/crdb-cluster/default.tfstate#<generation> \
          gs://cockroach-ali-tfstate-crdb/crdb-cluster/default.tfstate
```

## Rollback recipes

### Code-only rollback (no infra deployed)

```bash
git reset --hard pre-templating-ci          # or pre-ansible-refactor
git push --force-with-lease origin main     # only if you need to publish the rollback
```

### Code-only rollback (PR-style, preserves history)

```bash
git revert -m 1 f81df10   # reverts the PR #1 merge (templating + GCS + CI)
git revert -m 1 a7ef247   # reverts the Ansible refactor merge (only if needed)
git push origin main
```

### State rollback (after a bad apply)

```bash
gsutil ls -a gs://cockroach-ali-tfstate-crdb/crdb-cluster/default.tfstate
# Pick a generation number from the output, then:
gsutil cp gs://cockroach-ali-tfstate-crdb/crdb-cluster/default.tfstate#<generation> \
          gs://cockroach-ali-tfstate-crdb/crdb-cluster/default.tfstate
terraform -chdir=terraform/gcp refresh   # confirm restored state matches infra
```

### Total rollback (code + infra back to the original blueprint)

```bash
terraform -chdir=terraform/gcp destroy
git reset --hard pre-ansible-refactor
git push --force-with-lease origin main
# Then resume from the original null_resource scaffold
```

---

Tags are pushed and immortal on GitHub. Even if this local repo is wiped, `git fetch --tags` from origin recovers the rollback markers.
