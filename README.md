# Hamster Mining Reserve (HMR)

A Sepolia vault that permanently pools Graph A Squeek mining NFTs. Depositors
receive ERC-20 accounting shares (`hmSQUEEK`); a strategist merges equal-level
NFTs; holders claim their proportion of funded SQK rewards. The vault is one
application contract, `HamsterMiningReserve`, with no premint, token sale,
liquidity pool, fee, withdrawal of NFTs, administrative sweep, or upgrade path.

This delivery covers the contract stage: implementation, tests, ABI exports, and
the deployment/operations handoff. The manifest, independent review, source
publication, attestation, admission, deployment, and IPFS frontend release are
subsequent contributions/services. No `launch.json` or deployment transaction is
produced here.

## Build and verify

Requires Foundry and Solidity **0.8.26**, pinned in `foundry.toml`. OpenZeppelin
5.0.2 and forge-std 1.9.7 are vendored as ordinary files. The default suite needs
no network, environment values, signing key, or filesystem cheatcode permissions.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xaf59df9bcc9ccfe0c20638b0ac269b69bfaef4e3222da45b440a163aaa6e8934 forge test
forge fmt --check
python3 tools/export-abi.py --check
```

The live integration suite uses the same assertions as the offline replay:

```sh
FOUNDRY_PROFILE=fork FOUNDRY_FUZZ_SEED=0xaf59df9bcc9ccfe0c20638b0ac269b69bfaef4e3222da45b440a163aaa6e8934 forge test \
  --fork-url https://sepolia.rpc.sentio.xyz \
  --fork-block-number 12019224 --no-storage-caching -vv
```

An archive RPC is required for this optional live run. The offline replay installs
actual recorded runtime bytes and only the storage words accessed by these
assertions, using `vm.etch` and `vm.store`. It is neither a complete chain snapshot
nor a proof of the state root. It replays the recorded scenarios; the separately
run live fork verifies them against the archive node. See
[`docs/TESTING.md`](docs/TESTING.md) for results, coverage, and reproduction.

## Graph A interpretation and resolved choices

The approved workflow attributes Mining methods and version 6 to **Core**. The
named deployed graph instead has **Core v3** and **Mining v6**. The implementation
uses Mining for `position`, `claimable`, `merge`, and `claim`, and reads Core
explicitly for its identity and Squeek block height. This resolves the prior
`needs_input` result without inventing a new graph or silently requiring an
impossible Core version. The attribution conflict remains explicit for the
independent reviewer.

| Contract | Sepolia address | Use |
| --- | --- | --- |
| Core v3 | `0x74665dAecA35A2303e767E76a2FF1FB6F93e119f` | Direct identity/height read; settlement dependency |
| Mining v6 proxy | `0x3beE588fC20dE788Bac17d33b41Da7346cb27EC4` | Positions, checkpoints, merge, rewards |
| Required Mining implementation | `0x08890b360C65FD878344Bf6e23d1c36358433B4E` | Proxy identity and implementation self-identity must agree |
| SqueekNFT | `0x0eAF3E0d40A0a8E5a6Ac030b2459E9FB0B7905c6` | Genesis collection only (`collection = 0`) |
| SQK, discovered from Mining | `0x6872BfA5CcC3E9e440C6c16e5fFdAbb8DBA4Cc76` | Observed at the pinned block; activation reads and permanently stores Mining's token |

At **block 12,019,224**, the live tests establish:

- `Mining.claimable(0, [12,13]) = 12461377786582968289288` SQK base units
  (`12461.377786582968289288` SQK).
- Core reports version 3 and reverts on the `claimable` selector.
- Mining reports version 6, the required implementation, and the named Core.
- NFT `publicMinted() = 8888` and `totalSupply() = 6910`.

No application code calls a Graph B API or any HTTP endpoint. Source/ABI
provenance is in [`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md).

Other choices left open by the workflow:

- **Live reserve capacity: 32 NFTs**, matching Mining's `MAX_CLAIMS`. Every share
  balance/supply change settles the entire live reserve in one bounded claim.
  Merges free capacity. This avoids stale rewards and an unbounded gas loop, at
  the cost of a deliberate capacity limit; it is not a limit of 32 depositors.
