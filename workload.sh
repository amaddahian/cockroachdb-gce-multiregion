#!/usr/bin/env bash
# Full workload-VM lifecycle in one script: provision the VM, install the
# cockroach binary + copy certs (idempotent), run `cockroach workload run kv`
# across all cluster nodes, tear down. Mirrors the shape of quickstart.sh.
#
# USAGE
#   ./workload.sh                        # full path: up + bootstrap + test
#   ./workload.sh up                     # terraform apply for the workload stack
#   ./workload.sh bootstrap              # install cockroach + scp certs (skip if present)
#   ./workload.sh test                   # run cockroach workload run kv against all nodes
#   ./workload.sh down                   # terraform destroy for the workload stack
#   ./workload.sh redeploy               # down + up + bootstrap + test
#
# FLAGS (apply to `test` and the default full path)
#   --duration <go-duration>    default: 60s
#   --concurrency <int>         default: 64
#
# PRECONDITION
#   The cluster (terraform/gcp) must already be applied. The workload stack
#   data-sources the cluster's VPC + subnet by name, and `test` reads node
#   IPs from the cluster's terraform output. This script does NOT manage the
#   cluster — use `make deploy` or `./quickstart.sh` for that.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

TF_DIR="$REPO_ROOT/terraform/gcp"
WL_DIR="$REPO_ROOT/terraform/workload"

# Cockroach binary version installed on the workload VM. Must match the
# cluster's binary version (ansible/roles/cockroachdb/defaults/main.yml)
# so client + server protocols stay aligned.
CRDB_VERSION="v25.4.0"
CRDB_ARCH="amd64"

ACTION="${1:-default}"
if [[ $# -gt 0 ]]; then shift; fi

DURATION="60s"
CONCURRENCY="64"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)
      DURATION="${2:-}"
      [[ -n "$DURATION" ]] || { echo 'ERR --duration requires a value' >&2; exit 1; }
      shift 2
      ;;
    --concurrency)
      CONCURRENCY="${2:-}"
      [[ "$CONCURRENCY" =~ ^[0-9]+$ ]] \
        || { printf 'ERR --concurrency must be a positive integer (got: %q)\n' "$CONCURRENCY" >&2; exit 1; }
      shift 2
      ;;
    -h|--help)
      sed -n '2,23p' "$0"
      exit 0
      ;;
    *)
      printf 'ERR unknown option: %q (try --help)\n' "$1" >&2
      exit 1
      ;;
  esac
done

# --- styling (matches quickstart.sh) ---
red()    { printf "\033[0;31m%s\033[0m\n" "$*" >&2; }
green()  { printf "\033[0;32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[0;33m%s\033[0m\n" "$*"; }
blue()   { printf "\033[1;34m%s\033[0m\n" "$*"; }

step()  { blue ""; blue "==> $*"; }
ok()    { green   "  OK  $*"; }
warn()  { yellow  "  !!  $*"; }
die()   { red     "  ERR $*"; exit 1; }

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

# Populated by load_outputs() once it's safe to assume the stacks exist.
WL_IP=""
SSH_USER=""
NODE_IPS_JSON=""
LOCALITIES_JSON=""

# --- preflight (always runs) ----------------------------------------------
preflight_tools() {
  step "Pre-flight: tooling"
  command -v terraform >/dev/null 2>&1 || die "terraform not on PATH"
  command -v jq        >/dev/null 2>&1 || die "jq not on PATH (brew install jq)"
  command -v ssh       >/dev/null 2>&1 || die "ssh not on PATH"
  command -v scp       >/dev/null 2>&1 || die "scp not on PATH"
  ok "terraform, jq, ssh, scp present"
}

preflight_cluster() {
  step "Pre-flight: cluster stack"
  NODE_IPS_JSON="$(terraform -chdir="$TF_DIR" output -json node_internal_ips 2>/dev/null || true)"
  [[ -n "$NODE_IPS_JSON" && "$NODE_IPS_JSON" != "null" && "$NODE_IPS_JSON" != "{}" ]] \
    || die "no node_internal_ips from $TF_DIR — is the cluster deployed? (run: make apply or ./quickstart.sh)"

  LOCALITIES_JSON="$(terraform -chdir="$TF_DIR" output -json node_localities 2>/dev/null || echo '{}')"
  ok "cluster: $(echo "$NODE_IPS_JSON" | jq -r 'length') nodes across $(echo "$LOCALITIES_JSON" | jq -r '[.[]] | unique | length') regions"

  # Cert sources for bootstrap. Always check — even if we're only running
  # `test`, the certs on the VM came from this directory originally.
  for f in ca.crt client.root.crt client.root.key; do
    [[ -f "$REPO_ROOT/ansible/certs/$f" ]] \
      || die "ansible/certs/$f missing on controller — run 'make provision' first to generate the CA + client root cert"
  done
  ok "controller-side certs present in ansible/certs/"
}

