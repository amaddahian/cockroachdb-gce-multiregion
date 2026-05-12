.PHONY: help init plan apply inventory provision provision-check deploy destroy clean clean-ca fmt validate lint syntax-check verify

# Default Ansible playbook args (override on the CLI: make provision EXTRA="--tags certs")
EXTRA ?=

ANSIBLE_DIR := ansible
PLAYBOOK    := $(ANSIBLE_DIR)/playbooks/site.yml
INVENTORY   := $(ANSIBLE_DIR)/inventory/hosts.yml
RENDER      := $(ANSIBLE_DIR)/inventory/render.sh

help:
	@echo "Targets:"
	@echo "  init             terraform init"
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
	terraform init

plan:
	terraform plan

apply:
	terraform apply

inventory:
	bash $(RENDER)

provision: $(INVENTORY)
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory/hosts.yml playbooks/site.yml $(EXTRA)

provision-check: $(INVENTORY)
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory/hosts.yml playbooks/site.yml --check --diff $(EXTRA)

deploy: apply inventory provision

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
