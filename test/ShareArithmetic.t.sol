// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReserveTestBase} from "./ReserveTestBase.sol";
import {HamsterMiningReserve} from "src/HamsterMiningReserve.sol";
import {IGraphAMining} from "src/interfaces/IGraphA.sol";

/// forge-config: default.fuzz.runs = 1000
contract ShareArithmeticTest is ReserveTestBase {
    function testFuzz_DepositAfterMergeAndBurnObeysRoundingBounds(
        uint8 levelSeed,
        uint8 incomingSeed,
        uint256 burnSeed
    ) public {
        uint8 level = uint8(bound(levelSeed, 1, 9));
        uint8 incomingLevel = uint8(bound(incomingSeed, 1, 10));
        _deposit(alice, 12, level);
        _deposit(bob, 13, level);
        vm.prank(owner);
        vault.merge(12, 13);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.transfer(alice, bobShares);
        uint256 burned = bound(burnSeed, 0, vault.totalSupply() - 1);
        if (burned != 0) {
            vm.prank(alice);
            vault.renounceShares(burned);
        }
        _mintNFT(carol, 14, incomingLevel);
        uint256 weightBefore = vault.totalWeight();
        uint256 supplyBefore = vault.totalSupply();
        uint256 addedWeight = mining.position(0, 14).activeWeight;
        uint256 preview = vault.previewDeposit(14);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(HamsterMiningReserve.MinimumSharesNotMet.selector, preview, preview + 1)
        );
        vault.deposit(14, preview + 1);
        assertEq(nft.ownerOf(14), carol);
        assertEq(vault.totalWeight(), weightBefore);
        assertEq(vault.totalSupply(), supplyBefore);

        if (preview == 0) {
            // Zero-share admission must fail without confiscating the incoming NFT.
            vm.prank(carol);
            vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.MinimumSharesNotMet.selector, 0, 0));
            vault.deposit(14, 0);
            assertEq(nft.ownerOf(14), carol);
            return;
        }
        vm.prank(carol);
        uint256 minted = vault.deposit(14, preview);
        assertEq(minted, preview);
        // Independent price inequalities, rather than duplicating the mulDiv implementation.
        assertLe(minted * weightBefore, addedWeight * supplyBefore);
        assertGt((minted + 1) * weightBefore, addedWeight * supplyBefore);
        assertGe(vault.totalWeight() * supplyBefore, weightBefore * vault.totalSupply());
        assertEq(vault.balanceOf(alice), supplyBefore);
        assertEq(vault.balanceOf(carol), minted);
        assertEq(vault.totalWeight(), weightBefore + addedWeight);
        assertEq(nft.ownerOf(14), address(vault));
    }

    function testFuzz_ClaimCadenceAndRepeatedShareRoundTripsPreservePayouts(
        uint96 rewardSeed,
        uint8 cyclesSeed
    ) public {
        _twoDepositors();
        uint256 amount = bound(rewardSeed, 1, 1e24);
        uint256 cycles = bound(cyclesSeed, 2, 24);
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < cycles; ++i) {
            mining.credit(12, amount);
            vault.harvest();
            _claim(alice);
            _claim(bob);
            vm.prank(alice);
            vault.transfer(carol, 1000 ether);
            vm.prank(carol);
            vault.transfer(alice, 1000 ether);
            assertEq(_claim(carol), 0, "round trip captured rewards from before ownership");
        }
        uint256 paidAlice = sqk.balanceOf(alice);
        uint256 paidBob = sqk.balanceOf(bob);
        uint256 dust = sqk.balanceOf(address(vault));
        assertTrue(vm.revertToStateAndDelete(snapshot));
        for (uint256 i; i < cycles; ++i) {
            mining.credit(12, amount);
            vault.harvest();
        }
        assertEq(_claim(alice), paidAlice, "claim frequency discarded or manufactured fractions");
        assertEq(_claim(bob), paidBob);
        assertEq(sqk.balanceOf(address(vault)), dust);
        assertEq(paidAlice, cycles * amount / 2);
        assertEq(paidBob, cycles * amount / 2);
        assertLe(dust, 1);
        _assertSolvent();
    }

    function testOneWeiFractionsStayWithTheFormerHolderAndSurviveReentry() public {
        _twoDepositors();
        mining.credit(12, 1);
        vault.harvest();
        assertEq(_claim(alice), 0);
        assertEq(_claim(bob), 0);
        vm.prank(alice);
        vault.transfer(bob, 1000 ether);
        mining.credit(12, 1);
        vault.harvest();
        assertEq(_claim(alice), 0);
        assertEq(_claim(bob), 1);
        vm.prank(bob);
        vault.transfer(alice, 1000 ether);
        mining.credit(12, 1);
        vault.harvest();
        assertEq(_claim(alice), 1);
        assertEq(_claim(bob), 1);
        assertEq(sqk.balanceOf(alice), 1);
        assertEq(sqk.balanceOf(bob), 2);
        assertEq(vault.totalRewardsReceived(), 3);
        assertEq(vault.totalRewardsPaid(), 3);
        _assertSolvent();
    }

    function testOneRemainingShareCanCollectTheFullUint128RewardBoundary() public {
        _deposit(alice, 12, 10);
        uint256 burned = vault.totalSupply() - 1;
        vm.prank(alice);
        vault.renounceShares(burned);
        assertEq(vault.totalSupply(), 1);
        uint256 amount = type(uint128).max;
        mining.credit(12, amount);
        assertEq(vault.harvest(), amount);
        assertEq(_claim(alice), amount);
        assertEq(_claim(alice), 0);
        assertEq(vault.totalWeight(), 1_023_000);
        assertEq(nft.ownerOf(12), address(vault));
        assertEq(vault.rewardFraction(alice), 0);
        vm.prank(alice);
        vm.expectRevert(HamsterMiningReserve.InvalidExit.selector);
        vault.renounceShares(1);
        vm.prank(alice);
        vault.transfer(bob, 1);
        mining.credit(12, 1);
        vault.harvest();
        assertEq(_claim(alice), 0);
        assertEq(_claim(bob), 1);
        _assertSolvent();
    }

    function testEveryMergeableLevelAdds1000WeightWithoutMintingShares() public {
        for (uint8 level = 1; level < 10; ++level) {
            uint256 survivor = uint256(level) * 2;
            uint256 donor = survivor + 1;
            _deposit(alice, survivor, level);
            _deposit(bob, donor, level);
            uint256 supply = vault.totalSupply();
            uint256 weight = vault.totalWeight();
            uint256 count = vault.reserveCount();
            vm.prank(owner);
            vault.merge(survivor, donor);
            assertEq(vault.totalWeight(), weight + 1000);
            assertEq(vault.totalSupply(), supply);
            assertEq(vault.reserveCount(), count - 1);
            assertEq(vault.reserveLevel(survivor), level + 1);
            assertEq(vault.reserveLevel(donor), 0);
            IGraphAMining.Position memory position = mining.position(0, survivor);
            assertEq(position.pendingWeight - position.activeWeight, 1000);
        }
    }

    function testTokenIdBoundariesRemainSortedAfterHeadAndTailRemoval() public {
        _deposit(alice, type(uint256).max, 1);
        _deposit(bob, 1 << 255, 1);
        _deposit(carol, 1, 1);
        _deposit(alice, 2, 1);
        uint256[] memory ids = vault.liveTokenIds();
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
        assertEq(ids[2], 1 << 255);
        assertEq(ids[3], type(uint256).max);
        vm.prank(owner);
        vault.merge(2, 1); // remove head
        vm.prank(owner);
        vault.merge(1 << 255, type(uint256).max); // remove tail
        mining.activatePending();
        core.setHeight(100_001);
        vm.prank(owner);
        vault.merge(2, 1 << 255);
        ids = vault.liveTokenIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], 2);
        assertEq(vault.totalWeight(), 7000);
        assertEq(vault.totalSupply(), 4000 ether);
        mining.credit(2, 4 ether);
        assertEq(vault.harvest(), 4 ether);
        assertEq(_claim(alice), 2 ether);
        assertEq(_claim(bob), 1 ether);
        assertEq(_claim(carol), 1 ether);
        _assertSolvent();
    }
}
