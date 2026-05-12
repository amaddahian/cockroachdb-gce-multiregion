.PHONY: help init plan apply inventory provision provision-check deploy destroy clean clean-ca fmt validate lint syntax-check verify

# Default Ansible playbook args (override on the CLI: make provision EXTRA="--tags certs")
EXTRA ?=

ANSIBLE_DIR := ansible
PLAYBOOK    := $(ANSIBLE_DIR)/playbooks/site.yml
INVENTORY   := $(ANSIBLE_DIR)/inventory/hosts.yml
RENDER      := $(ANSIBLE_DIR)/inventory/render.sh

help:
	@echo "Targets:"
	@echo "  bootstrap-state  one-time: PROJECT_ID=… make bootstrap-state — create the GCS state bucket"
	@echo "  init             terraform init (uses backend.hcl if present, otherwise local state)"
	@echo "  plan             terraform plan"
	@echo "  apply            terraform apply"
	@echo "  inventory        regenerate $(INVENTORY) from terraform outputs"
	@echo "  provision        run the Ansible playbook against the inventory"
	@echo "  provision-check  --check (dry-run) run of the playbook"
	@echo "  deploy           apply + inventory + provision"
	@echo "  destroy          terraform destroy (CA at ansible/certs/ is preserved)"
	@echo "  clean            remove the generated inventory file"
	@echo "  clean-ca         delete ansible/certs/ — DESTRUCTIVE, rotates CA on next deploy"
	@echo "  fmt              terraform fmt -recursive"
	@echo "  validate         terraform fmt -check && terraform validate"
	@echo "  lint             ansible-lint"
	@echo "  syntax-check     ansible-playbook --syntax-check"
	@echo "  verify           validate + lint + syntax-check"

init:
	@if [ -f backend.hcl ]; then \
	  echo "Initializing with remote state (backend.hcl)..."; \
	  terraform init -backend-config=backend.hcl; \
	else \
	  echo "No backend.hcl found — initializing with local state."; \
	  echo "Copy backend.hcl.example to backend.hcl for GCS-backed remote state."; \
	  terraform init; \
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
	@echo "Bucket ready. Now copy backend.hcl.example -> backend.hcl,"
	@echo "set bucket = \"$$PROJECT_ID-tfstate-crdb\", and run 'make init'."

plan:
	terraform plan

apply:
	terraform apply $(APPROVE)

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
	terraform destroy

clean:
	rm -f $(INVENTORY)

clean-ca:
	@echo "About to delete $(ANSIBLE_DIR)/certs/ — this rotates the CA on next provision."
	@echo "Existing node certs will mismatch. Press Ctrl-C in 5s to abort."
	@sleep 5
	rm -rf $(ANSIBLE_DIR)/certs

fmt:
	terraform fmt -recursive

validate:
	terraform fmt -check
	terraform validate

lint:
	cd $(ANSIBLE_DIR) && ansible-lint

syntax-check: $(INVENTORY)
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory/hosts.yml playbooks/site.yml --syntax-check

verify: validate lint syntax-check

$(INVENTORY):
	@echo "ERROR: $(INVENTORY) does not exist. Run 'make inventory' (after 'terraform apply')." >&2
	@exit 1
