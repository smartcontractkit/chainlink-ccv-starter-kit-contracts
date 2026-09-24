# Operational notes

Runtime behaviour and constraints that the config files do not express.

## There is no pause function

The **only** emergency lever is outbound: `router = 0` for a destination on the source verifier. That destination's `getFee` and `forwardToVerifier` then revert `RemoteChainNotSupported`, and `ccipSend` fails.

```bash
# on the lane's SOURCE chain; requires LANE, RPC_URL, OUTPUT_MODE (+ SAFE_ADDRESS in SAFE mode)
make pause-lane LANE=sepolia-to-base_sepolia RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=SAFE SAFE_ADDRESS=0x...
```

`PauseLane` reads the destination's current on-chain config, zeroes only the router, and
skips the call when it is already zero. It then writes `remoteChainConfig.router = 0x0`
into the lane file so `apply-remote-config` keeps the pause. Commit that change. To
resume, delete the `router` key from the lane file and run `apply-remote-config`.

It is **per destination**, not global. Pausing one lane leaves every other destination on
the same verifier working.

There is **no inbound halt**. A message already signed on the source can still be
delivered.

`gasForVerification` must stay non-zero even while paused — `BaseVerifier` reverts
`DestGasCannotBeZero` regardless of the router value.

## RMN curse is separate

An RMN curse is a Chainlink-operated halt that fires *before* the router check. It is not
something this repo controls, and it looks different in traces: `CursedByRMN` rather than
`RemoteChainNotSupported`.

## Two fee destinations

The verifier's `DynamicConfig.feeAggregator` and the resolver's `setFeeAggregator` are
different settings on different contracts. **Set both.** A zero aggregator is a valid
state that intentionally makes fee withdrawals revert.

## Immutable values

Two constructor arguments cannot be changed after deployment:

- **`versionTag`** — `bytes4`, non-zero. A new tag means a new verifier deployment plus
  resolver re-wiring. Scheme: 2 bytes operator id, 2 bytes version.
- **`rmn`** — no getter, so no check can ever verify it. Get it right before deploying.

## Rotating a verifier

Because callers reach the verifier through the resolver, a new verifier can be introduced
without moving the resolver. The ordering is load-bearing:

1. Add the new tag to `config/operator.json` and a `verifiers[]` entry in every chain's operator file.
2. `make deploy-verifier CHAIN=… TAG=<new> RPC_URL=…` on every chain.
3. Register its **inbound** implementation on the destination (`ApplyInboundImplementationUpdates`).
4. Flip the lane's `versionTag` in `config/operator/lanes/*.json` and re-run configure on both chains.
5. Switch the **outbound** implementation on the source (`ApplyOutboundImplementationUpdates`) — cutover last.
6. Retire the old inbound mapping **only after in-flight messages drain** (stage `{tag, address(0)}`, delete the deployment record entry).

The old tag's inbound mapping must outlive the outbound switch. Messages already signed
with the old tag are still arriving, and they resolve through that mapping. Nothing
enforces this sequencing on-chain — this is the one ceremony where batch execution order
genuinely matters.

While both verifiers are live they are isolated only if their **signer sets** differ. The
new `versionTag` does not stop a signature made for one from satisfying the other — see
[what `versionTag` is, and is not](configuration.md#what-versiontag-is-and-is-not). Rotate
the committee alongside the verifier if that overlap matters.

## Fee sweeping

`SweepFees` (`make sweep-fees CHAIN=… RPC_URL=… OUTPUT_MODE=…`) withdraws accumulated fee
tokens to the configured aggregators; `BalanceReport` (`make balance-report`, read-only)
shows what is there first. Both cover **every recorded verifier** and the resolver, each
gated independently: a contract whose aggregator is zero on-chain *and* in `config/operator`
is skipped as not in use, while an aggregator named on only one side — or named
differently — reverts the build as drift.

`feeTokens` is optional per chain: absent means an empty list, which makes the fee scripts
no-op rather than fail. Every listed entry must be a real ERC20 with code — a zero
address, a codeless address, or a reverting `balanceOf` fails the build with the entry
named, rather than being read as an empty balance.

Zero-balance tokens are omitted from each staged call **by default**
(`SKIP_ZERO_BALANCES` defaults to true), and a contract with nothing sweepable gets no
call at all. Set `SKIP_ZERO_BALANCES=false` to stage every configured token regardless of
balance — for Safe batches executed long after they are built, where fees accrue between
build and execution.

`--rpc-url` is required, including in SAFE mode: the scripts read balances and the
on-chain aggregators at build time, and without an RPC the run reverts on the first
reachability check (`BaseScript: no code at verifier …`).

## Storage locations

`storageLocations` is where a verifier's own signers publish — a per-deployment input from the
off-chain component. It is updatable after deployment by the `storageLocationsAdmin`, via
`UpdateStorageLocations`.
