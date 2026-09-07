# CCV Starter Kit. Convenience targets.
#
# Recipes that expand an RPC URL are prefixed with `@`: make echoes recipe lines by
# default, and RPC URLs usually carry an API key. Keep the `@` when editing them.

.PHONY: help install build build-dev clean \
        test test-config fmt fmt-check lint lint-sh lint-typos \
        bootstrap-factory deploy-resolver deploy-verifier verify \
        apply-remote-config apply-allowlists apply-signature-configs \
        set-dynamic-config set-finality-config update-storage-locations \
        apply-inbound apply-outbound set-fee-aggregator \
        transfer-owner accept-owner cancel-owner \
        transfer-sla accept-sla cancel-sla \
        sweep-fees balance-report \
        snapshot drift parity parity-config deployments-doc deployments-check \
        discover add-chain sync-check sync-chain

CHAIN   ?=
LANE    ?=
TAG     ?=
SELECTOR ?=                 # CCIP chain selector, for add-chain
TARGET  ?=                  # ownership target: verifier:<tag> | resolver | factory
RPC_URL ?=
SOURCE_RPC ?=
DEST_RPC   ?=
SIGNER  ?= --aws            # override with --private-key $$PRIVATE_KEY for local
OUTPUT_MODE ?=              # REQUIRED on configure/ownership/fee targets: exactly EOA or SAFE, no default
SAFE_ADDRESS ?=

# ---- shared recipe for every configure / ownership / fee script ----
# $(call run-script,<script.s.sol>,"<sig>",<args>)
#   OUTPUT_MODE=EOA  -> broadcast now with $(SIGNER)
#   OUTPUT_MODE=SAFE -> SAFE_ADDRESS required, no broadcast (writes an out/safe/ batch)
# No default, matching the env var the scripts themselves read: EOA broadcasts live
# transactions, so selecting it must be explicit.
define run-script
	@test -n "$(CHAIN)"   || { echo "CHAIN is required, e.g. make $@ CHAIN=sepolia"; exit 2; }
	@test -n "$(RPC_URL)" || { echo "RPC_URL is required (that chain's endpoint)";   exit 2; }
	@case "$(strip $(OUTPUT_MODE))" in \
	EOA) \
		OUTPUT_MODE=EOA forge script $(1) --sig $(2) $(3) --rpc-url $(RPC_URL) --broadcast $(SIGNER);; \
	SAFE) \
		test -n "$(strip $(SAFE_ADDRESS))" || { echo "SAFE_ADDRESS is required with OUTPUT_MODE=SAFE (the executing Safe)"; exit 2; }; \
		OUTPUT_MODE=SAFE SAFE_ADDRESS=$(strip $(SAFE_ADDRESS)) forge script $(1) --sig $(2) $(3) --rpc-url $(RPC_URL);; \
	*) \
		echo "OUTPUT_MODE must be exactly EOA or SAFE, got \"$(strip $(OUTPUT_MODE))\" (EOA broadcasts live, so it is an explicit opt-in)"; exit 2;; \
	esac
endef

# guard for targets whose script takes (string,bytes4)
define need-tag
	@test -n "$(TAG)" || { echo "TAG is required (bytes4 versionTag, e.g. TAG=0x00010001)"; exit 2; }
endef

# Bare `make` must list targets, never run one — `install` used to be the accidental default.
.DEFAULT_GOAL := help
help:             ## list every target
	@grep -hE '^[a-zA-Z][a-zA-Z0-9_-]*:.*##' $(MAKEFILE_LIST) | awk -F':.*?## *' '{printf "  %-25s %s\n", $$1, $$2}'

install:          ## npm ci + git submodules
	npm ci
	git submodule update --init --recursive

build:            ## production (deterministic) profile
	forge build

build-dev:        ## fast iteration profile (NOT address-compatible)
	FOUNDRY_PROFILE=dev forge build

test:             ## hermetic; no RPC needed
	forge test -vvv

fmt:              ## forge fmt (writes)
	forge fmt

fmt-check:        ## forge fmt --check
	forge fmt --check

lint:             ## forge lint
	forge lint

lint-sh:          ## shellcheck every wrapper script
	shellcheck --severity=warning $$(find script -name '*.sh')

lint-typos:       ## spell-check the whole repo (needs crate-ci/typos: cargo install typos-cli)
	typos