# Load TF outputs from the workload stack. Called after `up` (where we know
# the stack is applied) and before `bootstrap`/`test`.
load_workload_outputs() {
  WL_IP="$(terraform -chdir="$WL_DIR" output -raw workload_vm_external_ip 2>/dev/null || true)"
  [[ -n "$WL_IP" ]] \
    || die "no workload_vm_external_ip from $WL_DIR — workload stack not applied? (run: ./workload.sh up)"

  SSH_USER="$(terraform -chdir="$WL_DIR" output -raw ssh_user 2>/dev/null || echo crdb)"
}

# --- actions --------------------------------------------------------------
up() {
  step "Terraform: apply workload stack"

  if [[ ! -d "$WL_DIR/.terraform" ]]; then
    if [[ -f "$WL_DIR/backend.hcl" ]]; then
      terraform -chdir="$WL_DIR" init -backend-config=backend.hcl -input=false >/dev/null
    else
      warn "$WL_DIR/backend.hcl missing — initializing with local state"
      terraform -chdir="$WL_DIR" init -input=false >/dev/null
    fi
    ok "terraform init"
  fi

  if [[ ! -f "$WL_DIR/terraform.tfvars" ]]; then
    die "$WL_DIR/terraform.tfvars missing — copy $WL_DIR/terraform.tfvars.example and edit project_id + admin_cidrs"
  fi

  terraform -chdir="$WL_DIR" apply -auto-approve
  load_workload_outputs
  ok "workload VM up at $WL_IP"
}

bootstrap() {
  step "Bootstrap workload VM (install cockroach + copy certs)"

  load_workload_outputs

  # SSH reachability first so the rest of the checks have a clear failure
  # if the firewall / admin_cidrs are misconfigured.
  if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" true 2>/dev/null; then
    die "ssh ${SSH_USER}@${WL_IP} failed — check admin_cidrs in $WL_DIR/terraform.tfvars covers your egress IP"
  fi
  ok "ssh ${SSH_USER}@${WL_IP}"

  # Skip-if-present: cockroach binary
  if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" 'command -v cockroach >/dev/null'; then
    local installed
    installed="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" 'cockroach version --build-tag' 2>/dev/null || echo unknown)"
    ok "cockroach already installed ($installed) — skipping"
  else
    warn "cockroach not installed — downloading ${CRDB_VERSION} (${CRDB_ARCH})"
    # shellcheck disable=SC2087  # heredoc is intentionally remote-expanded
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" bash -s <<REMOTE
      set -euo pipefail
      wget -qO- https://binaries.cockroachdb.com/cockroach-${CRDB_VERSION}.linux-${CRDB_ARCH}.tgz \
        | sudo tar -xz -C /tmp
      sudo mv /tmp/cockroach-${CRDB_VERSION}.linux-${CRDB_ARCH}/cockroach /usr/local/bin/
      sudo chmod 0755 /usr/local/bin/cockroach
      rm -rf /tmp/cockroach-${CRDB_VERSION}.linux-${CRDB_ARCH}
REMOTE
    ok "installed cockroach ${CRDB_VERSION}"
  fi

  # Skip-if-present: certs
  if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" \
       'test -f ~/certs/ca.crt && test -f ~/certs/client.root.crt && test -f ~/certs/client.root.key'; then
    ok "TLS certs already in place on workload VM — skipping"
  else
    warn "certs missing on workload VM — copying from ansible/certs/"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" 'mkdir -p ~/certs && chmod 700 ~/certs'
    scp -q "${SSH_OPTS[@]}" \
      "$REPO_ROOT/ansible/certs/ca.crt" \
      "$REPO_ROOT/ansible/certs/client.root.crt" \
      "$REPO_ROOT/ansible/certs/client.root.key" \
      "${SSH_USER}@${WL_IP}:~/certs/"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" 'chmod 600 ~/certs/client.root.key'
    ok "copied ca.crt + client.root.{crt,key} to ~/certs/"
  fi
}

