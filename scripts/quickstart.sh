#!/usr/bin/env bash
# Single-command bring-up (or tear-down) of the multi-region CockroachDB
# cluster on GCE. Wraps the Makefile flow with pre-flight checks and config
# generation. Idempotent — safe to run from a clean laptop or an existing
# checkout.
#
# USAGE
#   PROJECT_ID=my-project ./scripts/quickstart.sh           # deploy + verify
#   PROJECT_ID=my-project ./scripts/quickstart.sh destroy   # tear down
#   PROJECT_ID=my-project ./scripts/quickstart.sh redeploy  # destroy + deploy
#   PROJECT_ID=my-project ./scripts/quickstart.sh verify    # cluster checks
#
# OPTIONAL ENV OVERRIDES
#   SSH_KEY_PATH    public key path; default auto-detects ~/.ssh/id_*.pub
#   ADMIN_CIDRS     comma-separated CIDRs; default auto-detects this host's
#                   external IP via checkip.amazonaws.com and uses /32
#   STATE_LOCATION  GCS bucket region for state; default us-central1
#
# Cluster cost while running: ~$1.50/hr on the default 5-node n2-standard-4
# topology. Run `destroy` when you're done.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ACTION="${1:-deploy}"

# --- styling ---
red()    { printf "\033[0;31m%s\033[0m\n" "$*" >&2; }
green()  { printf "\033[0;32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[0;33m%s\033[0m\n" "$*"; }
blue()   { printf "\033[1;34m%s\033[0m\n" "$*"; }

step()  { blue ""; blue "==> $*"; }
ok()    { green   "  OK  $*"; }
warn()  { yellow  "  !!  $*"; }
die()   { red     "  ERR $*"; exit 1; }

# --- preflight ---
preflight() {
  step "Pre-flight checks"

  : "${PROJECT_ID:?env var PROJECT_ID is required (the GCP project to deploy into)}"
  ok "PROJECT_ID = $PROJECT_ID"

  local missing=()
  for cmd in terraform ansible-playbook jq gcloud; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    red "Missing required tools: ${missing[*]}"
    cat >&2 <<EOF
  Install:
    terraform        brew install terraform
    ansible          brew install ansible        (or: pipx install ansible)
    jq               brew install jq
    gcloud           https://cloud.google.com/sdk/docs/install
EOF
    exit 1
  fi
  ok "all required tools present"

  if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
    die "gcloud Application Default Credentials not configured.
    Run: gcloud auth application-default login"
  fi
  ok "gcloud ADC ready"

  # SSH public key — autodetect if not provided
  if [[ -z "${SSH_KEY_PATH:-}" ]]; then
    for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
      if [[ -f "$k" ]]; then
        SSH_KEY_PATH="$k"
        break
      fi
    done
  fi
  [[ -n "${SSH_KEY_PATH:-}" && -f "$SSH_KEY_PATH" ]] || die "no SSH public key found.
    Set SSH_KEY_PATH or generate one:  ssh-keygen -t ed25519"
  ok "SSH public key: $SSH_KEY_PATH"

  # Always detect this host's current external IP — we use it both to seed
  # admin_cidrs on a fresh tfvars and to verify-and-fix coverage on an
  # existing tfvars (see ensure_egress_covered below).
  CURRENT_EGRESS_IP="$(curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "$CURRENT_EGRESS_IP" ]]; then
    ok "current egress IP: $CURRENT_EGRESS_IP"
  else
    warn "couldn't auto-detect external IP via checkip.amazonaws.com — egress check will be skipped"
  fi

  # Admin CIDRs for the case when terraform.tfvars doesn't yet exist.
  if [[ -z "${ADMIN_CIDRS:-}" ]]; then
    [[ -n "$CURRENT_EGRESS_IP" ]] || die "couldn't auto-detect external IP. Set ADMIN_CIDRS=\"a.b.c.d/32\" explicitly."
    ADMIN_CIDRS="$CURRENT_EGRESS_IP/32"
  fi
  ok "admin CIDRs (used if creating new tfvars): $ADMIN_CIDRS"

  # Render ADMIN_CIDRS as a quoted, comma-separated HCL list
  ADMIN_CIDRS_HCL=$(echo "$ADMIN_CIDRS" | tr ',' '\n' | awk 'NF{printf "\"%s\", ", $0}' | sed 's/, $//')

  STATE_LOCATION="${STATE_LOCATION:-us-central1}"
  STATE_BUCKET="${PROJECT_ID}-tfstate-crdb"
  ok "state bucket: gs://$STATE_BUCKET (location: $STATE_LOCATION)"
}

