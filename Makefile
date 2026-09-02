# CCV Starter Kit. Convenience targets.
#
# Recipes that expand an RPC URL are prefixed with `@`: make echoes recipe lines by
# default, and RPC URLs usually carry an API key. Keep the `@` when editing them.

.PHONY: install build build-dev clean \
        test test-fork test-config fmt fmt-check lint lint-sh lint-typos \
        bootstrap-factory deploy-resolver deploy-verifier \
        snapshot drift parity parity-config deployments-doc deployments-check

CHAIN   ?=
LANE    ?=
TAG     ?=
RPC_URL ?=
SOURCE_RPC ?=
DEST_RPC   ?=
SIGNER  ?= --aws            # override with --private-key $$PRIVATE_KEY for local

install:
	npm ci
	git submodule update --init --recursive

build:            ## production (deterministic) profile
	forge build

build-dev:        ## fast iteration profile (NOT address-compatible)
	FOUNDRY_PROFILE=dev forge build

test:             ## hermetic; excludes fork tests (they need RPC secrets)
	forge test -vvv --no-match-path 'test/**/*.fork.t.sol'

test-fork:        ## needs RPC endpoints; not part of the PR gate
	forge test -vvv --match-path 'test/**/*.fork.t.sol'

fmt:
	forge fmt

fmt-check:
	forge fmt --check

lint:
	forge lint

lint-sh:          ## shellcheck every wrapper script
	shellcheck --severity=warning $$(find script -name '*.sh')

lint-typos:       ## spell-check the whole repo (needs crate-ci/typos: cargo install typos-cli)
	typos

test-config:      ## offline tests for the config-sync write/override semantics
	./script/config/selftest.sh

clean:
	forge clean

# ---- deploy (EOA path) ----
bootstrap-factory: ## CREATE2Factory; must be the deployer's FIRST tx on the chain
	@test -n "$(CHAIN)"   || { echo "CHAIN is required, e.g. make bootstrap-factory CHAIN=sepolia"; exit 2; }
	@test -n "$(RPC_URL)" || { echo "RPC_URL is required (that chain's endpoint)";            exit 2; }
	@OUTPUT_MODE=EOA forge script script/deploy/BootstrapFactory.s.sol \
		--sig "run(string)" $(CHAIN) --rpc-url $(RPC_URL) --broadcast $(SIGNER)

deploy-resolver:
	@test -n "$(CHAIN)"   || { echo "CHAIN is required, e.g. make deploy-resolver CHAIN=sepolia"; exit 2; }
	@test -n "$(RPC_URL)" || { echo "RPC_URL is required (that chain's endpoint)";                exit 2; }
	@OUTPUT_MODE=EOA forge script script/deploy/DeployResolver.s.sol \
		--sig "run(string)" $(CHAIN) --rpc-url $(RPC_URL) --broadcast $(SIGNER)

deploy-verifier:
	@test -n "$(CHAIN)"   || { echo "CHAIN is required, e.g. make deploy-verifier CHAIN=sepolia TAG=0x00010001"; exit 2; }
	@test -n "$(TAG)"     || { echo "TAG is required (bytes4 versionTag for this generation, e.g. TAG=0x00010001)"; exit 2; }
	@test -n "$(RPC_URL)" || { echo "RPC_URL is required (that chain's endpoint)";                exit 2; }
	@OUTPUT_MODE=EOA forge script script/deploy/DeployVerifier.s.sol \
		--sig "run(string,bytes4)" $(CHAIN) $(TAG) --rpc-url $(RPC_URL) --broadcast $(SIGNER)

# ---- governance ----
snapshot:
	@test -n "$(CHAIN)"   || { echo "CHAIN is required, e.g. make snapshot CHAIN=sepolia"; exit 2; }
	@test -n "$(RPC_URL)" || { echo "RPC_URL is required (that chain's endpoint)";          exit 2; }
	@forge script script/governance/SnapshotRoles.s.sol \
		--sig "run(string)" $(CHAIN) --rpc-url $(RPC_URL)

drift:            ## CI-schedulable; exit 0 clean / 1 drift / 2 rpc-unavailable
	@test -n "$(CHAIN)"   || { echo "CHAIN is required, e.g. make drift CHAIN=sepolia";              exit 2; }
	@test -n "$(RPC_URL)" || { echo "RPC_URL is empty (is the chain's *_RPC_URL exported?)";        exit 2; }
	@./script/governance/drift-check.sh $(CHAIN) $(RPC_URL)

deployments-doc:  ## regenerate docs/src/deployments.md from config/
	./script/governance/deployments-report.sh

deployments-check: ## CI: fail if the doc is stale, or if the resolver address diverges
	@./script/governance/deployments-report.sh --check > /dev/null

parity-config:    ## LANE=<name>; config-vs-config only — no RPC
	@test -n "$(LANE)" || { echo "LANE is required, e.g. make parity-config LANE=sepolia-to-base_sepolia"; exit 2; }
	forge script script/governance/LaneParityCheck.s.sol --sig "runConfig(string)" $(LANE)

parity:           ## LANE=<name> SOURCE_RPC=.. DEST_RPC=..; all three legs, worst-of exit
	@test -n "$(LANE)"       || { echo "LANE is required, e.g. make parity LANE=sepolia-to-base_sepolia"; exit 2; }
	@test -n "$(SOURCE_RPC)" || { echo "SOURCE_RPC is empty (export the source chain's RPC)";          exit 2; }
	@test -n "$(DEST_RPC)"   || { echo "DEST_RPC is empty (export the dest chain's RPC)";              exit 2; }
	@./script/governance/lane-parity-check.sh $(LANE) $(SOURCE_RPC) $(DEST_RPC)