# Build the per-node URL list. Stored in the URLS global. Locality-sorted so
# log output groups by region.
build_urls() {
  step "Build per-node connection URLs"
  local cert_dir="/home/${SSH_USER}/certs"
  local query="sslmode=verify-full&sslrootcert=${cert_dir}/ca.crt&sslcert=${cert_dir}/client.root.crt&sslkey=${cert_dir}/client.root.key"

  local pairs
  pairs="$(jq -r --argjson locs "$LOCALITIES_JSON" '
    to_entries
    | map({key: .key, ip: .value, loc: ($locs[.key] // "unknown")})
    | sort_by(.loc, .key)
    | .[] | "\(.loc)\t\(.key)\t\(.ip)"
  ' <<<"$NODE_IPS_JSON")"

  URLS=()
  while IFS=$'\t' read -r loc key ip; do
    URLS+=("postgresql://root@${ip}:26257?${query}")
    ok "  $loc / $key -> $ip"
  done <<<"$pairs"

  [[ "${#URLS[@]}" -gt 0 ]] || die "no URLs assembled — node_internal_ips was empty?"
}

run_test() {
  load_workload_outputs

  # Standalone test path needs to assert the bootstrap state. The default /
  # redeploy path runs bootstrap first, so these checks are belt-and-suspenders
  # there — harmless and fast.
  if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" 'command -v cockroach >/dev/null'; then
    die "cockroach not installed on workload VM — run: ./workload.sh bootstrap"
  fi
  if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" \
       'test -f ~/certs/ca.crt && test -f ~/certs/client.root.crt && test -f ~/certs/client.root.key'; then
    die "certs missing on workload VM — run: ./workload.sh bootstrap"
  fi

  build_urls

  step "cockroach workload init kv (idempotent)"
  # shellcheck disable=SC2029  # we want client-side expansion of the URL
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" \
    "cockroach workload init kv $(printf '%q' "${URLS[0]}")" \
    || die "workload init kv failed — check the verify-full cert chain on the workload VM"
  ok "kv schema ready"

  step "cockroach workload run kv (duration=$DURATION, concurrency=$CONCURRENCY)"
  local quoted_urls=""
  for u in "${URLS[@]}"; do
    quoted_urls+=" $(printf '%q' "$u")"
  done
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" \
    "cockroach workload run kv --duration=${DURATION} --concurrency=${CONCURRENCY} --display-every=10s${quoted_urls}"

  green ""
  green "Workload run complete."
  echo "  duration         $DURATION"
  echo "  concurrency      $CONCURRENCY"
  echo "  cluster regions  $(echo "$LOCALITIES_JSON" | jq -r '[.[]] | unique | join(", ")')"
  echo "  workload VM      $WL_IP"
}

down() {
  step "Terraform: destroy workload stack"
  if [[ ! -d "$WL_DIR/.terraform" ]]; then
    warn "$WL_DIR/.terraform missing — workload stack was never initialized; nothing to destroy"
    return 0
  fi
  terraform -chdir="$WL_DIR" destroy -auto-approve
  ok "workload stack destroyed (cluster stack untouched)"
}

# --- dispatch -------------------------------------------------------------
case "$ACTION" in
  up)
    preflight_tools
    preflight_cluster
    up
    ;;
  bootstrap)
    preflight_tools
    preflight_cluster
    bootstrap
    ;;
  test)
    preflight_tools
    preflight_cluster
    run_test
    ;;
  down)
    preflight_tools
    down
    ;;
  redeploy)
    preflight_tools
    preflight_cluster
    down
    up
    bootstrap
    run_test
    ;;
  default)
    preflight_tools
    preflight_cluster
    up
    bootstrap
    run_test
    ;;
  *)
    cat >&2 <<EOF
Usage: $0 [up|bootstrap|test|down|redeploy] [--duration <go-duration>] [--concurrency <int>]

With no action, runs the full path: up + bootstrap + test.

  up         terraform apply for the workload stack
  bootstrap  install cockroach + scp certs to the workload VM (skip if present)
  test       run cockroach workload run kv across all cluster nodes
  down       terraform destroy for the workload stack
  redeploy   down + up + bootstrap + test

Flags (test / default path):
  --duration <go-duration>   default: 60s
  --concurrency <int>        default: 64
EOF
    exit 1
    ;;
esac
