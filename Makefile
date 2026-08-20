# CCV Starter Kit — Onchain (Foundry). Convenience targets.
# Pass chain alias / lane via VARS, e.g.  make deploy-verifier CHAIN=sepolia

.PHONY: install build build-dev test test-fork fmt fmt-check lint ci clean \
        bootstrap deploy-resolver deploy-verifier \
        snapshot drift

RPC_URL ?= $(SEPOLIA_RPC_URL)
CHAIN   ?= sepolia
SIGNER  ?= --aws            # override with --private-key $$PRIVATE_KEY for local

install:
	npm install
	forge install foundry-rs/forge-std || true

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

clean:
	forge clean

# ---- deploy (EOA path) ----
bootstrap:
	OUTPUT_MODE=EOA forge script script/deploy/BootstrapFactory.s.sol \
		--rpc-url $(RPC_URL) --broadcast $(SIGNER)

deploy-resolver:
	OUTPUT_MODE=EOA forge script script/deploy/DeployResolver.s.sol \
		--sig "run(string)" $(CHAIN) --rpc-url $(RPC_URL) --broadcast $(SIGNER)

deploy-verifier:
	OUTPUT_MODE=EOA forge script script/deploy/DeployVerifier.s.sol \
		--sig "run(string)" $(CHAIN) --rpc-url $(RPC_URL) --broadcast $(SIGNER)

# ---- governance ----
snapshot:
	forge script script/governance/SnapshotRoles.s.sol \
		--sig "run(string)" $(CHAIN) --rpc-url $(RPC_URL)

drift:            ## CI-schedulable; exit 0 clean / 1 drift / 2 rpc-unavailable
	./script/governance/drift-check.sh $(CHAIN) $(RPC_URL)