test-config:      ## offline tests for the config-sync write/override semantics
	./script/config/selftest.sh

clean:            ## forge clean
	forge clean

# ---- chain config (Chainlink CCIP API) ----
discover:         ## list the CCIP API chain catalog + local config status
	./script/config/sync-ccip-config.sh discover

add-chain:        ## seed config/chains/<alias>.json from the API; never overwrites
	@test -n "$(CHAIN)"    || { echo "CHAIN is required, e.g. make add-chain CHAIN=sepolia SELECTOR=16015286601757825753"; exit 2; }
	@test -n "$(SELECTOR)" || { echo "SELECTOR is required (the chain's CCIP selector; make discover lists them)"; exit 2; }
	./script/config/sync-ccip-config.sh bootstrap $(CHAIN) $(SELECTOR)

sync-check:       ## config vs the CCIP API, all chains; read-only, CI-schedulable
	./script/config/sync-ccip-config.sh check --all

sync-chain:       ## accept upstream CCIP values for ONE chain (no --all by design)
	@test -n "$(CHAIN)" || { echo "CHAIN is required, e.g. make sync-chain CHAIN=sepolia"; exit 2; }
	./script/config/sync-ccip-config.sh sync $(CHAIN)

# ---- deploy (EOA path) ----
bootstrap-factory: ## CREATE2Factory; must be the deployer's FIRST tx on the chain
	@test -n "$(CHAIN)"   || { echo "CHAIN is required, e.g. make bootstrap-factory CHAIN=sepolia"; exit 2; }
	@test -n "$(RPC_URL)" || { echo "RPC_URL is required (that chain's endpoint)";            exit 2; }
	@OUTPUT_MODE=EOA forge script script/deploy/BootstrapFactory.s.sol \
		--sig "run(string)" $(CHAIN) --rpc-url $(RPC_URL) --broadcast $(SIGNER)

deploy-resolver:  ## resolver via CREATE2; must land at the same address on every chain
	@test -n "$(CHAIN)"   || { echo "CHAIN is required, e.g. make deploy-resolver CHAIN=sepolia"; exit 2; }
	@test -n "$(RPC_URL)" || { echo "RPC_URL is required (that chain's endpoint)";                exit 2; }
	@OUTPUT_MODE=EOA forge script script/deploy/DeployResolver.s.sol \
		--sig "run(string)" $(CHAIN) --rpc-url $(RPC_URL) --broadcast $(SIGNER)

deploy-verifier:  ## CommitteeVerifier for TAG; appends to the deployment record
	@test -n "$(CHAIN)"   || { echo "CHAIN is required, e.g. make deploy-verifier CHAIN=sepolia TAG=0x00010001"; exit 2; }
	@test -n "$(TAG)"     || { echo "TAG is required (the verifier's bytes4 versionTag, e.g. TAG=0x00010001)"; exit 2; }
	@test -n "$(RPC_URL)" || { echo "RPC_URL is required (that chain's endpoint)";                exit 2; }
	@OUTPUT_MODE=EOA forge script script/deploy/DeployVerifier.s.sol \
		--sig "run(string,bytes4)" $(CHAIN) $(TAG) --rpc-url $(RPC_URL) --broadcast $(SIGNER)

verify:           ## source-verify recorded contracts; ONLY=factory|resolver|verifiers|verifier:<tag>
	@test -n "$(CHAIN)" || { echo "CHAIN is required, e.g. make verify CHAIN=sepolia"; exit 2; }
	./script/deploy/verify.sh $(CHAIN) $(if $(ONLY),--only $(ONLY))

# ---- configure: per verifier (CHAIN + TAG; OUTPUT_MODE=EOA|SAFE) ----
apply-remote-config: ## lane remoteChainConfig on the SOURCE chain's verifier
	$(need-tag)
	$(call run-script,script/configure/ApplyRemoteChainConfigUpdates.s.sol,"run(string,bytes4)",$(CHAIN) $(TAG))

apply-allowlists: ## lane sender allowlists on the SOURCE chain's verifier
	$(need-tag)
	$(call run-script,script/configure/ApplyAllowlistUpdates.s.sol,"run(string,bytes4)",$(CHAIN) $(TAG))

