# choice_v2_contracts

Choice's Solidity for Injective EVM: the pieces PancakeSwap Infinity does not have, plus the
deploy orchestration and the address book that every other v2 repo reads.

Plan and decision log: `choice_v2/CHOICE_V2_EVM_PLAN.md`.

## What is here

| Path | |
| --- | --- |
| `src/fees/` | `ChoiceFeeController` - `IProtocolFeeController` with Choice's tier policy, a permissionless harvest and the treasury / burn-auction split |
| `src/launchpad/` | `InfinitySettler` (`IGraduationSettler`: seed a full-range CL pool atomically) and `PositionLocker` (holds the seed NFT forever, splits fees creator / launchpad) |
| `src/router/` | `ChoiceRouter` - aggregation across Infinity legs in one Vault lock, plus a terminal orderbook leg on the `0x65` precompile |
| `script/` | one ordered deploy run per network, wrapping the forks' numbered scripts |
| `deployments/` | **the** address book. Nothing else is authoritative |
| `lib/` | the three Infinity forks as submodules, pinned by commit |

## Layout rule

The forks' `src/` is never edited, so upstream's audits keep describing the bytecode we
deploy. Everything Choice-specific lives here. See each fork's `INJECTIVE_FORK.md`.

## Build

```bash
git submodule update --init --recursive
forge build
forge test --isolate
```

Compiler settings mirror the Infinity forks exactly (solc 0.8.26, `via_ir`, 25,666 runs,
`cancun`). They are pinned, not knobs: diverging changes the bytecode our contracts are built
with relative to the audited protocol they link against.

While the forks live only on disk, submodules point at `../forks/*`. Run
`./script/tools/submodule-urls.sh org` before pushing.

## Deploying to Injective

Injective RPCs can return `null` for a mined tx's receipt, and `forge --resume` has hung for
ten minutes on a real deploy.

- Broadcast with `--slow`, through the k8s testnet RPC or (mainnet) sentry / our own node.
  Never through polkachu, which serves no receipts.
- **Never `--resume`.** If a run dies mid-way, replay `broadcast/<script>/<chainId>/run-latest.json`
  one `cast send` at a time after checking the nonce.
- Confirm every contract with `eth_getCode`, never with a receipt.
- Update `deployments/injective_<network>.json` in the same PR as the broadcast.

The create3 factory is deployed from a dedicated **nonce-0 EOA**, never through the Arachnid
CREATE2 deployer: `Create3Factory`'s constructor owns and whitelists to `msg.sender`, so a
CREATE2 deploy hands both to a stub that can call nothing and bricks the factory permanently.
Plan D2.

## Licence

GPL-2.0-or-later, following Infinity.
