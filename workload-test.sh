#!/usr/bin/env bash
# Run `cockroach workload run kv` for ~1 minute against every node of the
# multi-region cluster, via the workload VM. Single-command smoke test.
#
# USAGE
#   ./workload-test.sh                                   # 60s, concurrency 64
#   ./workload-test.sh --duration 5m --concurrency 128
#   make workload-test                                   # via Makefile
#   make workload-test EXTRA="--duration 30s"            # via Makefile w/ args
#
# PRECONDITIONS (the script fails fast if any are missing)
#   - terraform/gcp applied (cluster up)
#   - terraform/workload applied (workload VM up)
#   - cockroach binary at /usr/local/bin/cockroach on the workload VM
#   - certs at ~/certs/{ca.crt,client.root.crt,client.root.key} on the workload VM
# See README "Workload VM (opt-in)" for the one-time install steps.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

TF_DIR="$REPO_ROOT/terraform/gcp"
WL_DIR="$REPO_ROOT/terraform/workload"

# --- args ---
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
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      printf 'ERR unknown option: %q (try --help)\n' "$1" >&2
      exit 1
      ;;
  esac
done

# --- styling (copied from quickstart.sh for visual consistency) ---
red()    { printf "\033[0;31m%s\033[0m\n" "$*" >&2; }
green()  { printf "\033[0;32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[0;33m%s\033[0m\n" "$*"; }
blue()   { printf "\033[1;34m%s\033[0m\n" "$*"; }

step()  { blue ""; blue "==> $*"; }
ok()    { green   "  OK  $*"; }
warn()  { yellow  "  !!  $*"; }
die()   { red     "  ERR $*"; exit 1; }

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

preflight() {
  step "Pre-flight checks"

  command -v terraform >/dev/null 2>&1 || die "terraform not on PATH"
  command -v jq        >/dev/null 2>&1 || die "jq not on PATH (brew install jq)"
  command -v ssh       >/dev/null 2>&1 || die "ssh not on PATH"
  ok "terraform, jq, ssh present"

  # Cluster outputs ---------------------------------------------------------
  NODE_IPS_JSON="$(terraform -chdir="$TF_DIR" output -json node_internal_ips 2>/dev/null || true)"
  [[ -n "$NODE_IPS_JSON" && "$NODE_IPS_JSON" != "null" && "$NODE_IPS_JSON" != "{}" ]] \
    || die "no node_internal_ips from $TF_DIR — is the cluster deployed? (run: make apply)"

  LOCALITIES_JSON="$(terraform -chdir="$TF_DIR" output -json node_localities 2>/dev/null || echo '{}')"
  ok "cluster outputs: $(echo "$NODE_IPS_JSON" | jq -r 'length') nodes"

  # Workload VM outputs -----------------------------------------------------
  WL_IP="$(terraform -chdir="$WL_DIR" output -raw workload_vm_external_ip 2>/dev/null || true)"
  [[ -n "$WL_IP" ]] \
    || die "no workload_vm_external_ip from $WL_DIR — is the workload VM deployed? (run: make workload-apply)"
  ok "workload VM: $WL_IP"

  SSH_USER="$(terraform -chdir="$TF_DIR" output -raw ssh_user 2>/dev/null || echo crdb)"
  ok "ssh user: $SSH_USER"

  # SSH reachability --------------------------------------------------------
  if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" true 2>/dev/null; then
    die "ssh ${SSH_USER}@${WL_IP} failed — check admin_cidrs in terraform/workload/terraform.tfvars covers your egress IP"
  fi
  ok "ssh to workload VM works"

  # cockroach binary on VM --------------------------------------------------
  if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" 'command -v cockroach >/dev/null'; then
    die "cockroach binary missing on workload VM — see README 'Workload VM (opt-in)' for the install snippet"
  fi
  CRDB_VERSION="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" 'cockroach version --build-tag' 2>/dev/null || echo unknown)"
  ok "cockroach on workload VM: $CRDB_VERSION"

  # certs on VM -------------------------------------------------------------
  if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" \
       'test -f ~/certs/ca.crt && test -f ~/certs/client.root.crt && test -f ~/certs/client.root.key'; then
    die "missing certs on workload VM at ~/certs/{ca.crt,client.root.crt,client.root.key} — see README 'Workload VM (opt-in)' for the scp snippet"
  fi
  ok "TLS certs in place on workload VM"
}

# Build one URL per node, in locality-sorted order so log output groups by
# region. Each URL points at the node's internal IP on 26257 with the
# verify-full cert chain. cockroach workload accepts multiple URLs and
# round-robins connections across them.
build_urls() {
  step "Build per-node connection URLs"

  local cert_dir="/home/${SSH_USER}/certs"
  local query="sslmode=verify-full&sslrootcert=${cert_dir}/ca.crt&sslcert=${cert_dir}/client.root.crt&sslkey=${cert_dir}/client.root.key"

  # Pair each node key with its locality+IP so we can sort by locality and
  # produce stable, grouped output. Falls back to key-sort if localities are
  # missing.
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

init_kv() {
  step "cockroach workload init kv (idempotent)"

  # Run init against the first URL only; the table is global once created.
  # init kv uses CREATE TABLE IF NOT EXISTS, so re-runs are safe.
  # shellcheck disable=SC2029  # we want client-side expansion of the URL
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" \
    "cockroach workload init kv $(printf '%q' "${URLS[0]}")" \
    || die "workload init kv failed — check the verify-full cert chain on the workload VM"
  ok "kv schema ready"
}

run_kv() {
  step "cockroach workload run kv (duration=$DURATION, concurrency=$CONCURRENCY)"

  # Pass URLs as separate args via printf %q to handle the query string
  # quoting cleanly across the ssh boundary.
  local quoted_urls=""
  for u in "${URLS[@]}"; do
    quoted_urls+=" $(printf '%q' "$u")"
  done

  # shellcheck disable=SC2029  # we want client-side expansion of $quoted_urls
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WL_IP}" \
    "cockroach workload run kv --duration=${DURATION} --concurrency=${CONCURRENCY} --display-every=10s${quoted_urls}"
}

footer() {
  green ""
  green "Workload run complete."
  echo "  duration         $DURATION"
  echo "  concurrency      $CONCURRENCY"
  echo "  cluster regions  $(echo "$LOCALITIES_JSON" | jq -r '[.[]] | unique | join(", ")')"
  echo "  workload VM      $WL_IP"
  echo ""
  echo "Re-run with a longer window:"
  echo "  $0 --duration 5m --concurrency 128"
}

# --- dispatch ---
preflight
build_urls
init_kv
run_kv
footer