apply-signature-configs: ## committee signer sets on the DEST chain's verifier
	$(need-tag)
	$(call run-script,script/configure/ApplySignatureConfigs.s.sol,"run(string,bytes4)",$(CHAIN) $(TAG))

set-dynamic-config: ## verifier { feeAggregator, allowlistAdmin } from roles
	$(need-tag)
	$(call run-script,script/configure/SetDynamicConfig.s.sol,"run(string,bytes4)",$(CHAIN) $(TAG))

set-finality-config: ## verifier allowed-finality cap from chain config
	$(need-tag)
	$(call run-script,script/configure/SetAllowedFinalityConfig.s.sol,"run(string,bytes4)",$(CHAIN) $(TAG))

update-storage-locations: ## verifier storageLocations (caller: storageLocationsAdmin)
	$(need-tag)
	$(call run-script,script/configure/UpdateStorageLocations.s.sol,"run(string,bytes4)",$(CHAIN) $(TAG))

# ---- configure: resolver-scoped (CHAIN only) ----
apply-inbound:    ## resolver inbound map (versionTag -> verifier) for lanes INTO this chain
	$(call run-script,script/configure/ApplyInboundImplementationUpdates.s.sol,"run(string)",$(CHAIN))

apply-outbound:   ## resolver outbound map (dest selector -> verifier) for lanes FROM this chain
	$(call run-script,script/configure/ApplyOutboundImplementationUpdates.s.sol,"run(string)",$(CHAIN))

set-fee-aggregator: ## resolver feeAggregator from roles
	$(call run-script,script/configure/SetFeeAggregator.s.sol,"run(string)",$(CHAIN))

# ---- ownership: owner roles (CHAIN + TARGET=verifier:<tag>|resolver|factory) ----
transfer-owner:   ## current owner PROPOSES the configured holder
	@test -n "$(TARGET)" || { echo "TARGET is required: verifier:<tag> | resolver | factory"; exit 2; }
	$(call run-script,script/ownership/TransferOwnership.s.sol,"run(string,string)",$(CHAIN) $(TARGET))

accept-owner:     ## incoming owner ACCEPTS (run with THEIR signer / Safe)
	@test -n "$(TARGET)" || { echo "TARGET is required: verifier:<tag> | resolver | factory"; exit 2; }
	$(call run-script,script/ownership/AcceptOwnership.s.sol,"run(string,string)",$(CHAIN) $(TARGET))

cancel-owner:     ## current owner clears a pending transfer
	@test -n "$(TARGET)" || { echo "TARGET is required: verifier:<tag> | resolver | factory"; exit 2; }
	$(call run-script,script/ownership/CancelOwnership.s.sol,"run(string,string)",$(CHAIN) $(TARGET))

# ---- ownership: storageLocationsAdmin (CHAIN + TAG) ----
transfer-sla:     ## current admin PROPOSES the configured storageLocationsAdmin
	$(need-tag)
	$(call run-script,script/ownership/TransferStorageLocationsAdmin.s.sol,"run(string,bytes4)",$(CHAIN) $(TAG))

accept-sla:       ## incoming admin ACCEPTS (run with THEIR signer / Safe)
	$(need-tag)
	$(call run-script,script/ownership/AcceptStorageLocationsAdmin.s.sol,"run(string,bytes4)",$(CHAIN) $(TAG))

cancel-sla:       ## current admin clears a pending transfer
	$(need-tag)
	$(call run-script,script/ownership/CancelStorageLocationsAdmin.s.sol,"run(string,bytes4)",$(CHAIN) $(TAG))

# ---- fees ----
sweep-fees:       ## withdraw fee-token balances to the aggregators
	$(call run-script,script/fees/SweepFees.s.sol,"run(string)",$(CHAIN))

balance-report:   ## read-only fee balances (no OUTPUT_MODE, no broadcast)
	@test -n "$(CHAIN)"   || { echo "CHAIN is required, e.g. make balance-report CHAIN=sepolia"; exit 2; }
	@test -n "$(RPC_URL)" || { echo "RPC_URL is required (that chain's endpoint)";               exit 2; }
	@forge script script/fees/BalanceReport.s.sol --sig "run(string)" $(CHAIN) --rpc-url $(RPC_URL)

# ---- governance ----
snapshot:         ## write live role holders to out/governance/ (read-only)
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