# --- bootstrap state bucket (idempotent) ---
bootstrap_state() {
  step "Bootstrap GCS state bucket"
  if gcloud storage buckets describe "gs://$STATE_BUCKET" --format="value(name)" >/dev/null 2>&1; then
    ok "bucket gs://$STATE_BUCKET already exists"
  else
    gcloud storage buckets create "gs://$STATE_BUCKET" \
      --project="$PROJECT_ID" \
      --location="$STATE_LOCATION" \
      --uniform-bucket-level-access >/dev/null
    ok "created gs://$STATE_BUCKET"
  fi
  gcloud storage buckets update "gs://$STATE_BUCKET" --versioning >/dev/null
  ok "versioning on"
}

# --- write backend.hcl + terraform.tfvars (preserve customizations) ---
configure() {
  step "Configure backend.hcl + terraform.tfvars"

  if [[ -f backend.hcl ]]; then
    ok "backend.hcl exists (preserved)"
  else
    cat > backend.hcl <<EOF
bucket = "$STATE_BUCKET"
prefix = "crdb-cluster"
EOF
    ok "wrote backend.hcl"
  fi

  if [[ -f terraform.tfvars ]]; then
    if grep -qE 'my-gcp-project-id|"1\.2\.3\.4/32"' terraform.tfvars; then
      die "terraform.tfvars contains placeholder values. Remove it (rm terraform.tfvars)
    and re-run, or edit it manually to fix project_id / admin_cidrs / ssh_pubkey_path."
    fi
    ok "terraform.tfvars exists (preserved)"
  else
    cat > terraform.tfvars <<EOF
project_id  = "$PROJECT_ID"
admin_cidrs = [$ADMIN_CIDRS_HCL]

ssh_user        = "crdb"
ssh_pubkey_path = "$SSH_KEY_PATH"

machine_type      = "n2-standard-4"
boot_disk_size_gb = 50
data_disk_size_gb = 250
EOF
    ok "wrote terraform.tfvars"
  fi

  ensure_egress_covered
}

# Verify that this host's current egress IP is covered by at least one CIDR
# in admin_cidrs. If not, prepend <ip>/32 (preserves existing entries so
# other networks keep working). This is the recurring footgun: every
# laptop-network change (VPN, WiFi, ISP rotation) silently breaks SSH.
ensure_egress_covered() {
  [[ -n "${CURRENT_EGRESS_IP:-}" ]] || { warn "skipping egress check (no current IP)"; return 0; }

  local cidrs
  cidrs=$(awk -F'[][]' '/^[[:space:]]*admin_cidrs/{print $2}' terraform.tfvars \
            | tr -d ' "' | tr ',' '\n' | grep -v '^$' || true)
  if [[ -z "$cidrs" ]]; then
    warn "no admin_cidrs found in terraform.tfvars — skipping egress check"
    return 0
  fi

  if echo "$cidrs" | python3 -c "
import ipaddress, sys
ip = ipaddress.ip_address('$CURRENT_EGRESS_IP')
covered = any(ip in ipaddress.ip_network(c.strip()) for c in sys.stdin if c.strip())
sys.exit(0 if covered else 1)
"; then
    ok "egress IP $CURRENT_EGRESS_IP is covered by admin_cidrs"
    return 0
  fi

  warn "egress IP $CURRENT_EGRESS_IP is NOT covered by admin_cidrs in terraform.tfvars"
  warn "current admin_cidrs: $(echo "$cidrs" | tr '\n' ' ')"
  warn "prepending $CURRENT_EGRESS_IP/32 (backup at terraform.tfvars.bak)"
  cp terraform.tfvars terraform.tfvars.bak
  sed -i.tmp "s|admin_cidrs = \[|admin_cidrs = [\"$CURRENT_EGRESS_IP/32\", |" terraform.tfvars
  rm -f terraform.tfvars.tmp
  ok "$(grep '^admin_cidrs' terraform.tfvars)"
  ok "terraform apply will update the firewall rules to allow this IP (~30s of churn)"
}

