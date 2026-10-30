// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReserveTestBase} from "./ReserveTestBase.sol";
import {HamsterMiningReserve} from "../src/HamsterMiningReserve.sol";
import {IGraphAMining} from "../src/interfaces/IGraphA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockNFT} from "./mocks/GraphAMocks.sol";

contract HamsterMiningReserveTest is ReserveTestBase {
    function testDepositMergeClaimCycle() public {
        _twoDepositors();
        mining.credit(12, 80 ether);
        mining.credit(13, 20 ether);
        assertEq(vault.pendingMiningRewards(), 100 ether);
        vm.prank(owner);
        vault.merge(12, 13, type(uint256).max);
        assertEq(vault.totalWeight(), 3000);
        assertEq(vault.totalSupply(), 2000 ether);
        assertEq(vault.reserveCount(), 1);
        assertEq(vault.reserveLevel(12), 2);
        assertEq(vault.reserveLevel(13), 0);
        assertEq(nft.ownerOf(12), address(vault));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 13));
        nft.ownerOf(13);
        (uint256 active, uint256 pending) = vault.miningWeights();
        assertEq(active, 2000);
        assertEq(pending, 1000);
        assertEq(_claim(alice), 50 ether);
        assertEq(_claim(bob), 50 ether);
        mining.activatePending();
        mining.credit(12, 90 ether);
        vault.harvest();
        assertEq(_claim(alice), 45 ether);
        assertEq(_claim(bob), 45 ether);
        assertEq(vault.totalRewardsReceived(), 190 ether);
        _assertSolvent();
    }

    function testDepositPricingPreservesExistingMergeGainIncludingPendingBonus() public {
        _twoDepositors();
        vm.prank(owner);
        vault.merge(12, 13, type(uint256).max);
        _mintNFT(carol, 14, 1);
        uint256 expected = uint256(2000 ether) / 3;
        assertEq(vault.previewDeposit(14), expected);
        vm.prank(carol);
        uint256 minted = vault.deposit(14, expected);
        assertEq(minted, expected);
        assertEq(vault.totalWeight(), 4000);
        assertEq(vault.balanceOf(alice), 1000 ether);
    }

    function testDepositCarriedRewardsBelongToDepositorAndOldPoolRewardsStayWithOldHolder() public {
        _deposit(alice, 12, 1);
        mining.credit(12, 99 ether);
        _mintNFT(bob, 13, 1);
        mining.credit(13, 25 ether);
        vm.prank(bob);
        vault.deposit(13, 1000 ether);
        assertEq(vault.claimableRewards(alice), 99 ether);
        assertEq(vault.claimableRewards(bob), 25 ether);
        assertEq(_claim(alice), 99 ether);
        assertEq(_claim(bob), 25 ether);
        _assertSolvent();
    }

    function testSortedIdsAfterUnorderedDepositsAndDonorRemoval() public {
        _deposit(alice, 19, 1);
        _deposit(alice, 3, 1);
        _deposit(bob, 15, 1);
        uint256[] memory ids = vault.liveTokenIds();
        assertEq(ids[0], 3);
        assertEq(ids[1], 15);
        assertEq(ids[2], 19);
        vm.prank(owner);
        vault.merge(19, 3, type(uint256).max);
        ids = vault.liveTokenIds();
        assertEq(ids.length, 2);
        assertEq(ids[0], 15);
        assertEq(ids[1], 19);
        mining.credit(19, 3 ether);
        vault.harvest();
        _assertSolvent();
    }

    function testTransferSettlesPastRewardsAndOnlyFutureRewardsFollowShares() public {
        _twoDepositors();
        mining.credit(12, 20 ether);
        vm.prank(alice);
        vault.transfer(carol, 1000 ether);
        assertEq(vault.claimableRewards(alice), 10 ether);
        assertEq(vault.claimableRewards(carol), 0);
        mining.credit(13, 30 ether);
        vault.harvest();
        assertEq(_claim(alice), 10 ether);
        assertEq(_claim(bob), 25 ether);
        assertEq(_claim(carol), 15 ether);
        _assertSolvent();
    }

    function testTransferFromRespectsAllowanceAndRewardsStayWithSender() public {
        _twoDepositors();
        mining.credit(12, 12 ether);
        vm.prank(alice);
        vault.approve(carol, 500 ether);
        vm.prank(carol);
        vault.transferFrom(alice, bob, 500 ether);
        assertEq(vault.allowance(alice, carol), 0);
        assertEq(vault.claimableRewards(alice), 6 ether);
        assertEq(vault.claimableRewards(bob), 6 ether);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, 1));
        vault.transferFrom(alice, bob, 1);
        _assertSolvent();
    }

    function testCheckpointBeforeDepositPreventsTakingPreviouslyFundedEpoch() public {
        _deposit(alice, 12, 1);
        mining.deferCredit(12, 30 ether);
        _deposit(bob, 13, 1);
        assertEq(mining.checkpoints(), 1);
        assertEq(vault.claimableRewards(alice), 30 ether);
        assertEq(vault.claimableRewards(bob), 0);
    }

    function testCheckpointBeforeTransferPreventsMovingUnharvestedRewards() public {
        _deposit(alice, 12, 1);
        mining.deferCredit(12, 30 ether);
        vm.prank(alice);
        vault.transfer(bob, 1000 ether);
        assertEq(vault.claimableRewards(alice), 30 ether);
        assertEq(vault.claimableRewards(bob), 0);
    }

    function testCheckpointBacklogFailsAtomicallyAndPermissionlessProgressUnblocks() public {
        _deposit(alice, 12, 1);
        mining.setBacklog(2);
        vm.prank(alice);
        vm.expectRevert(HamsterMiningReserve.CheckpointRequired.selector);
        vault.transfer(bob, 1);
        assertEq(mining.checkpointBacklog(), 2);
        mining.checkpoint();
        vm.prank(alice);
        vault.transfer(bob, 1);
        assertEq(mining.checkpointBacklog(), 0);
    }

    function testCorePauseDoesNotBlockFundedHarvestOrAccruedClaims() public {
        _deposit(alice, 12, 1);
        core.setPaused(true);
        mining.credit(12, 31 ether);
        vault.harvest();
        assertEq(_claim(alice), 31 ether);
        mining.deferCredit(12, 10 ether);
        _mintNFT(bob, 13, 1);
        vm.prank(bob);
        vm.expectRevert(HamsterMiningReserve.CheckpointRequired.selector);
        vault.deposit(13, 0);
        core.setPaused(false);
        vm.prank(bob);
        vault.deposit(13, 0);
        assertEq(mining.checkpoints(), 1);
        assertEq(_claim(alice), 10 ether);
        assertEq(vault.claimableRewards(bob), 0);
    }

    function testCorePauseWithSettledRoundStillAllowsExitByTransferOrBurnButNotAdmission() public {
        _twoDepositors();
        mining.deferCredit(12, 10 ether);
        core.setPaused(true);
        vm.prank(alice);
        vault.transfer(carol, 1000 ether);
        vm.prank(bob);
        vault.renounceShares(500 ether);
        assertEq(mining.checkpoints(), 0);
        assertEq(vault.balanceOf(carol), 1000 ether);
        assertEq(vault.balanceOf(bob), 500 ether);
        _mintNFT(carol, 14, 1);
        vm.prank(carol);
        vm.expectRevert(HamsterMiningReserve.CheckpointRequired.selector);
        vault.deposit(14, 0);
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.CheckpointRequired.selector);
        vault.merge(12, 13, type(uint256).max);
        core.setPaused(false);
        vault.harvest();
        assertEq(vault.totalRewardsReceived(), 0);
        vm.prank(carol);
        vault.deposit(14, 0);
        assertEq(mining.checkpoints(), 1);
        // The round certified during the pause follows the shares that held it when it was funded.
        assertEq(vault.claimableRewards(alice), 0);
        assertApproxEqAbs(vault.claimableRewards(carol), uint256(10 ether) * 2 / 3, 1);
        assertApproxEqAbs(vault.claimableRewards(bob), uint256(10 ether) / 3, 1);
        _assertSolvent();
    }

    function testVoluntaryBurnGivesUpFutureRewardsAndKeepsAccruedRewards() public {
        _twoDepositors();
        mining.credit(12, 40 ether);
        vm.prank(alice);
        vault.renounceShares(1000 ether);
        assertEq(vault.totalSupply(), 1000 ether);
        assertEq(vault.totalWeight(), 2000);
        assertEq(vault.reserveCount(), 2);
        mining.credit(13, 20 ether);
        vault.harvest();
        assertEq(_claim(alice), 20 ether);
        assertEq(_claim(bob), 40 ether);
        vm.prank(bob);
        vm.expectRevert(HamsterMiningReserve.InvalidExit.selector);
        vault.renounceShares(1000 ether);
        _assertSolvent();
    }

    function testLastHolderCanTransferEntireSupplyButCannotBurnIt() public {
        _deposit(alice, 12, 1);
        vm.prank(alice);
        vault.transfer(bob, 1000 ether);
        assertEq(vault.balanceOf(bob), vault.totalSupply());
        uint256 supply = vault.totalSupply();
        vm.prank(bob);
        vm.expectRevert(HamsterMiningReserve.InvalidExit.selector);
        vault.renounceShares(supply);
    }

    function testDuplicateZeroAndNonOwnerDepositsFail() public {
        _deposit(alice, 12, 1);
        vm.prank(alice);
        vm.expectRevert(HamsterMiningReserve.InvalidDeposit.selector);
        vault.deposit(12, 0);
        vm.expectRevert(HamsterMiningReserve.InvalidDeposit.selector);
        vault.deposit(0, 0);
        _mintNFT(bob, 13, 1);
        vm.prank(alice);
        vm.expectRevert(HamsterMiningReserve.InvalidDeposit.selector);
        vault.deposit(13, 0);
    }

    function testDepositNeedsApprovalAndAcceptableShareMinimum() public {
        nft.mint(alice, 12);
        mining.register(12, 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(vault), 12)
        );
        vault.deposit(12, 0);
        vm.prank(alice);
        nft.approve(address(vault), 12);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                HamsterMiningReserve.MinimumSharesNotMet.selector, 1000 ether, 1000 ether + 1
            )
        );
        vault.deposit(12, 1000 ether + 1);
        assertEq(nft.ownerOf(12), alice);
        assertEq(vault.totalSupply(), 0);
    }

    function testPendingAndMalformedPositionsCannotDeposit() public {
        _mintNFT(alice, 12, 1);
        IGraphAMining.Position memory p = mining.position(0, 12);
        p.pendingRound = 7;
        p.pendingWeight = 1000;
        mining.setPosition(12, p);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.PendingActivation.selector, 12));
        vault.deposit(12, 0);
        p.pendingRound = 0;
        p.pendingWeight = 0;
        p.activeWeight = 999;
        mining.setPosition(12, p);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.InvalidPosition.selector, 12));
        vault.deposit(12, 0);
        p.level = 0;
        mining.setPosition(12, p);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.InvalidPosition.selector, 12));
        vault.deposit(12, 0);
    }

    function testUnsafeNFTDonationMintsNoSharesAndSafeUnsolicitedNFTIsRejected() public {
        _mintNFT(alice, 12, 1);
        vm.prank(alice);
        vm.expectRevert(HamsterMiningReserve.UnexpectedNFT.selector);
        nft.safeTransferFrom(alice, address(vault), 12);
        vm.prank(alice);
        nft.transferFrom(alice, address(vault), 12);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalWeight(), 0);
        assertEq(vault.reserveCount(), 0);
        vm.expectRevert(HamsterMiningReserve.UnexpectedNFT.selector);
        vault.onERC721Received(address(vault), alice, 12, "");
        MockNFT other = new MockNFT();
        other.mint(alice, 12);
        vm.prank(alice);
        vm.expectRevert(HamsterMiningReserve.UnexpectedNFT.selector);
        other.safeTransferFrom(alice, address(vault), 12);
    }

    function testCapacityBoundAndMergeReopensSlot() public {
        for (uint256 i = 1; i <= 32; ++i) {
            _deposit(alice, i, 1);
        }
        _mintNFT(alice, 33, 1);
        vm.prank(alice);
        vm.expectRevert(HamsterMiningReserve.ReserveFull.selector);
        vault.deposit(33, 1);
        vm.prank(owner);
        vault.merge(32, 31, type(uint256).max);
        vm.prank(alice);
        vault.deposit(33, 1);
        assertEq(vault.reserveCount(), 32);
        vault.harvest();
    }

    function testInvalidAndUnauthorizedMerges() public {
        _twoDepositors();
        vm.prank(alice);
        vm.expectRevert(HamsterMiningReserve.OnlyStrategist.selector);
        vault.merge(12, 13, type(uint256).max);
        vm.startPrank(owner);
        vm.expectRevert(HamsterMiningReserve.InvalidMerge.selector);
        vault.merge(12, 12, type(uint256).max);
        vm.expectRevert(HamsterMiningReserve.InvalidMerge.selector);
        vault.merge(12, 99, type(uint256).max);
        vm.stopPrank();
        _deposit(carol, 14, 2);
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.InvalidMerge.selector);
        vault.merge(12, 14, type(uint256).max);
        _deposit(carol, 15, 10);
        _deposit(carol, 16, 10);
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.InvalidMerge.selector);
        vault.merge(15, 16, type(uint256).max);
    }

    function testMergeCooldownAndPendingActivation() public {
        _twoDepositors();
        IGraphAMining.Position memory p = mining.position(0, 12);
        p.nextMergeBlock = 100_001;
        mining.setPosition(12, p);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.MergeCooldown.selector, 100_001, 100_000));
        vault.merge(12, 13, type(uint256).max);
        core.setHeight(100_001);
        vm.prank(owner);
        vault.merge(12, 13, type(uint256).max);
        _deposit(carol, 14, 2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.PendingActivation.selector, 12));
        vault.merge(12, 14, type(uint256).max);
        mining.activatePending();
        vm.prank(owner);
        vault.merge(12, 14, type(uint256).max);
        assertEq(vault.totalWeight(), 7000);
    }

    function testMergeFailureOrCorruptionRollsBackDonorBurnAndAccounting() public {
        _twoDepositors();
        nft.setFailBurn(true);
        vm.prank(owner);
        vm.expectRevert("burn failed");
        vault.merge(12, 13, type(uint256).max);
        assertEq(vault.totalWeight(), 2000);
        assertEq(nft.ownerOf(13), address(vault));
        nft.setFailBurn(false);
        mining.setCorruptMerge(true);
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.InvalidMerge.selector);
        vault.merge(12, 13, type(uint256).max);
        assertEq(vault.reserveCount(), 2);
        assertEq(nft.ownerOf(13), address(vault));
    }

    function testClaimFailureBlocksDepositWithoutTakingNFTOrMintingShares() public {
        _deposit(alice, 12, 1);
        _mintNFT(bob, 13, 1);
        mining.setFailClaim(true);
        vm.prank(bob);
        vm.expectRevert("claim failed");
        vault.deposit(13, 0);
        assertEq(nft.ownerOf(13), bob);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.totalWeight(), 1000);
    }

    function testIncomingClaimFailureRollsBackFirstDepositTransfer() public {
        _mintNFT(alice, 12, 1);
        mining.setFailClaim(true);
        vm.prank(alice);
        vm.expectRevert("claim failed");
        vault.deposit(12, 0);
        assertEq(nft.ownerOf(12), alice);
        assertEq(vault.totalSupply(), 0);
    }

    function testFalseTokenTransferRestoresClaimCredit() public {
        _deposit(alice, 12, 1);
        mining.credit(12, 5 ether);
        vault.harvest();
        sqk.setFailTransfer(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(sqk)));
        vault.claimRewards();
        assertEq(vault.claimableRewards(alice), 5 ether);
        assertEq(vault.totalRewardsPaid(), 0);
        sqk.setFailTransfer(false);
        assertEq(_claim(alice), 5 ether);
    }

    function testReportedClaimAmountMustMatchBalanceDelta() public {
        _deposit(alice, 12, 1);
        mining.credit(12, 5 ether);
        mining.setMisreportClaim(true);
        vm.expectRevert(HamsterMiningReserve.InvalidRewardPayment.selector);
        vault.harvest();
        assertEq(vault.totalRewardsReceived(), 0);
        assertEq(vault.pendingMiningRewards(), 5 ether);
        mining.setMisreportClaim(false);
        vault.harvest();
        assertEq(_claim(alice), 5 ether);
    }

    function testRewardDonationCannotManipulateSharePriceOrCreateUnbackedClaims() public {
        _deposit(alice, 12, 1);
        sqk.mint(address(vault), 1_000_000 ether);
        _deposit(bob, 13, 1);
        assertEq(vault.balanceOf(bob), 1000 ether);
        assertEq(vault.totalRewardsReceived(), 0);
        assertEq(vault.claimableRewards(alice), 0);
        assertEq(vault.claimableRewards(bob), 0);
    }

    function testIdentityUpgradeStopsMergesButNotHarvestingClaimsOrShareExit() public {
        _twoDepositors();
        mining.credit(12, 12 ether);
        vault.harvest();
        mining.setIdentity(7, address(0xBEEF));
        mining.credit(12, 100 ether);
        assertEq(vault.pendingMiningRewards(), 100 ether);
        assertEq(vault.harvest(), 100 ether);
        vm.prank(alice);
        vault.transfer(carol, 500 ether);
        vm.prank(alice);
        vault.renounceShares(100 ether);
        vm.prank(bob);
        vault.approve(carol, 1);
        vm.prank(carol);
        vault.transferFrom(bob, carol, 1);
        _mintNFT(carol, 14, 1);
        vm.prank(carol);
        vault.deposit(14, 0);
        assertEq(vault.reserveCount(), 3);
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.UnsupportedImplementation.selector);
        vault.merge(12, 13, type(uint256).max);
        assertEq(_claim(alice), 56 ether);
        assertEq(_claim(bob), 56 ether);
        assertEq(sqk.balanceOf(address(mining)), 0);
        mining.setIdentity(6, vault.MINING_IMPLEMENTATION());
        core.setVersion(4);
        vault.harvest();
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.UnsupportedImplementation.selector);
        vault.merge(12, 13, type(uint256).max);
        core.setVersion(3);
        vm.prank(owner);
        vault.merge(12, 13, type(uint256).max);
        _assertSolvent();
    }

    function testMergeSupplyGuardRejectsFrontRunningDepositAndAcceptsUnchangedSupply() public {
        _twoDepositors();
        uint256 prepared = vault.totalSupply();
        _deposit(carol, 14, 1);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(HamsterMiningReserve.UnexpectedSupply.selector, 3000 ether, prepared)
        );
        vault.merge(12, 13, prepared);
        assertEq(vault.totalWeight(), 3000);
        assertEq(vault.reserveLevel(13), 1);
        uint256 supply12 = vault.totalSupply();
        vm.prank(owner);
        vault.merge(12, 13, supply12);
        assertEq(vault.totalWeight(), 4000);
        // Burns before the merge only reduce supply and never trip the guard.
        vm.prank(alice);
        vault.renounceShares(10 ether);
        _deposit(alice, 15, 2);
        _deposit(bob, 16, 2);
        mining.activatePending();
        uint256 supply15 = vault.totalSupply();
        vm.prank(owner);
        vault.merge(15, 16, supply15);
    }

    function testNoAdminCanWithdrawNFTsOrMintShares() public {
        _deposit(alice, 12, 1);
        vm.startPrank(owner);
        (bool mintOK,) = address(vault).call(abi.encodeWithSignature("mint(address,uint256)", owner, 1));
        (bool withdrawOK,) = address(vault).call(abi.encodeWithSignature("withdraw(uint256)", 12));
        (bool sweepOK,) =
            address(vault).call(abi.encodeWithSignature("sweep(address,uint256)", address(nft), 12));
        vm.stopPrank();
        assertFalse(mintOK);
        assertFalse(withdrawOK);
        assertFalse(sweepOK);
        assertEq(nft.ownerOf(12), address(vault));
    }

    function testRepeatedClaimsAndZeroTransfersCannotManufactureRewards() public {
        _twoDepositors();
        mining.credit(12, 5 ether);
        vault.harvest();
        assertEq(_claim(alice), 2.5 ether);
        assertEq(_claim(alice), 0);
        vm.startPrank(alice);
        vault.transfer(alice, 1000 ether);
        vault.transfer(bob, 0);
        vm.stopPrank();
        assertEq(_claim(alice), 0);
        assertEq(_claim(bob), 2.5 ether);
        _assertSolvent();
    }

    function testShareRecipientAndBurnValidation() public {
        _twoDepositors();
        vm.startPrank(alice);
        vm.expectRevert(HamsterMiningReserve.InvalidShareRecipient.selector);
        vault.transfer(address(vault), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vault.transfer(address(0), 1);
        vm.expectRevert(HamsterMiningReserve.InvalidExit.selector);
        vault.renounceShares(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000 ether, 1001 ether
            )
        );
        vault.renounceShares(1001 ether);
        vm.stopPrank();
    }

    function testVoluntaryBurnCannotCollapseSupplyBelowPrecisionFloor() public {
        _deposit(alice, 12, 2);
        uint256 floor = 3000 * vault.MIN_SHARES_PER_WEIGHT();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.SupplyBelowFloor.selector, 1, floor));
        vault.renounceShares(3000 ether - 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(HamsterMiningReserve.SupplyBelowFloor.selector, floor - 1, floor)
        );
        vault.renounceShares(3000 ether - floor + 1);
        vm.prank(alice);
        vault.renounceShares(3000 ether - floor);
        assertEq(vault.totalSupply(), floor);
        assertEq(vault.balanceOf(alice), floor);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(HamsterMiningReserve.SupplyBelowFloor.selector, floor - 1, floor)
        );
        vault.renounceShares(1);
    }

    function testDepositsAfterMaximalBurnStayExactlyProportionalForEveryLevel() public {
        _deposit(alice, 12, 3);
        uint256 burnable = 7000 ether - 7000 * vault.MIN_SHARES_PER_WEIGHT();
        vm.prank(alice);
        vault.renounceShares(burnable);
        assertEq(vault.totalSupply(), 7000 * 1e9);
        _mintNFT(bob, 13, 4);
        assertEq(vault.previewDeposit(13), 15000 * 1e9);
        vm.prank(bob);
        assertEq(vault.deposit(13, 15000 * 1e9), 15000 * 1e9);
        _mintNFT(carol, 14, 1);
        assertEq(vault.previewDeposit(14), 1000 * 1e9);
        vm.prank(carol);
        assertEq(vault.deposit(14, 1000 * 1e9), 1000 * 1e9);
        assertEq(vault.totalWeight(), 23000);
        assertEq(vault.totalSupply(), 23000 * 1e9);
        mining.credit(12, 7 ether);
        mining.credit(13, 15 ether);
        mining.credit(14, 1 ether);
        vault.harvest();
        assertEq(_claim(alice), 7 ether);
        assertEq(_claim(bob), 15 ether);
        assertEq(_claim(carol), 1 ether);
        _assertSolvent();
    }

    function testMergesAfterMaximalBurnKeepEveryLevelDepositableAndBlockFurtherBurns() public {
        _twoDepositors();
        uint256 floor = 2000 * vault.MIN_SHARES_PER_WEIGHT();
        vm.prank(alice);
        vault.renounceShares(1000 ether - 1);
        vm.prank(bob);
        vault.renounceShares(1000 ether + 1 - floor);
        assertEq(vault.totalSupply(), floor);
        uint256 supply12 = vault.totalSupply();
        vm.prank(owner);
        vault.merge(12, 13, supply12);
        assertEq(vault.totalWeight(), 3000);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(HamsterMiningReserve.SupplyBelowFloor.selector, floor - 1, 3000 * 1e9)
        );
        vault.renounceShares(1);
        _mintNFT(carol, 14, 1);
        uint256 quote = vault.previewDeposit(14);
        assertEq(quote, uint256(1000) * floor / 3000);
        vm.prank(carol);
        assertEq(vault.deposit(14, quote), quote);
        mining.activatePending();
        mining.credit(12, 3 ether);
        mining.credit(14, 1 ether);
        vault.harvest();
        assertApproxEqAbs(_claim(carol), 1 ether, 1e9);
        assertApproxEqAbs(_claim(alice) + _claim(bob), 3 ether, 1e9);
    }

    function testFuzzProportionalSharesAndRewards(uint8 a, uint8 b, uint96 reward) public {
        uint8 levelA = uint8(bound(a, 1, 10));
        uint8 levelB = uint8(bound(b, 1, 10));
        uint256 amount = bound(reward, 1, 1e26);
        uint256 wa = vault.weightForLevel(levelA);
        uint256 wb = vault.weightForLevel(levelB);
        _deposit(alice, 12, levelA);
        _deposit(bob, 13, levelB);
        assertEq(vault.balanceOf(alice), wa * 1e18);
        assertEq(vault.balanceOf(bob), wb * 1e18);
        mining.credit(12, amount);
        vault.harvest();
        uint256 paidA = _claim(alice);
        uint256 paidB = _claim(bob);
        assertApproxEqAbs(paidA, amount * wa / (wa + wb), 1);
        assertApproxEqAbs(paidB, amount * wb / (wa + wb), 1);
        assertLe(paidA + paidB, amount);
        assertLe(amount - paidA - paidB, 2);
        _assertSolvent();
    }

    function testFuzzTransfersClaimsAndFractionalDust(uint96 reward, uint96 transferAmount) public {
        _twoDepositors();
        uint256 amount = bound(reward, 1, 1e25);
        uint256 moved = bound(transferAmount, 1, 1000 ether);
        mining.credit(12, amount);
        vm.prank(alice);
        vault.transfer(bob, moved);
        _claim(alice);
        _claim(bob);
        mining.credit(13, amount);
        vault.harvest();
        vm.prank(bob);
        vault.transfer(carol, moved);
        _claim(alice);
        _claim(bob);
        _claim(carol);
        assertLe(vault.totalRewardsPaid(), 2 * amount);
        assertLe(2 * amount - vault.totalRewardsPaid(), 3);
        _assertSolvent();
    }
}
