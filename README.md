# choice_v2_contracts

Choice's Solidity for Injective EVM: the pieces PancakeSwap Infinity does not have, plus the
deploy orchestration and the address book that every other v2 repo reads.

Plan and decision log: `choice_v2/CHOICE_V2_EVM_PLAN.md`.

## What is here

| Path | |
| --- | --- |
| `src/fees/` | `ChoiceFeeController` - `IProtocolFeeController` with Choice's tier policy, a permissionless harvest and the treasury / burn-auction split |
| `src/launchpad/` | `InfinitySettler` (`IGraduationSettler`: seeds a full-range CL pool and calls `onSettled`, all inside `triggerGraduation`), `PositionLocker` (holds the seed NFT forever; permissionless `collect` splits LP fees creator / launchpad) and `LaunchPoolGuardHook` (only a settler may create a graduation pool) |
| `src/router/` | `ChoiceRouter` - holds the intermediate token across a Choice -> Pumex handoff so one end-to-end `minimumReceive` can be enforced. Routes inside one deployment do NOT go through it and `execute` REFUSES them: `UniversalRouter`'s `INFI_SWAP` already runs a whole split, multi-hop route in a single Vault lock. It locks both Vaults itself rather than calling Pumex's UniversalRouter, which is pausable by a Safe outside Choice. There is no orderbook leg - an EVM `0x65` fill cannot be atomic (plan M5, 2026-09-05). ⚠️ Deployed on testnet 1439 but INERT there: only Choice's vault exists on that chain, so every route is single-deployment and `execute` reverts `NotCrossVault` until a second vault is allowlisted with `setVault` |
| `script/` | one ordered deploy run per network, wrapping the forks' numbered scripts |
| `deployments/` | **the** address book. Nothing else is authoritative |
| `lib/` | the three Infinity forks as submodules, pinned by commit |

## Layout rule

The forks' `src/` is never edited, so upstream's audits keep describing the bytecode we
deploy. Everything Choice-specific lives here. See each fork's `INJECTIVE_FORK.md`.

## Build

**Foundry is pinned to `v1.5.1`** — `foundryup --install v1.5.1`. CI installs that exact
version, because `forge fmt` output changes between releases and an unpinned toolchain makes
the format gate disagree with your machine. Bumping it is a deliberate PR: move the pin in
`.github/workflows/ci.yml` and commit the reformat with it.

