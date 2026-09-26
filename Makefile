SHELL := /bin/bash
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TREE ?= master
JOBS ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')
SSH_PORT ?= 2222
QEMU_KVM ?= auto

export ROOT TREE JOBS SSH_PORT QEMU_KVM

.PHONY: all check-host fetch bpf-object buildroot kernel compile-commands image run stop test test-smoke clean distclean help

all: help

check-host:
	$(ROOT)/scripts/check-host.sh

fetch:
	$(ROOT)/scripts/fetch-sources.sh

bpf-object:
	$(ROOT)/scripts/build-bpf-test.sh

buildroot: bpf-object
	$(ROOT)/scripts/build-buildroot.sh

kernel:
	$(ROOT)/scripts/build-kernel.sh --tree $(TREE)

compile-commands:
	$(ROOT)/scripts/gen-compile-commands.sh --tree $(TREE)

image: buildroot kernel

run: image
	$(ROOT)/scripts/run-qemu.sh --tree $(TREE) --ssh-port $(SSH_PORT)

stop:
	$(ROOT)/scripts/run-qemu.sh --tree $(TREE) --ssh-port $(SSH_PORT) --stop

test: image
	$(ROOT)/scripts/test.sh --tree $(TREE) --ssh-port $(SSH_PORT)

test-smoke: test

clean:
	@for tree in master bpf bpf-next; do \
		source_db="$(ROOT)/sources/linux/$$tree/compile_commands.json"; \
		expected_db="$(ROOT)/out/kernel/$$tree/compile_commands.json"; \
		if [[ -L "$$source_db" && "$$(readlink -- "$$source_db")" == "$$expected_db" ]]; then \
			rm -- "$$source_db"; \
		fi; \
	done
	rm -rf $(ROOT)/out/kernel $(ROOT)/out/artifacts $(ROOT)/out/qemu

# distclean intentionally preserves the downloaded source trees.
distclean: clean
	rm -rf $(ROOT)/out/buildroot

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  check-host                 Check host tools without installing packages' \
	  '  fetch                      Create Linux worktrees and fetch Buildroot' \
	  '  bpf-object                 Build the minimal BPF tracepoint object' \
	  '  buildroot                  Build the QEMU root filesystem' \
	  '  kernel TREE=<name>         Build master, bpf, or bpf-next' \
	  '  compile-commands TREE=<name> Generate database after a kernel build' \
	  '  image TREE=<name>          Build rootfs and kernel' \
	  '  run TREE=<name>            Boot QEMU with serial console' \
	  '  test TREE=<name>           Boot QEMU and run the guest smoke test' \
	  '  stop TREE=<name>           Stop a background QEMU instance' \
	  '  clean / distclean          Remove generated output'
