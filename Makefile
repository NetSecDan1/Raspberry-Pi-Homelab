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
# The Pi's address is never committed (public repo). Set it per shell:
#   export PI_HOST=<Pi's LAN IP>      (or its Tailscale IP later)

PI_USER ?= pi
PI       = $(PI_USER)@$(PI_HOST)
VENV  ?= .venv
BIN   := $(VENV)/bin
TAGS  ?=
TAGARG := $(if $(TAGS),--tags $(TAGS),)

.PHONY: setup lint discover check deploy validate need-host

need-host:
	@test -n "$(PI_HOST)" || { echo "PI_HOST is not set: export PI_HOST=<Pi's IP>"; exit 1; }

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

discover: need-host
	ssh $(PI) 'bash -s' < scripts/discover.sh

check:
	cd ansible && ../$(BIN)/ansible-playbook playbook.yml --check --diff $(TAGARG)

deploy:
	cd ansible && ../$(BIN)/ansible-playbook playbook.yml --diff $(TAGARG)

validate: need-host
	ssh $(PI) 'sudo bash -s' < scripts/validate.sh
