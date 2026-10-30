# Additional reserve tests

These tests build on the accepted unit tests, behavioral Graph A mocks, historical
runtime/storage replay, and variable-supply reserve invariant. Production code,
dependencies, ABI exports, launch artifacts and Foundry configuration are unchanged.

## Coverage and property selection

The five discovery passes in the supplied Pashov reference were applied to the
permanent reserve. The Trail of Bits reference informed the independent oracle,
explicit boundary cases, constrained inputs, and interpretation of failures.

| Discovery pass | Property and evidence | New coverage |
| --- | --- | --- |
| Conservation | Funded SQK is either in Mining, in the reserve or paid to a holder. Donations add assets without adding liabilities. Minted shares stay with depositors or their transferees. | `RewardOwnershipInvariant.t.sol` independently tracks funded, distributed, donated and paid amounts, and every holder's shares. |
| State transitions | Failed transactions undo checkpoints, harvested SQK, receiver state, approvals, custody and share accounting. Merges add exactly 1000 final weight and remove one donor without minting shares. | `SettlementAtomicity.t.sol`, all nine mergeable levels in `ShareArithmetic.t.sol`, and custody invariants. |
| Round trips and rounding | Claim timing and reversible transfers cannot create or discard historical entitlement. A deposit's share price respects integer rounding and its minimum-share bound. | Exact per-holder invariant; two 1000-run fuzz properties; explicit one-wei fractions and one-share supply cases. |
| Adversarial behavior | An unapproved spender, revoked strategist, false claim report or forged NFT receipt cannot change assets or claims. Actual NFT custody is required in addition to the receiver callback. | Rollback matrix across all five settling actions; allowance and balance failures; missing, repeated and forged callbacks; dependency and position validation. |
| Protocol-specific properties | This is a permanent NFT reserve with ERC-20 accounting shares. A share exit preserves the sender's accrued SQK. Merge donors are burned; surviving NFTs remain in custody. | Real fork cycle with distinct holders, delegated/full-balance transfers and reward ownership invariants. ERC-4626 redemption properties do not apply. |

The existing `ReserveInvariant.t.sol` continues to mix deposits, carried rewards,
merges, burns, transfers, harvests and claims over changing supply. The additional
oracle deliberately keeps supply at 4000 ether across four holders. For each
distribution it adds `amount * sharesOwnedAtThatInstant` to each holder's lifetime
entitlement numerator. Dividing by the fixed supply gives that holder's total
whole-token entitlement. This uses neither the reserve's reward index nor its
fraction implementation.

Because the reserve's precision is exactly divisible by this fixed supply, the
oracle has no distribution-level rounding tolerance: paid plus claimable must
equal the independently computed entitlement for each holder. The combined
unclaimed fractional dust is strictly less than four token base units. A final
harvest and claim by every actor checks that outstanding claims can actually be
paid. Inline configuration runs 256 sequences of 128 actions with reverts treated
as failures; explicit zero, one-unit and full-balance branches supplement random
interior amounts. The existing changing-supply invariant remains complementary.

`SettlementAtomicity.t.sol` prepares both funded rewards and a deferred checkpoint
before testing a failure. Its fingerprint includes reward indexes and fractions,
share balances and allowances, live IDs and levels, all three mining positions,
checkpoint/claim counters, SQK supply/balances and NFT custody/approval. Successful
retries demonstrate that a reverting guard or NFT handshake does not remain stuck.

## Live fork and offline behavior

`GraphAPinnedFork.t.sol` is part of the default `test/` suite. Its setup reads only
`vm.envOr("SEPOLIA_RPC_URL", string(""))`, skips only when that value is empty, and
forks exactly Sepolia block **12029130**. It checks chain ID and height. Dependency
code, storage, balances and time come from the fork; the only impersonation is
for local NFT owner actions and test vault roles. No network transactions are sent.

Seven cases exercise activation and wiring; reverse-order deposits of real IDs
12 and 13 by distinct holders; a real merge, donor burn and pending weight bonus;
SQK payouts after an entire share balance is transferred away; minimum-share
failure and retry; ownership/approval/replay failures; unsolicited safe transfer;
invalid claim batches; and rejection of a genuinely pending external merge.

The existing offline replay retains the historical block **12019224** acceptance
figures. It is a partial storage replay and is not used to stand in for the new
fork tests. Future certified work and rewards are exercised with behavioral mocks.

## Requirements discrepancy

The approved brief assigns version 6 and `claimable` to Core. At the required live
fork, Core reports **3** and reverts on `claimable(0,[12,13])`; Mining reports **6**
and returns **12461377786582968289288** for that call. Two scratch tests asserting
the literal Core requirements were run and failed for those reasons. The accepted
implementation and its documentation already use the observed Core/Mining split.
This remains a requirements finding in `.imd-findings.json`; passing the integration
tests does not establish satisfaction of the conflicting wording.

## Reproduction

Use the supplied RPC environment variable for the live run. The endpoint's value
is never stored in this repository. No additional packages are required.

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_FUZZ_SEED=0xaf59df9bcc9ccfe0c20638b0ac269b69bfaef4e3222da45b440a163aaa6e8934 forge test --out test/scratch/out --cache-path test/scratch/cache --no-storage-caching
env -u SEPOLIA_RPC_URL FOUNDRY_FUZZ_SEED=0xaf59df9bcc9ccfe0c20638b0ac269b69bfaef4e3222da45b440a163aaa6e8934 forge test --out test/scratch/out --cache-path test/scratch/cache --no-storage-caching
```

Scratch outputs are disposable. No submitted test imports or reads anything from
`test/scratch/`; the verifier can remove it before building.

## Local check results

All checks used the seed shown above.

| Check | Result |
| --- | --- |
| `forge build` | Passed; existing source/dependency linter advisories remain. |
| Complete suite with supplied RPC | 81 Foundry-reported results passed, zero failures or skips. All seven new fork cases reached block 12029130. |
| Complete suite without RPC variable | 74 passed, zero failures; Foundry reports the fork suite's skipped `setUp` as one skip. |
| New arithmetic fuzzing | Two properties, 1000 runs each, passed. |
| New entitlement invariant group | Three properties, 256 runs × 128 calls = 32,768 actions, zero reverts. |
| Existing changing-supply invariant group | Three properties, 128 runs × 64 calls = 8192 actions, zero reverts. |

Foundry groups each contract's three invariant properties into one reported result.
The two intentionally failing requirements probes were scratch diagnostics, not
submitted tests; their concrete inputs and results are in the finding report.
