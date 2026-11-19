# Thin wrapper around bootstrap.sh. Pass options through, e.g.
#   make server IDENTITY=kinsol
#   make dotfiles ARGS=--dry-run

IDENTITY ?=
ARGS ?=
BOOT = ./bootstrap.sh $(if $(IDENTITY),--identity $(IDENTITY)) $(ARGS)
STEPS = base shell dotfiles ssh gui vscode

.PHONY: help all server workstation dry-run $(STEPS)

help:
	@sed -n '2,17s/^# \{0,1\}//p' bootstrap.sh
	@echo
	@echo "make targets: all server workstation dry-run $(STEPS)"

all:
	$(BOOT)

server:
	$(BOOT) --profile server

workstation:
	$(BOOT) --profile workstation

dry-run:
	$(BOOT) --dry-run

$(STEPS):
	$(BOOT) --only $@
