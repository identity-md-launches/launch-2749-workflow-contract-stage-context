# Security design and review handoff

This is a design/self-check record, not an independent audit. The separate review
assignment must evaluate the accepted source and manifest before release.

## Assets and authority

Only the vault can mint shares (after verified NFT custody) or burn shares (the
caller's voluntary renunciation). No shares are preminted, sold, granted to the
owner or minted on merges. Ownership is initialized from the explicit constructor
argument and handed over with Ownable2Step. The owner only activates once and
appoints the merge strategist. The strategist cannot choose a reward beneficiary,
withdraw an NFT, spend SQK, change level weights or add a collection.

All reserve NFTs remain owned by the vault except donors destroyed by Graph A
Mining's merge. There is no arbitrary call, NFT approval to an external operator,
rescue, ETH transfer, swap, proxy or upgrade mechanism in the application. The
already-deployed Graph A dependencies include proxies and are external trust
assumptions, not proxies deployed by this assignment.

## Accounting invariants

Let `S` be share supply and `W` the sum of the final level weights of live tracked
NFTs. A noninitial deposit contributes `w` and mints `floor(w*S/W)` shares. First
supply is `w*1e18`. This avoids rewarding a new depositor for a previous merge:
merging leaves `S` unchanged and adds 1000 to `W`. NFT/token donations do not
increase tracked weight. A nonzero minimum-share bound protects a caller from
rounding or ordering changes. Zero-share deposits revert even with minimum zero.

Before any nontrivial share balance or supply change, Mining is advanced through
currently certified work (or the transaction reverts if one bounded checkpoint
is insufficient). Every tracked live NFT is then claimed in ascending order.
This prevents selectively unharvested funded rewards from following newly minted
or transferred shares. Incoming NFT credit is collected separately for its owner.

Rewards use a cumulative index at precision 1e36. Each holder is accrued before
its balance changes. Whole rewards and fractional remainders stay with the holder
when shares leave. Each payout clears accrued whole units before SafeERC20's
external transfer, and a failed transfer reverts the update. New collections use
actual balance deltas and require them to equal Mining's reported payment.

For an ordinary sequence without unsolicited SQK donations:

```text
SQK received = SQK paid + SQK in vault
sum(all accounted whole claims) <= SQK in vault
share supply = sum(holder balances) > 0 once a reserve exists
tracked weight = sum(1000*(2**level - 1) for live reserve NFTs)
```

Donations increase the physical balance without creating a liability. Per-claim
and per-distribution dust remains in the system. The final share supply cannot
be burned, preventing a reset that lets a later depositor capture old NFTs.
Voluntary burns can leave a very small supply, making later deposits round to
zero; those deposits fail rather than accepting an NFT for no shares. Transfer
remains the ordinary full exit.

## External calls and bounded work

OpenZeppelin ReentrancyGuard protects deposit, activation, merge, harvest,
reward claims, share transfers/transferFrom and renunciation. `_update` accrues
both accounts before changing ERC-20 balances. The ERC-721 callback is the one
necessary entry during a guarded deposit; it accepts only the designated NFT,
vault operator, depositor and ID, exactly once. A caller cannot use it to mint.

The reserve never claims caller-selected IDs. It maintains an ordered list of at
most 32, removes burned donors and only adds NFTs received by deposit. Operations
requiring a full settlement thus remain bounded. Core/Mining activation and
cooldown errors roll back the whole operation. Merge postconditions verify the
new level, combined old active weight, pending final weight and dead donor.

Claimed amounts are in native SQK base units; there is no hardcoded assumption
about SQK decimals inside allocation arithmetic. Share decimals and precision are
separate. Math.mulDiv avoids intermediate product overflow; per-user fractions
use mulmod. Shift arithmetic is Solidity, and there is no packed hash of dynamic
inputs or externally linked library.

## Concrete issues and operational assumptions for independent review

1. **Workflow/deployment attribution conflict:** the specified Core is v3 and has
   no Mining `claimable`. Mining is v6 at the required implementation and returns
   the specified historical claimable value. The application deliberately uses
   that actual split. The live fork and offline replay prove the observations;
   they do not amend the wording of the approved workflow.
2. **Transferable accounting share wording:** transfers implement the requested
   exit. No sale/pool is supplied. Standard ERC-20 shares can nevertheless be
   transferred into an independently created market; the application cannot
   promise absolute non-tradeability.
3. **Reward timing:** uncertified past work is unknowable to this vault. Shares
   can change before that work is certified. Allocation follows available
   certified/funded state, not retrospective time-weighted NFT ownership.
4. **External control:** Graph A governance/reporters can stop or alter settlement.
   The current Mining proxy's implementation is pinned, Core must advertise v3,
   and the SQK token is pinned on activation. A graph upgrade can freeze share
   movement and harvesting; accounted SQK can still be claimed. There is no
   migration or emergency NFT withdrawal. Review the permanent-custody choice.
5. **Liveness and capacity:** share changes need full funded settlement. A large
   checkpoint backlog requires permissionless direct Mining calls before retry.
   The fixed 32-live-NFT limit bounds gas and limits admission until merges free
   slots. Review worst-case activation/checkpoint gas on the service's simulation.
6. **Direct transfers:** unsafe NFT transfers and unrelated token donations are
   unrecoverable and mint no shares. No administrator receives a rescue privilege.
7. **Supply rounding:** burns are voluntary without principal redemption. Leaving
   only a few base share units can reject later zero-share deposit quotes.
8. **Deployment/manifest authorization:** one `address owner_` argument must be
   `$owner`. No factory/IMD role, proxy, initializer-by-factory, dynamic constructor
   argument, linked bytecode or payable constructor is needed. Owner activation
   occurs after launch; the deployer is not the operator.

No fee, royalty, treasury, relayer key, randomness service or price oracle is
introduced. There are no transactions to sign or broadcast in this contribution.
The security reference's patterns were checked against these concrete paths;
Slither and Mythril were not run, and no independent audit is claimed. A passing
runtime opcode/size rehearsal does not prove application correctness or service
admission. Services own signed artifact linkage and launch policy enforcement.
