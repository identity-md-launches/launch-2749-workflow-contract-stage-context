# Contract and frontend ABI handoff

The exported JSON files are ABI arrays generated from Solidity 0.8.26 artifacts:

- `abi/HamsterMiningReserve.json` — application, including inherited ERC-20 and
  Ownable2Step functions/events and custom errors.
- `abi/IGraphAMining.json`, `abi/IGraphACore.json`, `abi/IGraphANFT.json` — the
  exact external subset used here. These are interfaces, not additional contracts
  to include in a launch manifest.

Regenerate with `forge build && python3 tools/export-abi.py`. Check for drift with
`python3 tools/export-abi.py --check`. There are no linked libraries.

## Application methods

| Method | Caller | Meaning |
| --- | --- | --- |
| `constructor(address owner_)` | Launch factory | Explicit owner and initial strategist; zero ETH, no external calls |
| `activate()` | Owner, once | Verify Sepolia/Graph A and pin the discovered SQK token; emits `Activated` |
| `setStrategist(address)` | Owner | Replace the nonzero merge operator; emits `StrategistUpdated` |
| `deposit(uint256 tokenId, uint256 minShares) returns (uint256 shares)` | NFT owner | Permanently transfer a single approved live NFT and mint proportional shares |
| `merge(uint256 survivorId, uint256 donorId)` | Strategist | Merge two owned, activated equal levels, burn the donor and account for the bonus |
| `harvest() returns (uint256 amount)` | Anyone | Collect all live reserve IDs, credit the reward index; no caller reward |
| `claimRewards() returns (uint256 amount)` | Claimant | Transfer accounted SQK only to `msg.sender`; no implicit harvest |
| `renounceShares(uint256 shares)` | Share holder | Optional voluntary burn, keeping accrued SQK; never returns NFTs or burns the entire supply |
| `transfer(address,uint256)`, `transferFrom(address,address,uint256)` | Holder / approved spender | Settle funded rewards, then move future participation rights |
| `approve`, `allowance`, `balanceOf`, `totalSupply`, `name`, `symbol`, `decimals` | ERC-20 semantics | 18-decimal accounting shares; no mint/pool/sale interface |
| `owner`, `pendingOwner`, `transferOwnership`, `acceptOwnership`, `renounceOwnership` | Ownable2Step semantics | Explicit two-step ownership handoff; strategist does not automatically change |

`Deposited` records contributor, NFT, final contributed weight, shares and carried
SQK. `Merged` records survivor, donor, new level and total final weight. `Harvested`
records the actual new SQK amount and global index. `RewardsClaimed` records a
payout; standard `Transfer` records share movements, mints and burns.

## Live reads for the later static website

Read from a Sepolia RPC at one consistent block. No backend private key, Graph B
API or fabricated deployment address is needed. If the service handoff has not
provided the deployed vault address, show an explicit unconfigured state and do
not issue calls to a made-up address.

| UI datum | Read and interpretation |
| --- | --- |
| Deployment / ownership | Chain ID 11155111, confirmed vault address, `activated()`, `owner()`, `strategist()` |
| Share balance and supply | `balanceOf(account)`, `totalSupply()`; format with share `decimals()` |
| Current claim | `claimableRewards(account)` in SQK base units; excludes unharvested Mining rewards |
| Pool's unharvested funded SQK | `pendingMiningRewards()`; do not add this pool-wide amount directly to each holder's balance |
| Current/future weight | `miningWeights()` returns actual active weight and pending *increase*; `totalWeight()` is final level-based share-pricing weight |
| NFT inventory | `reserveCount()`, `liveTokenIds()`, `reserveLevel(id)`; at most 32 live IDs |
| Individual position | `Mining.position(0,id)`; level, active weight, pending replacement weight, pending round, Core-height cooldown |
| Deposit quote | `previewDeposit(id)`; provisional, not a guarantee of ownership, approval or capacity; submit `minShares` |
| Rewards collected / paid | `totalRewardsReceived()`, `totalRewardsPaid()`; donations are excluded |
| Dependency addresses | `CORE()`, `MINING()`, `NFT()`, `MINING_IMPLEMENTATION()`, `rewardToken()` after activation |
| Graph NFT figures | `SqueekNFT.publicMinted()`, `totalSupply()`; historical reference values are not hardcoded live stats |
| Settled work / Squeek blocks | `Core.state()`; use its `blockHeight` for merge cooldowns, not `eth_blockNumber` |
| Checkpoint backlog | `Mining.checkpointStatus()`; `roundSettled` means another checkpoint can advance funding |

A disconnected, wrong-chain, not-yet-activated or failed-RPC state must be shown
as such. Do not display a failed read as zero. Funded, unharvested rewards and
uncertified physical work are different quantities. No fixed APY is promised.

## Tuple layouts

All types below preserve ABI declaration order and integer width.

`Mining.position(uint8,uint256)` returns:

```text
(uint64 activeWeight, uint64 pendingWeight, uint40 pendingRound,
 uint48 nextMergeBlock, uint8 level, uint256 lastIndex, uint256 accruedScaled)
```

Level 0 is dead/nonexistent. A nonzero `pendingRound` means `pendingWeight`
will **replace** active weight. For example, immediately after merging level 1s,
active weight is 2000 and pending replacement weight is 3000, not an extra 3000.
`accruedScaled` uses Mining's 2^128 scale, not the vault's reward-index scale.

`Mining.configuration()` returns:

```text
(address core, bytes32 streamId, address governance, address token,
 address genesisCollection, uint64 genesisTimestamp, uint16 genesisMaxSupply,
 uint64 maxWorkPerRound, uint64 minimumTimelockDelay, uint128 supplyCap,
 uint8 genesisMaximumLevel, uint32 initialWorkPerThousandBlocks)
```

`Core.state()` returns:

```text
(uint64 settledThroughRound, uint64 cumulativeWork, uint96 cumulativeBlockUnits,
 uint64 blockHeight, uint96 blockProgress, uint32 workPerThousandBlocks,
 uint256 authorizationNonce, bool paused)
```

`Mining.deploymentIdentity()` is implemented by the proxy itself and returns the
current implementation and its admin. The vault compares the implementation to
the required v6 address, as well as checking the implementation's self-report.

## Error handling

| Error | User/operator response |
| --- | --- |
| `NotActivated` | Owner must successfully call `activate()` first |
| `WrongChain` / `UnsupportedImplementation` / `InvalidGraph` | Check chain, deployed graph and version; no owner override exists |
| `ReserveFull` | Current live reserve has 32 NFTs; a valid merge frees one slot |
| `InvalidDeposit` / `InvalidPosition` | Verify ownership, Genesis collection, live level and weight |
| `PendingActivation` | Wait for Graph A settlement and checkpoint the scheduled activation |
| `MinimumSharesNotMet` | Refresh quote and review the new minimum; never silently retry with zero |
| `CheckpointRequired` | Advance Mining's bounded checkpoints directly until caught up, then retry |
| `MergeCooldown` | Wait for the supplied Squeek Core height, not a fixed wall-clock duration |
| `OnlyStrategist` / Ownable errors | Use the authorized role |
| `InvalidExit` | Burn must be positive and smaller than outstanding supply; transfer is the normal exit |
| `InvalidRewardPayment` / SafeERC20 errors | Underlying payment failed; transaction and claim credit rolled back |
| `UnexpectedNFT` | Use `deposit` rather than an unsolicited safe transfer |

Graph A may also propagate its own pause, activation, authorization, claim and
settlement errors. A failed transaction does not move an NFT, change share supply,
consume accrued credit or partially apply a merge.
