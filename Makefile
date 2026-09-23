# Convenience wrappers. Every target is a thin alias for a command you could
# type yourself -- read them before trusting them.
#
#   make setup      one-time: local venv with pinned Ansible + collections
#   make lint       everything CI's lint workflow runs (minus hadolint)
#   make discover   read-only fact gathering on the Pi
#   make check      dry run: what WOULD change (no changes made)
#   make deploy     apply (run `make check` first and read the diff)
#   make validate   read-only post-deploy health check on the Pi
#
# PI must match ansible/inventory.ini (user@LAN-IP, or Tailscale name later).

PI    ?= pi@192.168.1.2
VENV  ?= .venv
BIN   := $(VENV)/bin
TAGS  ?=
TAGARG := $(if $(TAGS),--tags $(TAGS),)

.PHONY: setup lint discover check deploy validate

setup:
	python3 -m venv $(VENV)
	$(BIN)/pip install -r requirements-dev.txt
	cd ansible && ../$(BIN)/ansible-galaxy collection install -r requirements.yml

lint:
	$(BIN)/yamllint --strict .
	cd ansible && ../$(BIN)/ansible-playbook playbook.yml --syntax-check
	cd ansible && ../$(BIN)/ansible-lint --offline
	shellcheck --severity=style $$(git ls-files '*.sh')
	docker compose --env-file docker/.env.example -f docker/docker-compose.yml config --quiet

discover:
	ssh $(PI) 'bash -s' < scripts/discover.sh

check:
	cd ansible && ../$(BIN)/ansible-playbook playbook.yml --check --diff $(TAGARG)

deploy:
	cd ansible && ../$(BIN)/ansible-playbook playbook.yml --diff $(TAGARG)

validate:
	ssh $(PI) 'sudo bash -s' < scripts/validate.sh