```bash
git submodule update --init --recursive
forge build
forge fmt --check
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

- 🔴 **Broadcast WITHOUT `--slow`.** This file said the opposite until 2026-09-05 and it was
  wrong: `--slow` waits for a receipt Injective never serves, so it strands the run after its
  FIRST transaction. Without it every transaction is broadcast before the receipt polling
  fails, so they all land — the run then EXITS NON-ZERO with "Failure on receiving a
  receipt" for each. That is the expected ending, not a failure.
- 🔴 **Pass an explicit, generous `--gas-limit` on every write.** `eth_estimateGas`
  under-reports on Injective and the shortfall is silent: `initializePool` estimated 156k,
  reverted at 156k with no receipt to explain it, and landed at 1.5M. Use 3-5x plus a floor.
- Use the k8s testnet RPC or (mainnet) sentry / our own node. Never polkachu, which serves no
  receipts at all.
- **Never `--resume`.** If a run dies mid-way, replay `broadcast/<script>/<chainId>/run-latest.json`
  one `cast send` at a time after checking the nonce.
- Confirm every contract with `eth_getCode`, never with a receipt. A cheap extra check: the
  runtime sizes `forge build --sizes` prints must equal the deployed code lengths.
- Update `deployments/injective_<network>.json` in the same PR as the broadcast.

The create3 factory is deployed from a dedicated **nonce-0 EOA**, never through the Arachnid
CREATE2 deployer: `Create3Factory`'s constructor owns and whitelists to `msg.sender`, so a
CREATE2 deploy hands both to a stub that can call nothing and bricks the factory permanently.
Plan D2.

## Launchpad graduation (M4)

A SHROOM launch graduates onto a Choice v2 CL pool in the **same transaction that fills the
curve**. `LaunchpadCore.triggerGraduation` moves both legs to `InfinitySettler`, which
initialises the pool at exactly `realPair / poolTokenAmount`, mints one full-range position to
`PositionLocker`, and calls `LaunchpadCore.onSettled`. There is no keeper crank and no
`PendingSettlement` window: unlike the CosmWasm `Phase3Settler`, whose seed lands in another VM
where the EVM cannot see it, a CL mint either happened in this transaction or the transaction
does not exist.

Afterwards the seed position never moves. `PositionLocker.collect(launchId)` is permissionless
and pulls only fees - the plan hard-codes a liquidity delta of zero - splitting them
creator / launchpad treasury by the launch's own `creatorFeeShareBps`. Choice's own share of
the same swaps arrives separately, through `ChoiceFeeController.harvest`.

🔴 **Graduation costs 1,595,080 gas, measured on testnet — not the ~900k
`test_graduationGasBudget` pins.** The test is not wrong about what it measures; it cannot
measure the rest. Its mocks are plain ERC20s, while the real launch token and quote are MTS
bank ERC20s whose transfers run through the `0x64` precompile, and the core moves BOTH legs
inside `triggerGraduation` before the settler is even called. No forked local EVM can price
that, because `0x64` has no code to fork. Treat the unit budget as a floor on our half and
**size the sender off 1.6M**. Injective's `eth_estimateGas` under-reports too, so whatever
sends `triggerGraduation` needs an explicit, generous limit rather than an estimate — the
pad keeper's 5M is comfortable.

### The pool is un-campable, and that needs a hook

Initialising an Infinity pool is free, permissionless, and sets the price with no liquidity
behind it - and a launch token's address is public from `bindLaunchToken` onward. Anyone could
open the pool a graduation was going to use, at a price of their choosing, and take the
difference from the seed on the first arb. Refusing to seed a mispriced pool is a wedge, not a
defence: there are only four canonical tiers, so camping all of them costs four times the gas
of camping one.

`LaunchPoolGuardHook` closes it: `beforeInitialize` reverts unless the caller is an allowlisted
settler, so nobody else can create the pool at any price, funded or not. It registers
`beforeInitialize` and **nothing else**, which `Hooks.validateHookConfig` enforces at
initialize - so the hook is called exactly once in a pool's life and can never tax a swap,
block a withdrawal or freeze a pool afterwards, even if it broke. Infinity carries hook
permissions in `PoolKey.parameters` rather than in the hook's address bits, so no address
mining is involved. A griefer can still open a *hookless* pool for the same pair; that is a
different `PoolKey`, it holds no liquidity, and the graduation ignores it.

🔴 **The settler initialises through `CLPoolManager.initialize`, never
`CLPositionManager.initializePool`.** Two reasons, both load-bearing: the hook is handed the
`msg.sender` of the pool-manager call, so the position manager would mask the settler; and
`initializePool` wraps the call in a try/catch that **swallows every error**, so a rejection
would come back as `type(int24).max` instead of a revert.

Deploy with `script/05_DeployLaunchpadSettler.s.sol`. All three contracts are born owned by the
timelock — the locker and the hook are constructed already pointing at the settler, whose
CREATE3 address is known before it exists — so there is no ownership handoff and no
pending-owner window. One step is not ours: the **launchpad admin** must call
`setSeederFactory(<settler>)` on its core. Only launches created after that call graduate onto
v2; the pad snapshots the settler per launch, so everything in flight keeps the CosmWasm path.

✅ **This is live on testnet 1439 and has been walked end to end (2026-09-05).** The addresses
are in `deployments/injective_testnet.json`; the pad admin has flipped `setSeederFactory`, so
every new testnet launch now graduates here. Launch #13 filled its curve to its exact 10,950
USDC target and graduated under ONE transaction hash — pool initialised at
`realPair / poolTokenAmount`, one full-range position minted to the locker and registered,
`onSettled` called. The pool's `sqrtPriceX96` was **0 one block earlier and the exact target in
that block**, which is the whole atomicity claim in two reads. A swap each way then accrued
fees; `collect` paid creator 7000 / launchpad 3000 bps in both currencies, and `harvest` paid
Choice 3299 pips of each swap's input, to the pip. Both were called from an address that is
neither the creator nor an owner, which is what makes them permissionless rather than merely
documented as such. `meta.firstGraduation` in the address book carries the poolId, tokenId and
transaction: with no receipts served on Injective, those are the only durable handles on it.

### The one coupling to watch

`creator` and `creatorFeeShareBps` are not on any getter the deployed `LaunchpadCore` exposes;
its `launches` mapping is `internal` and `LaunchpadViews` decodes raw storage. So the settler
reads them with `extsload` at fixed word offsets. Three canaries make a wrong layout fail
closed rather than pay a decoded-from-garbage address - the state word must read
`PendingSettlement`, the settler word must be the settler itself, and the share must be a legal
bps - and `script/05` refuses to deploy unless two more decoded fields agree with the core's
own getters on a real launch.

🔴 **If the launchpad redeploys its core, re-check the layout.** `test/mocks/MockLaunchpadCore.sol`
carries the `Launch` struct verbatim so the compiler derives the packing, and the offsets were
last verified on 2026-09-05 against the live testnet core `0xb03f…a71d`, field by field against
`LaunchpadViews` at `0x60e1…156d`.

## Licence

GPL-2.0-or-later, following Infinity. The full text is in [LICENSE](LICENSE); [NOTICE](NOTICE)
records the upstream copyright, the two deliberately-MIT interfaces, and where the complete
corresponding source for every deployed contract lives.
