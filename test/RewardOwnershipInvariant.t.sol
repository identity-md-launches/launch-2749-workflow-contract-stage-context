// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ReserveTestBase} from "./ReserveTestBase.sol";
import {HamsterMiningReserve} from "src/HamsterMiningReserve.sol";
import {MockSQK, MockNFT, MockMining, MockCore} from "./mocks/GraphAMocks.sol";

/// @dev An independent, exact entitlement oracle: each distribution contributes
/// amount * sharesOwnedAtThatInstant to an account's numerator. The denominator
/// stays fixed. This deliberately does not reproduce rewardPerShare/rewardIndex.
/// Deposits and burns that change the denominator are covered by ReserveInvariantTest.
contract RewardOwnershipHandler is Test {
    uint256 public constant SUPPLY = 4000 ether;
    HamsterMiningReserve public immutable vault;
    MockMining public immutable mining;
    MockSQK public immutable sqk;
    address[4] public actors;
    uint256[4] public shares;
    uint256[4] public entitlementNumerator;
    uint256[4] public paid;
    uint256 public funded;
    uint256 public pending;
    uint256 public distributed;
    uint256 public donated;
    uint256 public merges;

    constructor(HamsterMiningReserve vault_, address[4] memory actors_) {
        vault = vault_;
        mining = MockMining(vault_.MINING());
        sqk = MockSQK(address(vault_.rewardToken()));
        actors = actors_;
        for (uint256 i; i < 4; ++i) {
            shares[i] = 1000 ether;
        }
    }

    function fund(uint256 idSeed, uint256 amountSeed) external {
        uint256[] memory ids = vault.liveTokenIds();
        uint256 amount = _amount(amountSeed, 1e26);
        mining.credit(ids[idSeed % ids.length], amount);
        funded += amount;
        pending += amount;
    }

    function donate(uint256 amountSeed) external {
        uint256 amount = _amount(amountSeed, 1e26);
        sqk.mint(address(vault), amount);
        donated += amount;
    }

    function harvest() public {
        uint256 amount = pending;
        _allocate();
        assertEq(vault.harvest(), amount, "harvest must collect the funded amount");
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        uint256 amount = _amount(amountSeed, shares[from]);
        _move(from, to, amount);
    }

    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        uint256 from = fromSeed % 4;
        _move(from, toSeed % 4, shares[from]);
    }

    function delegatedTransfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool infinite) external {
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        uint256 amount = _amount(amountSeed, shares[from]);
        if (amount != 0 && from != to) _allocate();
        vm.prank(actors[from]);
        vault.approve(address(this), infinite ? type(uint256).max : amount);
        assertTrue(vault.transferFrom(actors[from], actors[to], amount));
        assertEq(vault.allowance(actors[from], address(this)), infinite ? type(uint256).max : 0);
        shares[from] -= amount;
        shares[to] += amount;
    }

    function roundTrip(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        uint256 amount = _amount(amountSeed, shares[from]);
        uint256 initialFrom = shares[from];
        uint256 initialTo = shares[to];
        _move(from, to, amount);
        uint256 creditFrom = vault.claimableRewards(actors[from]);
        uint256 creditTo = vault.claimableRewards(actors[to]);
        _move(to, from, amount);
        assertEq(shares[from], initialFrom);
        assertEq(shares[to], initialTo);
        assertEq(vault.claimableRewards(actors[from]), creditFrom, "round trip created a claim");
        assertEq(vault.claimableRewards(actors[to]), creditTo, "round trip moved a historical claim");
    }

    function claim(uint256 actorSeed) public {
        uint256 who = actorSeed % 4;
        uint256 expected = entitlementNumerator[who] / SUPPLY - paid[who];
        uint256 beforeBalance = sqk.balanceOf(actors[who]);
        vm.prank(actors[who]);
        uint256 actual = vault.claimRewards();
        assertEq(actual, expected, "payout belongs to the historical share owner");
        assertEq(sqk.balanceOf(actors[who]) - beforeBalance, expected);
        paid[who] += expected;
        vm.prank(actors[who]);
        assertEq(vault.claimRewards(), 0, "a claim cannot be paid twice");
    }

    function merge(uint256 seed) external {
        uint256[] memory ids = vault.liveTokenIds();
        if (ids.length < 2) return;
        mining.activatePending();
        MockCore(vault.CORE()).setHeight(1_000_000);
        uint256 survivor = ids[seed % ids.length];
        uint8 level = vault.reserveLevel(survivor);
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == survivor || vault.reserveLevel(ids[i]) != level) continue;
            _allocate();
            vault.merge(survivor, ids[i], vault.totalSupply());
            ++merges;
            assertEq(vault.reserveLevel(ids[i]), 0, "burned donor remains tracked");
            assertEq(vault.reserveLevel(survivor), level + 1);
            return;
        }
    }

    function _move(uint256 from, uint256 to, uint256 amount) private {
        if (amount != 0 && from != to) _allocate();
        vm.prank(actors[from]);
        assertTrue(vault.transfer(actors[to], amount));
        shares[from] -= amount;
        shares[to] += amount;
    }

    function _allocate() private {
        for (uint256 i; i < 4; ++i) {
            entitlementNumerator[i] += pending * shares[i];
        }
        distributed += pending;
        pending = 0;
    }

    /// @dev Bias toward zero, one base unit and the entire balance as well as interiors.
    function _amount(uint256 seed, uint256 maximum) private pure returns (uint256) {
        if (maximum == 0 || seed % 4 == 0) return 0;
        if (seed % 4 == 1) return 1;
        if (seed % 4 == 2) return maximum;
        return bound(seed, 0, maximum);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract RewardOwnershipInvariantTest is StdInvariant, ReserveTestBase {
    RewardOwnershipHandler internal handler;
    address internal fourth;

    function setUp() public override {
        super.setUp();
        fourth = makeAddr("fourth reward holder");
        _deposit(alice, 12, 1);
        _deposit(bob, 13, 1);
        _deposit(carol, 14, 1);
        _deposit(fourth, 15, 1);
        handler = new RewardOwnershipHandler(vault, [alice, bob, carol, fourth]);
        vm.prank(owner);
        vault.setStrategist(address(handler));
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.harvest.selector;
        selectors[3] = handler.transfer.selector;
        selectors[4] = handler.transferAll.selector;
        selectors[5] = handler.delegatedTransfer.selector;
        selectors[6] = handler.roundTrip.selector;
        selectors[7] = handler.claim.selector;
        selectors[8] = handler.merge.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_EachHolderReceivesExactlyTheirHistoricalEntitlement() public view {
        uint256 numeratorSum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 numerator = handler.entitlementNumerator(i);
            assertEq(vault.balanceOf(actor), handler.shares(i));
            assertEq(vault.claimableRewards(actor) + handler.paid(i), numerator / handler.SUPPLY());
            assertEq(sqk.balanceOf(actor), handler.paid(i));
            numeratorSum += numerator;
        }
        assertEq(numeratorSum, handler.distributed() * handler.SUPPLY());
    }

    function invariant_RewardConservationIncludesDonationsAndUnharvestedFunds() public view {
        uint256 paid;
        uint256 claims;
        for (uint256 i; i < 4; ++i) {
            paid += handler.paid(i);
            claims += vault.claimableRewards(handler.actors(i));
        }
        assertEq(vault.totalRewardsReceived(), handler.distributed());
        assertEq(vault.totalRewardsPaid(), paid);
        assertEq(sqk.balanceOf(address(mining)), handler.pending());
        assertEq(handler.funded(), handler.distributed() + handler.pending());
        assertEq(sqk.balanceOf(address(vault)) + paid, handler.distributed() + handler.donated());
        assertLe(claims + paid, handler.distributed());
        // Exact denominator: each of the four holders can leave less than one wei of dust.
        assertLt(handler.distributed() - paid - claims, 4);
    }

    function invariant_MergesIncreaseWeightWithoutIssuingSharesOrReleasingCustody() public view {
        assertEq(vault.totalSupply(), handler.SUPPLY());
        assertEq(vault.totalWeight(), 4000 + 1000 * handler.merges());
        assertEq(vault.reserveCount(), 4 - handler.merges());
        assertEq(nft.balanceOf(address(vault)), vault.reserveCount());
        uint256[] memory ids = vault.liveTokenIds();
        for (uint256 i; i < ids.length; ++i) {
            assertEq(nft.ownerOf(ids[i]), address(vault));
            if (i != 0) assertGt(ids[i], ids[i - 1]);
        }
    }

    function afterInvariant() public {
        handler.harvest();
        for (uint256 i; i < 4; ++i) {
            handler.claim(i);
        }
        invariant_EachHolderReceivesExactlyTheirHistoricalEntitlement();
        invariant_RewardConservationIncludesDonationsAndUnharvestedFunds();
        assertEq(sqk.balanceOf(address(mining)), 0);
    }
}