# --- terraform init + make deploy ---
deploy() {
  step "Terraform init"
  make init >/dev/null
  ok "initialized against gs://$STATE_BUCKET"

  step "Deploy (terraform apply -> render inventory -> ansible-playbook)"
  make deploy
  ok "deploy complete"

  verify
}

# --- verify cluster ---
verify() {
  step "Verify cluster"
  local n1
  n1=$(terraform output -json node_external_ips 2>/dev/null | jq -r '.n1 // ""')
  [[ -n "$n1" ]] || die "no node IPs in terraform output. Did the deploy succeed?"

  local key="${SSH_KEY_PATH%.pub}"
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -i "$key" "crdb@$n1" \
    'sudo -u cockroach /usr/local/bin/cockroach node status \
       --certs-dir=/var/lib/cockroach/certs --host=localhost' \
    | tail -7

  green ""
  green "Cluster is up. Useful next steps:"
  echo "  Admin UI         $(terraform output -raw admin_ui_url)"
  echo "  All node IPs     terraform output node_external_ips"
  echo "  SSH to a node    ssh crdb@$n1"
  echo "  Tear it down     PROJECT_ID=$PROJECT_ID $0 destroy"

  # DB Console credentials. Pull username from the ansible_group_vars output
  # (which is JSON-readable even though marked sensitive). Pull password from
  # the controller-side stash if it exists; otherwise note that one was set
  # explicitly via crdb_admin_password and won't be re-displayed here.
  local admin_user admin_pw_file admin_pw_explicit
  admin_user=$(terraform output -json ansible_group_vars 2>/dev/null | jq -r '.crdb_admin_user // ""')
  admin_pw_explicit=$(terraform output -json ansible_group_vars 2>/dev/null | jq -r '.crdb_admin_password // ""')
  admin_pw_file="ansible/certs/admin_password.txt"

  if [[ -n "$admin_user" ]]; then
    green ""
    green "DB Console credentials:"
    echo "  Username         $admin_user"
    if [[ -n "$admin_pw_explicit" ]]; then
      echo "  Password         (set via var.crdb_admin_password — not displayed)"
    elif [[ -f "$admin_pw_file" ]]; then
      echo "  Password         $(cat "$admin_pw_file")"
      yellow "                   stored at $admin_pw_file (mode 0600). Rotate with 'make rotate-admin-password'."
    else
      warn "no admin password found at $admin_pw_file"
    fi
  fi

  green ""
  yellow "Reminder: cluster costs ~\$1.50/hr while running. Don't forget to destroy."
}

# --- destroy ---
destroy() {
  step "Destroy cluster"
  if [[ ! -d .terraform ]]; then
    warn ".terraform/ missing — running terraform init first"
    make init >/dev/null
  fi
  terraform destroy -auto-approve
  ok "destroy complete"
  green ""
  yellow "Note: GCS state bucket (gs://$STATE_BUCKET) and ansible/certs/"
  yellow "are preserved. To rotate the CA on next deploy: make clean-ca."
  yellow "To delete the state bucket: gcloud storage rm -r gs://$STATE_BUCKET"
}

# --- dispatch ---
case "$ACTION" in
  deploy)
    preflight
    bootstrap_state
    configure
    deploy
    ;;
  destroy)
    preflight
    destroy
    ;;
  redeploy)
    preflight
    destroy
    bootstrap_state
    configure
    deploy
    ;;
  verify)
    preflight
    verify
    ;;
  *)
    cat >&2 <<EOF
Usage: PROJECT_ID=my-project $0 [deploy|destroy|redeploy|verify]

Optional env overrides:
  SSH_KEY_PATH    public key path; default auto-detects ~/.ssh/id_*.pub
  ADMIN_CIDRS     comma-separated CIDRs; default auto-detects via checkip
  STATE_LOCATION  GCS bucket region; default us-central1
EOF
    exit 1
    ;;
esac
