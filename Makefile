.PHONY: help init plan apply inventory provision provision-check deploy destroy clean clean-ca rotate-admin-password fmt validate lint syntax-check verify workload-init workload-plan workload-apply workload-destroy

# Default Ansible playbook args (override on the CLI: make provision EXTRA="--tags certs")
EXTRA ?=

ANSIBLE_DIR := ansible
PLAYBOOK    := $(ANSIBLE_DIR)/playbooks/site.yml
INVENTORY   := $(ANSIBLE_DIR)/inventory/hosts.yml
RENDER      := $(ANSIBLE_DIR)/inventory/render.sh
TF_DIR      := terraform/gcp
TF          := terraform -chdir=$(TF_DIR)
WL_DIR      := terraform/workload
WL          := terraform -chdir=$(WL_DIR)

help:
	@echo "Targets:"
	@echo "  bootstrap-state  one-time: PROJECT_ID=… make bootstrap-state — create the GCS state bucket"
	@echo "  init             terraform init (uses $(TF_DIR)/backend.hcl if present, otherwise local state)"
	@echo "  plan             terraform plan"
	@echo "  apply            terraform apply"
	@echo "  inventory        regenerate $(INVENTORY) from terraform outputs"
	@echo "  provision        run the Ansible playbook against the inventory"
	@echo "  provision-check  --check (dry-run) run of the playbook"
	@echo "  deploy           apply + inventory + provision"
	@echo "  destroy          terraform destroy (CA at ansible/certs/ is preserved)"
	@echo "  clean            remove the generated inventory file"
	@echo "  clean-ca         delete ansible/certs/ — DESTRUCTIVE, rotates CA on next deploy"
	@echo "  rotate-admin-password  generate a new DB Console admin password and apply it"
	@echo "  fmt              terraform fmt -recursive"
	@echo "  validate         terraform fmt -check && terraform validate"
	@echo "  lint             ansible-lint"
	@echo "  syntax-check     ansible-playbook --syntax-check"
	@echo "  verify           validate + lint + syntax-check"
	@echo ""
	@echo "Workload VM (opt-in adjunct stack under $(WL_DIR)):"
	@echo "  workload-init    terraform init for the workload stack (uses $(WL_DIR)/backend.hcl if present)"
	@echo "  workload-plan    terraform plan for the workload stack"
	@echo "  workload-apply   terraform apply for the workload stack"
	@echo "  workload-destroy terraform destroy for the workload stack"

init:
	@if [ -f $(TF_DIR)/backend.hcl ]; then \
	  echo "Initializing with remote state ($(TF_DIR)/backend.hcl)..."; \
	  $(TF) init -backend-config=backend.hcl; \
	else \
	  echo "No $(TF_DIR)/backend.hcl found — initializing with local state."; \
	  echo "Copy $(TF_DIR)/backend.hcl.example to $(TF_DIR)/backend.hcl for GCS-backed remote state."; \
	  $(TF) init; \
	fi

bootstrap-state:
	@if [ -z "$$PROJECT_ID" ]; then echo "Set PROJECT_ID first: PROJECT_ID=my-project make bootstrap-state"; exit 1; fi
	@bucket="gs://$$PROJECT_ID-tfstate-crdb"; \
	if gcloud storage buckets describe "$$bucket" --format="value(name)" >/dev/null 2>&1; then \
	  echo "Bucket $$bucket already exists — skipping create."; \
	else \
	  gcloud storage buckets create "$$bucket" --project="$$PROJECT_ID" --location=us-central1 --uniform-bucket-level-access; \
	fi
	gcloud storage buckets update "gs://$$PROJECT_ID-tfstate-crdb" --versioning
	@echo
	@echo "Bucket ready. Now copy $(TF_DIR)/backend.hcl.example -> $(TF_DIR)/backend.hcl,"
	@echo "set bucket = \"$$PROJECT_ID-tfstate-crdb\", and run 'make init'."

plan:
	$(TF) plan

apply:
	$(TF) apply $(APPROVE)

inventory:
	bash $(RENDER)

provision: $(INVENTORY)
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory/hosts.yml playbooks/site.yml $(EXTRA)

provision-check: $(INVENTORY)
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory/hosts.yml playbooks/site.yml --check --diff $(EXTRA)

# `make deploy` chains apply + inventory + provision in one shot. apply
# auto-approves here because make is non-interactive — `terraform apply`
# without flags would EOF on the y/n prompt and abort. For deliberate
# step-by-step bring-up, use `make plan && make apply` (interactive) and
# then `make inventory && make provision`.
deploy:
	$(MAKE) apply APPROVE=-auto-approve
	$(MAKE) inventory
	$(MAKE) provision

destroy:
	$(TF) destroy

clean:
	rm -f $(INVENTORY)

clean-ca:
	@echo "About to delete $(ANSIBLE_DIR)/certs/ — this rotates the CA on next provision."
	@echo "Existing node certs will mismatch. Press Ctrl-C in 5s to abort."
	@sleep 5
	rm -rf $(ANSIBLE_DIR)/certs

# Rotate the DB Console admin password. Removes the cached file so the next
# provision generates a new one, runs only the admin_user task (fast — no
# storage/install/cert churn), then prints the new password.
rotate-admin-password: $(INVENTORY)
	@if grep -qE '^[[:space:]]*crdb_admin_password[[:space:]]*=' $(TF_DIR)/terraform.tfvars 2>/dev/null \
	   && ! grep -qE '^[[:space:]]*crdb_admin_password[[:space:]]*=[[:space:]]*""' $(TF_DIR)/terraform.tfvars 2>/dev/null; then \
	  echo "ERROR: crdb_admin_password is set explicitly in $(TF_DIR)/terraform.tfvars."; \
	  echo "       Edit it there to rotate, then run 'make provision EXTRA=\"--tags admin_user\"'."; \
	  exit 1; \
	fi
	rm -f $(ANSIBLE_DIR)/certs/admin_password.txt
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory/hosts.yml playbooks/site.yml --tags admin_user
	@echo
	@echo "New DB Console password:"
	@cat $(ANSIBLE_DIR)/certs/admin_password.txt
	@echo

fmt:
	$(TF) fmt -recursive

validate:
	$(TF) fmt -check
	$(TF) validate

lint:
	cd $(ANSIBLE_DIR) && ansible-lint

syntax-check: $(INVENTORY)
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory/hosts.yml playbooks/site.yml --syntax-check

verify: validate lint syntax-check

# --- Workload VM (opt-in) ---------------------------------------------------
# Spins up a single GCE VM in the cluster's primary region for running
# `cockroach workload run` close to the cluster. See README "Workload VM
# (opt-in)" for post-apply install steps (cockroach binary + certs).
workload-init:
	@if [ -f $(WL_DIR)/backend.hcl ]; then \
	  echo "Initializing workload stack with remote state ($(WL_DIR)/backend.hcl)..."; \
	  $(WL) init -backend-config=backend.hcl; \
	else \
	  echo "No $(WL_DIR)/backend.hcl found — initializing workload stack with local state."; \
	  echo "Copy $(WL_DIR)/backend.hcl.example to $(WL_DIR)/backend.hcl for GCS-backed remote state."; \
	  $(WL) init; \
	fi

workload-plan:
	$(WL) plan

workload-apply:
	$(WL) apply $(APPROVE)

workload-destroy:
	$(WL) destroy

$(INVENTORY):
	@echo "ERROR: $(INVENTORY) does not exist. Run 'make inventory' (after 'terraform apply')." >&2
	@exit 1
