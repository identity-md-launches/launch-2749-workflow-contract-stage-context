# Verification record

Verified locally with Foundry 1.8.3, Solidity **0.8.26**, optimizer 200, Cancun,
`bytecode_hash = "none"`, and the assignment's fuzz seed:

```text
0xaf59df9bcc9ccfe0c20638b0ac269b69bfaef4e3222da45b440a163aaa6e8934
```

These are contributor checks, not independent review, service admission, or a
security audit.

## Results

| Check | Result |
| --- | --- |
| `forge build` | Pass |
| Default `forge test` | 52 Foundry-reported tests/groups pass: 48 unit/fuzz tests, 3 Graph A replay tests, 1 group containing 4 invariants |
| Reviewer proof `Proof_ffd6e6bcb7aa.t.sol` (supply collapse) | Failed on the previous tree, passes on this one |
| Fuzz functions | 2 functions × 256 runs |
| Stateful invariant group | 128 runs × 64 actions = 8192 calls; zero reverts; `fail_on_revert = true` |
| Live Sepolia fork, block 12019224 | 3 tests; not re-run on this revision (no network on the worker); the shared assertions were re-run offline through the replay |
| `forge fmt --check` | Pass |
| `python3 tools/export-abi.py --check` | Pass |
| Application runtime size | 15,200 bytes, below EIP-170's 24,576 |
| Application creation code | 16,008 bytes before its one static constructor word |
| External library links | None |
| Constructor with graph code removed | Pass; explicit owner retained and zero share supply |
| Application runtime escape-opcode scan | Pass; no reachable DELEGATECALL, CALLCODE or SELFDESTRUCT under the protected floor's scan |

Foundry's build linter also emits advisory warnings about bounded external-call
loops, event ordering and reentrancy. The public asset/share entry points are
protected by ReentrancyGuard, required events are present, and the callback and
failure tests exercise the corresponding interactions. These warnings are not
represented as an independent static-analysis pass. Slither and Mythril were
not run.

## What the tests establish

`HamsterMiningReserve.t.sol` covers first and later deposits, proportional
weight/share pricing, preservation of the merge bonus, depositor-owned incoming
credit, sorted live claims, reward handoff on transfer and transferFrom, allowance
checks, checkpoint-before-share-change, multi-checkpoint backlog, pauses, pending
activation, Core-height cooldowns, max-level and malformed merges, failed donor
burns, claim failures, inaccurate reward reports, false token transfers,
unauthorized actions, unsolicited NFTs, donations, repeat actions, minimum shares,
reserve capacity, the voluntary-burn floor (exact boundary, exact proportional
deposits of every level after a maximal burn, merges after a maximal burn),
the merge `maxSupply` guard against a front-running deposit, exits during a Core
pause, and a Mining identity change that stops merges but not harvesting,
deposits, transfers, burns or claims.

`AccessAndReentrancy.t.sol` covers explicit ownership under factory-style
construction, no constructor dependency reads, activation authorization and
one-shot behavior, chain/version/implementation/wiring/level/token failures,
proxy identity versus a spoofed implementation self-report, Ownable2Step,
strategist rotation, refusal of `renounceOwnership` before activation, reentry
from ERC-721 transfers and SQK collection/payout, absence of owner asset
extraction, and the protected runtime size/opcode floor.

`ReserveInvariant.t.sol` interleaves deposits with carried credit, new rewards,
harvests, arbitrary partial transfers, claims, voluntary burns (including burns
exactly to the floor) and valid merges across three holders. It checks physical
SQK conservation, claim backing, share/balance conservation, permanent custody,
sorted unique live IDs, levels, tracked final weight and that supply never falls
below 1e7 share units per weight unit after every action. Deposits in the
handler have no rounding guard: every level must remain depositable after any
sequence. The handler avoids only the deliberate capacity limit; dedicated
failure tests cover it.

`GraphAAssertions.sol` is shared by the live-fork and offline-replay tests. It
checks the exact historical amount and NFT supply figures, the selector and ABI
tuple layouts, Core v3 / Mining v6 attribution and implementation, a deposit of
real IDs 12 and 13 followed by a real merge, donor burn, pending bonus, carried
SQK payouts and share transfer. It also checks real Mining's unauthorized,
unsorted, duplicate and dead-ID failures. The fork only impersonates NFT owners
for local approvals and deposits; it sends no network transaction.

The real merge's new bonus is scheduled for a future Graph A round. The pinned
fork cannot certify future physical work. Future funding/activation, continuing
pro-rata distributions and long mixed sequences are therefore exercised in the
local behavioral mocks, not claimed as already observed future on-chain rewards.

## Offline replay provenance and limits

The default suite includes all needed dependency source and fixture data.
`GraphAReplayTest` loads six original runtime byte sequences and 50 storage words
read from the archive fork, with no RPC, file-reading permission or environment
access. It runs the same three assertions as the live integration suite.

```text
chain:      11155111
block:      12019224
block hash: 0x415526f82a22ebc9a1c14af7e0f6c06cfa9bdf755f6cdbac58a967ad949f0f2c
state root: 0x40ad3d3976d30759d1d3485a2b897ede345a4b743dd8448e411c09835274907e
```

The fixture is a **partial accessed-state replay**. Unrecorded storage is zero in
the offline EVM; arbitrary new integration scenarios must first be run live and
recaptured. Runtime hashes, addresses and slot counts are in
`test/fixtures/graph-a-snapshot.json`. The fixture does not prove the state root;
the live archive RPC is the source of the recorded data. An optional second RPC
comparison matched all 28 responses it could serve; 28 other reads returned
`historical state ... is not available`. That partial comparison is not treated
as full independent verification.

To reproduce the fixture from a fresh record, run the read-only recorder and the
fork test in the same local network namespace. In one terminal:

```sh
python3 tools/capture-fork.py \
  --upstream https://sepolia.rpc.sentio.xyz \
  --output test/scratch/graph-a-rpc.json
```

In another terminal:

```sh
FOUNDRY_PROFILE=fork FOUNDRY_FUZZ_SEED=0xaf59df9bcc9ccfe0c20638b0ac269b69bfaef4e3222da45b440a163aaa6e8934 forge test \
  --fork-url http://127.0.0.1:18545 \
  --fork-block-number 12019224 --no-storage-caching
python3 tools/generate-snapshot.py test/scratch/graph-a-rpc.json
forge fmt
```

The recorder permits only read methods needed by Foundry, caches pinned responses
and never broadcasts or signs. The generator checks that recorded code/storage
reads are pinned to the same block number/hash. Recordings and logs in
`test/scratch/` are disposable; the generated fixture and its metadata are the
submitted artifacts. Nothing in `test/scratch/` is required by a build or test.

## Review boundary

The exact Core/Mining attribution conflict and additional model decisions are
listed in `README.md` and `docs/SECURITY.md`. The protected floor's rehearsals
cannot prove application correctness, custody economics or the authorization of
manifest values. A separate reviewer must assess accepted source and manifest;
services must perform their own artifact linkage, policy checks and complete
transaction simulation. This assignment neither creates nor approves a manifest.
