# Safe batches

Every configuration and role-transfer script can emit **Safe Transaction Builder JSON**
instead of broadcasting. Same script, different mode:

```bash
export OUTPUT_MODE=SAFE
export SAFE_ADDRESS=0x<the executing Safe>

forge script script/ownership/TransferOwnership.s.sol \
  --sig "run(string,string)" sepolia verifier:0x00010001 --rpc-url $SEPOLIA_RPC_URL
# -> writes out/safe/sepolia/transfer-owner-verifier-0x00010001.json
```

In SAFE mode the script stages addresses and calldata only — nothing is broadcast, so it
**never needs a signing key**. It usually **does** need `--rpc-url`; see
[When an RPC is required](#when-an-rpc-is-required).

## OUTPUT_MODE and SAFE_ADDRESS

Every configure, ownership and fee script reads both variables at the start of `run()`.

| variable | required? | values |
|---|---|---|
| `OUTPUT_MODE` | **always** | exactly `EOA` or `SAFE` (case-sensitive) |
| `SAFE_ADDRESS` | in SAFE mode only | the Safe that will import and execute the batch |

There is **no default** for `OUTPUT_MODE`. Unset, empty, or any other string reverts
immediately:

```
BaseScript: OUTPUT_MODE must be exactly EOA or SAFE, got "…"
```

That is deliberate: EOA mode broadcasts live transactions, so selecting it must be an
explicit opt-in. A typo fails the run instead of silently picking a mode.

In SAFE mode, `SAFE_ADDRESS` is also required and must not be zero. The address is written
into the batch JSON as `createdFromSafeAddress`; the Transaction Builder compares it
against the Safe doing the import and flags a mismatch before anyone signs.

In EOA mode, `SAFE_ADDRESS` is ignored. If it is set anyway, the script logs that and
continues.

Every script logs its resolved mode on the first line:

```
[BaseScript] output mode: SAFE
```

Some ownership scripts additionally require `SAFE_ADDRESS` to be the **current on-chain
holder** of the role being moved (owner or `storageLocationsAdmin`), so a batch built for
the wrong Safe is refused at build time rather than after signatures are collected.

## One file, one batch

The Transaction Builder imports **one file at a time**. Each generated JSON is a complete,
independent batch — there is no multi-file container. A multi-step operation therefore
produces several files, each imported and signed separately.

**A batch is atomic; a set of batches is not.** Safe executes one multi-transaction batch
as a single Safe transaction through `MultiSend`, which reverts every call in it if any one
fails — so a batch cannot land half-applied, and there is no flag to configure. Across
files there is no such guarantee: each is its own Safe transaction with its own nonce and
signing round. That is safe here for the reasons in
[Execution order does not matter](#execution-order-does-not-matter), but it does mean a
multi-file operation can sit half-executed between signings.

A script that stages nothing writes **no file**, and deletes any batch left at that path by
an earlier run — otherwise a stale batch could be imported as if it were current.

Batch files are grouped by chain alias under `out/safe/<alias>/`.

That directory is gitignored: batches are run-local artifacts, regenerated from `config/`
whenever they are needed, and delivered to signers out of band rather than through the
repo.

## Execution order does not matter

Batches can be imported and executed in any order:

- The configure batches write disjoint state.
- The two-step handover is enforced **on-chain** — `acceptOwnership()` reverts unless the
  caller is already the pending holder, so an early accept fails harmlessly.

The propose and accept legs are signed by *different* parties anyway; each party generates
and executes only its own leg. The one ceremony where order genuinely matters is
[rotating a verifier](operations.md#rotating-a-verifier).

## When an RPC is required

Always pass `--rpc-url`, in SAFE mode too. SAFE mode never needs a signing **key**, but
nearly every script reads chain state to build or validate the batch — current values to
skip what already matches, reachability, role preflights. (The one exception is
`SetFeeAggregator`, whose calldata comes from `config/` alone.) A missing RPC reverts
before anything is staged — `BaseScript: no code at … - wrong --rpc-url, or none
passed?` — so it costs a re-run and nothing else. The batch's `chainId` comes from
`config/chains/<alias>.json`, not the RPC.

## Verify before signing

The generated JSON is plain addresses and calldata. Signers should check:

- `chainId` matches the chain they intend to execute on
- `meta.createdFromSafeAddress` matches their Safe
- every `to` address matches `config/deployments/<alias>.json`
- the batch name describes what they think they are signing