- **Initial denomination: 1e18 share units per weight unit**, with 18 share
  decimals. Level 1 contributes 1000 weight and initially mints 1000 hmSQUEEK.
  Later deposits use the current proportional share price.
- **Level weight: `1000 * (2**level - 1)`**, levels 1–10. A merge adds 1000 final
  weight but its bonus becomes active only after Mining's scheduled activation.
  Share pricing includes that promised bonus immediately so a later depositor
  cannot dilute existing holders' merge gain.
- **Reward precision: 1e36**. User fractions survive transfers, claims and burns;
  per-harvest division dust and unsolicited token donations remain in custody.
  There is no dust-sweep privilege.
- **Strategist initially equals the explicit launch owner**; the owner can set
  another nonzero strategist. No separate operator address is invented.
- **Shares are transferable**, as required by the specified exit mechanism. They
  are internal accounting claims with no offered market or sale. An ordinary
  transferable ERC-20 cannot prohibit all independently created secondary trades.
- **Exit normally transfers shares to a willing recipient.** Optional
  `renounceShares` burns a caller's shares without NFT redemption and keeps their
  accrued SQK claimable. The last outstanding supply cannot be burned: otherwise
  a later first depositor could capture the entire permanent reserve.
- **Incoming NFT rewards:** already-funded SQK carried by an incoming NFT belongs
  to its depositor, rather than being donated to previous pool holders. Mining's
  sub-base-unit fraction stays on the NFT and joins subsequent pool rewards.

These choices are named constants or explicit contract behavior, not deployment
inputs that require another requester answer.

## Deposit, merge, rewards and exit

1. After activation, a depositor owns a live Graph A Genesis NFT, waits for any
   pending weight activation, approves **this vault** for the NFT, and calls
   `deposit(tokenId, minShares)`. Only the caller's NFT can move. A zero ID,
   duplicate, inactive/malformed position, missing approval, full reserve or
   unacceptable share minimum reverts atomically. No batch supplied by a caller
   can introduce duplicate/dead claim IDs.
2. The vault checkpoints previously certified Mining work when necessary, then
   claims all existing reserve NFTs before minting shares. Incoming rewards are
   credited separately. Shares minted are `floor(weight * supply / totalWeight)`;
   the empty initial reserve instead uses `weight * 1e18`. There is no asset-price
   oracle or market-value claim. Direct NFT/token donations do not affect pricing.
3. The strategist calls `merge(survivorId, donorId)` for two live equal levels below
   10. Both must be activated and past their **Squeek Core block-height** cooldown,
   not Ethereum's block number. Mining burns the donor; the vault verifies the
   survivor's resulting level, current weight and scheduled final weight. Nobody,
   including the owner, can withdraw a reserve NFT or redirect it elsewhere.
4. Anyone can call `harvest()` to distribute already-funded SQK from all live IDs.
   Callers cannot choose a subset or a reward recipient. Internal claim IDs remain
   live and strictly ascending. New work must be settled by Graph A and funded via
   Mining's permissionless `checkpoint()` before it becomes claimable.
5. `claimRewards()` pays only the caller's accounted rewards in SQK base units.
   It does not implicitly harvest; call `harvest()` first for a fresh claim.
   Already-accounted payments remain available if Core pauses or Mining upgrades.
6. `transfer` and `transferFrom` settle funded rewards before moving nonzero shares
   between different accounts. Past rewards stay with the sender and future
   distributions follow the recipient. `renounceShares` does the same before
   burning. Share transfers to the vault itself are rejected to prevent accidental
   permanent loss of claims. Standard allowances apply to `transferFrom`.

The pool does not promise income for uncertified work. Allocation is based on
certified/funded rewards at settlement, not wall-clock NFT holding time. Graph A
may certify old work after membership changes; there is no oracle in this vault
that can attribute that as-yet-unknown reward to historical holders. This timing
exposure is an explicit assumption of this share model.

## Deployment parameters

Deploy one nonpayable application:

| Solidity contract | Constructor argument | Manifest handoff |
| --- | --- | --- |
| `HamsterMiningReserve` | `address owner_` | `$owner` |

The supplied launch owner is `0x2bbad01f50eae735f95050b62e3a7d0c4cf8f6ca`.
The deployment service resolves `$owner`. Factory `msg.sender` and `tx.origin`
never become owners. Constructor code performs no external call, requires no
other contract's code, creates no child contract and mints no shares. It can be
rehearsed on an empty chain. The build pins Solidity 0.8.26, Cancun, optimization
at 200 runs and `bytecode_hash = "none"`; all library calls are inlined.

Only the manifest contribution writes `launch.json`. The launch service supplies
the confirmed vault address; no predicted or fictitious address belongs in a
frontend configuration.

## After launch

The **owner**, not IMD, is responsible for activation and ongoing operation:

| Action | Who | Value/source and effect |
| --- | --- | --- |
| `activate()` once | Owner | Checks Sepolia, Graph A identity, NFT links, all ten level weights and limits. Reads SQK from `Mining.configuration().token` and pins it. No guessed token address or initialization transaction by the deployment factory is needed. Features revert `NotActivated` until this succeeds. |
| `setStrategist(address)` | Owner | Optional chosen operator; default is the owner. This operator can only perform validated merges. Setter emits `StrategistUpdated`. |
| `transferOwnership(address)` then `acceptOwnership()` | Current/new owner | Optional ownership handoff to the requester's chosen wallet or multisig. It does not automatically rotate an existing strategist; rotate that role explicitly. |
| `Mining.checkpoint()` | Anyone/keeper | Advances funded rounds and pending weight activations after Core settlement. If more than one bounded checkpoint is needed, call Mining directly until caught up, then retry share changes. |
| `harvest()` | Anyone/keeper | Claims all live pool IDs and updates the reward index. No keeper fee is charged or promised. |
| `merge(survivorId, donorId)` | Strategist | Select equal active levels, inspect pending rounds and Core-height cooldowns, then merge. |
| Frontend configuration | Frontend/service operator | Use the confirmed deployed vault address from the service handoff and chain 11155111; use the supplied ABI files and direct RPC reads. See `docs/ABI.md`. |

There are no requester-held keys, registry IDs, signers, fees or subscription
values to fabricate or defer. SQK is deterministically discovered from the pinned
graph. Do not renounce ownership before activation; doing so disables activation
permanently. Renouncing later removes owner management while leaving the last
strategist in place.

## Trust and limitations

NFT contributions are irreversible. An unsafe ERC-721 `transferFrom` directly to
the vault bypasses receiver checks, creates no shares, and strands that NFT; use
`deposit`. Unsolicited safe transfers are rejected. Untracked ERC-20 donations are
also not recoverable. The only normal asset outflow is accounted SQK to its
claimant; shares and NFTs carry no promised principal redemption.

Graph A's governance, Core reporter and underlying contracts remain external
trust dependencies. They control settlement, pauses and upgrades. The vault pins
Mining's actual proxy implementation and advertised identity and checks Core v3;
unsupported upgrades halt deposits, transfers, burns, merging and harvesting.
There is deliberately no owner bypass to accept a changed graph. Accounted SQK
can still be claimed if its token supports transfers. SQK transfers that fail
revert without consuming the user's credit. The design assumes Graph A's standard
non-rebasing, non-fee SQK token; a claim return inconsistent with the actual
balance delta is rejected.

Share changes require a working, caught-up Mining dependency. A paused Core with
certified but uncheckpointed rounds or an outstanding checkpoint backlog can
block them. Funded harvesting and accounted claims do not require new Core
settlement. There are no emergency NFT refunds, replacement graph addresses,
admin-controlled reward recipients, or promised keeper availability.

The owner appoints the strategist; a malicious or absent strategist can choose
poor timing or stop merges, but cannot extract reserve assets. Tests and the
supplied security checklist do not replace the separate independent review
required before release. This contribution does not claim deployment, explorer
verification, an audit, signed attestations or service admission.
