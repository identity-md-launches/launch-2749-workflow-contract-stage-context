// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterMiningReserve} from "src/HamsterMiningReserve.sol";
import {IGraphAMining, IGraphACore, IGraphANFT} from "src/interfaces/IGraphA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Actual Graph A integration at the assignment's only permitted fork block.
/// The older historical acceptance figures also remain covered by GraphAReplayTest.
/// No dependency code, storage, balances, time or chain height is replaced on this fork.
contract GraphAPinnedForkTest is Test {
    HamsterMiningReserve internal vault;
    IGraphAMining internal mining;
    IGraphACore internal core;
    IGraphANFT internal nft;
    IERC20 internal sqk;
    address internal owner = makeAddr("pinned fork vault owner");
    address internal alice = makeAddr("pinned fork depositor A");
    address internal bob = makeAddr("pinned fork depositor B");
    address internal recipient = makeAddr("pinned fork share recipient");

    function setUp() public {
        string memory url = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, 12029130);
        assertEq(block.chainid, 11155111);
        assertEq(block.number, 12029130);
        vault = new HamsterMiningReserve(owner);
        mining = IGraphAMining(vault.MINING());
        core = IGraphACore(vault.CORE());
        nft = IGraphANFT(vault.NFT());
        vm.prank(owner);
        vault.activate();
        sqk = vault.rewardToken();
    }

    function testFork_ActivationBindsTheLiveGraphAndLevelTable() public view {
        assertTrue(vault.activated());
        assertGt(address(mining).code.length, 0);
        assertGt(address(core).code.length, 0);
        assertGt(address(nft).code.length, 0);
        (address implementation,) = mining.deploymentIdentity();
        assertEq(implementation, vault.MINING_IMPLEMENTATION());
        assertEq(mining.implementationCodeAddress(), implementation);
        assertEq(mining.implementationCodeVersion(), 6);
        assertEq(mining.core(), address(core));
        IGraphAMining.Configuration memory cfg = mining.configuration();
        assertEq(cfg.core, address(core));
        assertEq(cfg.genesisCollection, address(nft));
        assertEq(address(sqk), cfg.token);
        assertGt(address(sqk).code.length, 0);
        assertEq(nft.mining(), address(mining));
        assertEq(nft.sqkCore(), address(core));
        assertEq(mining.MAX_CLAIMS(), 32);
        assertEq(mining.MAX_LEVELS(), 10);
        for (uint8 level = 1; level <= 10; ++level) {
            assertEq(mining.weightForLevel(0, level), vault.weightForLevel(level));
        }
        assertEq(vault.owner(), owner);
        assertEq(vault.strategist(), owner);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.reserveCount(), 0);
    }

    function testFork_DepositMergeClaimAndFullShareExitAcrossDistinctHolders() public {
        uint256 credit12 = _claimable(12);
        uint256 credit13 = _claimable(13);
        assertGt(credit12, 0);
        assertGt(credit13, 0);
        uint256 nftSupply = nft.totalSupply();
        // Reverse admission order exercises sorting with real Mining's strict claim batches.
        _deposit(13, bob);
        _deposit(12, alice);
        assertEq(vault.claimableRewards(alice), credit12);
        assertEq(vault.claimableRewards(bob), credit13);
        assertEq(vault.balanceOf(alice), 1000 ether);
        assertEq(vault.balanceOf(bob), 1000 ether);
        uint256[] memory ids = vault.liveTokenIds();
        assertEq(ids.length, 2);
        assertEq(ids[0], 12);
        assertEq(ids[1], 13);

        {
            uint256 supply = vault.totalSupply();
            vm.prank(owner);
            vault.merge(12, 13, supply);
        }
        assertEq(nft.totalSupply(), nftSupply - 1);
        assertEq(nft.ownerOf(12), address(vault));
        vm.expectRevert();
        nft.ownerOf(13);
        assertEq(vault.reserveCount(), 1);
        assertEq(vault.reserveLevel(13), 0);
        assertEq(mining.position(0, 13).level, 0);
        IGraphAMining.Position memory survivor = mining.position(0, 12);
        assertEq(survivor.level, 2);
        assertEq(survivor.activeWeight, 2000);
        assertEq(survivor.pendingWeight, 3000);
        assertGt(survivor.pendingRound, 0);
        (uint256 active, uint256 pendingIncrease) = vault.miningWeights();
        assertEq(active, 2000);
        assertEq(pendingIncrease, 1000);
        assertEq(vault.totalWeight(), 3000);
        assertEq(vault.totalSupply(), 2000 ether);

        vm.prank(alice);
        vault.transfer(recipient, 1000 ether);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(recipient), 1000 ether);
        assertEq(vault.claimableRewards(recipient), 0);
        _assertPayout(alice, credit12);
        _assertPayout(bob, credit13);
        _assertPayout(recipient, 0);
        assertEq(vault.totalRewardsReceived(), credit12 + credit13);
        assertEq(vault.totalRewardsPaid(), credit12 + credit13);
        assertEq(sqk.balanceOf(address(vault)), 0);
        assertEq(nft.ownerOf(12), address(vault));
        assertEq(vault.harvest(), 0);
    }

    function testFork_SlippageFailureLeavesCustodyCreditAndSharesUntouchedThenRetrySucceeds() public {
        _deposit(12, alice);
        _moveNFT(13, bob);
        uint256 incomingCredit = _claimable(13);
        uint256 existingCredit = vault.claimableRewards(alice);
        uint256 received = vault.totalRewardsReceived();
        uint256 balance = sqk.balanceOf(address(vault));
        vm.startPrank(bob);
        nft.approve(address(vault), 13);
        vm.expectRevert(
            abi.encodeWithSelector(
                HamsterMiningReserve.MinimumSharesNotMet.selector, 1000 ether, 1000 ether + 1
            )
        );
        vault.deposit(13, 1000 ether + 1);
        vm.stopPrank();
        assertEq(nft.ownerOf(13), bob);
        assertEq(_claimable(13), incomingCredit);
        assertEq(vault.totalSupply(), 1000 ether);
        assertEq(vault.totalWeight(), 1000);
        assertEq(vault.reserveCount(), 1);
        assertEq(vault.claimableRewards(alice), existingCredit);
        assertEq(vault.totalRewardsReceived(), received);
        assertEq(sqk.balanceOf(address(vault)), balance);
        vm.prank(bob);
        assertEq(vault.deposit(13, 1000 ether), 1000 ether);
        assertEq(vault.claimableRewards(bob), incomingCredit);
    }

    function testFork_DepositRequiresOwnershipApprovalAndCannotBeReplayed() public {
        _moveNFT(12, alice);
        vm.prank(bob);
        vm.expectRevert(HamsterMiningReserve.InvalidDeposit.selector);
        vault.deposit(12, 0);
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(12, 0);
        assertEq(nft.ownerOf(12), alice);
        assertEq(vault.totalSupply(), 0);
        vm.startPrank(alice);
        nft.approve(address(vault), 12);
        vault.deposit(12, 1000 ether);
        vm.expectRevert(HamsterMiningReserve.InvalidDeposit.selector);
        vault.deposit(12, 0);
        vm.stopPrank();
        assertEq(vault.totalSupply(), 1000 ether);
        assertEq(vault.reserveCount(), 1);
    }

    function testFork_UnsolicitedSafeTransferIsRejectedByTheRealNFT() public {
        address holder = nft.ownerOf(12);
        vm.prank(holder);
        vm.expectRevert(HamsterMiningReserve.UnexpectedNFT.selector);
        nft.safeTransferFrom(holder, address(vault), 12);
        assertEq(nft.ownerOf(12), holder);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalWeight(), 0);
        assertEq(vault.reserveCount(), 0);
    }

    function testFork_RealMiningRejectsUnauthorizedUnsortedDuplicateAndBurnedIds() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 13;
        ids[1] = 12;
        vm.expectRevert();
        mining.claimable(0, ids);
        ids[0] = 12;
        vm.expectRevert();
        mining.claimable(0, ids);
        ids[1] = 13;
        vm.expectRevert();
        mining.claim(0, ids);
        _deposit(12, alice);
        _deposit(13, bob);
        {
            uint256 supply = vault.totalSupply();
            vm.prank(alice);
            vm.expectRevert(HamsterMiningReserve.OnlyStrategist.selector);
            vault.merge(12, 13, supply);
        }
        {
            uint256 supply = vault.totalSupply();
            vm.prank(owner);
            vault.merge(12, 13, supply);
        }
        vm.expectRevert();
        mining.claimable(0, ids);
        assertEq(vault.pendingMiningRewards(), 0);
        {
            uint256 supply = vault.totalSupply();
            vm.prank(owner);
            vm.expectRevert(HamsterMiningReserve.InvalidMerge.selector);
            vault.merge(12, 13, supply);
        }
        assertEq(vault.totalWeight(), 3000);
    }

    function testFork_StaleSupplyGuardLeavesRealPositionsUntouchedThenFloorBoundsBurns() public {
        _deposit(12, alice);
        _deposit(13, bob);
        uint256 supply = vault.totalSupply();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(HamsterMiningReserve.UnexpectedSupply.selector, supply, supply - 1)
        );
        vault.merge(12, 13, supply - 1);
        assertEq(mining.position(0, 12).level, 1);
        assertEq(mining.position(0, 13).level, 1);
        assertEq(nft.ownerOf(13), address(vault));
        assertEq(vault.reserveCount(), 2);
        vm.prank(owner);
        vault.merge(12, 13, supply);
        assertEq(mining.position(0, 12).level, 2);

        vm.prank(bob);
        vault.transfer(alice, 1000 ether);
        uint256 floor = 3000 * vault.MIN_SHARES_PER_WEIGHT();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(HamsterMiningReserve.SupplyBelowFloor.selector, floor - 1, floor)
        );
        vault.renounceShares(supply - floor + 1);
        vm.prank(alice);
        vault.renounceShares(supply - floor);
        assertEq(vault.totalSupply(), floor);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(HamsterMiningReserve.SupplyBelowFloor.selector, floor - 1, floor)
        );
        vault.renounceShares(1);
        assertEq(nft.ownerOf(12), address(vault));
        assertEq(vault.totalWeight(), 3000);
        assertEq(vault.totalRewardsPaid() + sqk.balanceOf(address(vault)), vault.totalRewardsReceived());
    }

    function testFork_PendingRealMergeCannotBeDepositedAsActivatedWeight() public {
        _moveNFT(12, alice);
        _moveNFT(13, alice);
        vm.prank(alice);
        mining.merge(0, 12, 13);
        IGraphAMining.Position memory position = mining.position(0, 12);
        assertEq(position.level, 2);
        assertGt(position.pendingRound, 0);
        vm.startPrank(alice);
        nft.approve(address(vault), 12);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.PendingActivation.selector, 12));
        vault.deposit(12, 0);
        vm.stopPrank();
        assertEq(nft.ownerOf(12), alice);
        assertEq(vault.reserveCount(), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function _moveNFT(uint256 id, address to) private {
        address holder = nft.ownerOf(id);
        vm.prank(holder);
        nft.transferFrom(holder, to, id);
    }

    function _deposit(uint256 id, address depositor) private {
        _moveNFT(id, depositor);
        vm.startPrank(depositor);
        nft.approve(address(vault), id);
        uint256 shares = vault.deposit(id, 1000 ether);
        vm.stopPrank();
        assertEq(shares, 1000 ether);
        assertEq(nft.ownerOf(id), address(vault));
    }

    function _claimable(uint256 id) private view returns (uint256) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        return mining.claimable(0, ids);
    }

    function _assertPayout(address who, uint256 expected) private {
        uint256 beforeBalance = sqk.balanceOf(who);
        vm.prank(who);
        assertEq(vault.claimRewards(), expected);
        assertEq(sqk.balanceOf(who) - beforeBalance, expected);
        vm.prank(who);
        assertEq(vault.claimRewards(), 0);
    }
}
