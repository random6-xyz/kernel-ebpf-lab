SHELL := /bin/bash
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TREE ?= master
JOBS ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')
SSH_PORT ?= 2222
QEMU_KVM ?= auto

export ROOT TREE JOBS SSH_PORT QEMU_KVM

.PHONY: all check-host fetch bpf-object buildroot kernel image run stop test test-smoke verifier clean distclean help

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

image: buildroot kernel

run: image
	$(ROOT)/scripts/run-qemu.sh --tree $(TREE) --ssh-port $(SSH_PORT)

stop:
	$(ROOT)/scripts/run-qemu.sh --tree $(TREE) --ssh-port $(SSH_PORT) --stop

test: image
	$(ROOT)/scripts/test.sh --tree $(TREE) --ssh-port $(SSH_PORT)

test-smoke: test

verifier: bpf-object
	$(ROOT)/scripts/collect-verifier.sh --tree $(TREE) --ssh-port $(SSH_PORT)

clean:
	rm -rf $(ROOT)/out/kernel $(ROOT)/out/artifacts $(ROOT)/out/qemu

# distclean intentionally preserves the downloaded source trees.
distclean: clean
	rm -rf $(ROOT)/out/buildroot

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  check-host                 Check host tools without installing packages' \
	  '  fetch                      Create Linux worktrees and fetch Buildroot' \
	  '  bpf-object                 Build tests/bpf cases into out/bpf' \
	  '  buildroot                  Build the QEMU root filesystem' \
	  '  kernel TREE=<name>         Build master, bpf, or bpf-next' \
	  '  image TREE=<name>          Build rootfs and kernel' \
	  '  run TREE=<name>            Boot QEMU with serial console' \
	  '  test TREE=<name>           Boot QEMU and run the guest smoke test' \
	  '  verifier TREE=<name>       Collect verifier responses for tests/bpf cases' \
	  '  stop TREE=<name>           Stop a background QEMU instance' \
	  '  clean / distclean          Remove generated output'
