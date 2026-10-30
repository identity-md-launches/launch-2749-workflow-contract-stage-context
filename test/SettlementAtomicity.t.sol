// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReserveTestBase} from "./ReserveTestBase.sol";
import {HamsterMiningReserve} from "src/HamsterMiningReserve.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev A faulty NFT calls the correct receiver hook without actually transferring custody.
contract CallbackWithoutCustodyNFT {
    address private immutable holder;

    constructor(address holder_) {
        holder = holder_;
    }

    function ownerOf(uint256) external view returns (address) {
        return holder;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        IERC721Receiver(to).onERC721Received(msg.sender, from, id, "");
    }
}

contract SettlementAtomicityTest is ReserveTestBase {
    function setUp() public override {
        super.setUp();
        _twoDepositors();
        _mintNFT(carol, 14, 1);
        // A failed action must undo an actual checkpoint and actual reward transfers,
        // not just leave an already-empty reserve unchanged.
        mining.credit(12, 9 ether + 1);
        mining.deferCredit(13, 11 ether + 1);
        mining.credit(14, 7 ether);
        vm.prank(alice);
        vault.approve(carol, 7 ether);
    }

    function testClaimFailureRollsBackDepositTransferDelegatedTransferBurnAndMerge() public {
        mining.setFailClaim(true);
        _allActionsRevertWithoutChange(abi.encodeWithSignature("Error(string)", "claim failed"));
        mining.setFailClaim(false);
        _retryEveryAction();
    }

    function testFalseClaimReportRollsBackPaymentCheckpointAndEveryShareChange() public {
        mining.setMisreportClaim(true);
        _allActionsRevertWithoutChange(
            abi.encodeWithSelector(HamsterMiningReserve.InvalidRewardPayment.selector)
        );
        mining.setMisreportClaim(false);
        _retryEveryAction();
    }

    function testCheckpointBacklogIsNotPartiallyConsumedByAnyFailedShareChange() public {
        mining.setBacklog(2);
        _allActionsRevertWithoutChange(
            abi.encodeWithSelector(HamsterMiningReserve.CheckpointRequired.selector)
        );
        mining.checkpoint();
        _retryEveryAction();
    }

    function testPausedCheckpointBlocksOnlyAdmissionsWhileExitsSettleFundedStateOnly() public {
        core.setPaused(true);
        // Deposit and merge would buy into a certified-but-unfunded round: both roll back entirely.
        bytes32 beforeState = _stateHash();
        for (uint256 action; action < 5; action += 4) {
            uint256 supply = vault.totalSupply();
            vm.prank(_actor(action));
            vm.expectRevert(HamsterMiningReserve.CheckpointRequired.selector);
            _act(action, supply);
            assertEq(_stateHash(), beforeState, "failed admission changed reserve or dependency state");
        }
        // Transfer, delegated transfer and burn proceed without attempting a checkpoint.
        for (uint256 action = 1; action < 4; ++action) {
            vm.prank(_actor(action));
            _act(action, 0);
        }
        assertEq(mining.checkpoints(), 0);
        assertEq(mining.checkpointBacklog(), 1);
        assertEq(vault.totalRewardsReceived(), 9 ether + 1, "only the funded round was harvested");
        assertEq(vault.balanceOf(alice), 997 ether);
        assertEq(vault.balanceOf(bob), 1002 ether);
        assertEq(vault.totalSupply(), 1999 ether);
        assertEq(vault.allowance(alice, carol), 6 ether);
        // The funded round was settled at the pre-transfer 1000/1000 split.
        assertEq(vault.claimableRewards(alice), 4.5 ether);
        assertEq(vault.claimableRewards(bob), 4.5 ether);
        assertEq(_claim(alice), 4.5 ether);

        core.setPaused(false);
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(carol);
        vault.deposit(14, 999 ether);
        assertEq(mining.checkpoints(), 1);
        assertEq(mining.checkpointBacklog(), 0);
        // The round certified during the pause is funded to whoever held shares when it was funded.
        assertApproxEqAbs(vault.claimableRewards(alice), uint256(11 ether + 1) * 997 / 1999, 1);
        assertApproxEqAbs(vault.claimableRewards(bob), 4.5 ether + uint256(11 ether + 1) * 1002 / 1999, 1);
        assertEq(vault.claimableRewards(carol), 7 ether, "new depositor only receives its NFT's own credit");
        assertEq(vault.balanceOf(carol), uint256(1000) * supplyBefore / 2000);
        uint256 supply = vault.totalSupply();
        vm.prank(owner);
        vault.merge(12, 13, supply);
        assertEq(vault.totalWeight(), 4000);
        assertEq(vault.totalRewardsReceived(), 27 ether + 2);
        _assertSolvent();
    }

    function testPausedCoreWithoutCertifiedRoundDoesNotBlockAdmissions() public {
        mining.checkpoint();
        core.setPaused(true);
        uint256 supply = vault.totalSupply();
        vm.prank(carol);
        vault.deposit(14, 1000 ether);
        vm.prank(owner);
        vault.merge(12, 13, supply + 1000 ether);
        assertEq(mining.checkpoints(), 1);
        assertEq(vault.totalWeight(), 4000);
        assertEq(vault.claimableRewards(carol), 7 ether);
        _assertSolvent();
    }

    function testPausedExitStillFailsAtomicallyWhenFundedHarvestFails() public {
        core.setPaused(true);
        mining.setFailClaim(true);
        bytes32 beforeState = _stateHash();
        for (uint256 action = 1; action < 4; ++action) {
            vm.prank(_actor(action));
            vm.expectRevert("claim failed");
            _act(action, 0);
            assertEq(_stateHash(), beforeState);
        }
        mining.setFailClaim(false);
        mining.setMisreportClaim(true);
        for (uint256 action = 1; action < 4; ++action) {
            vm.prank(_actor(action));
            vm.expectRevert(HamsterMiningReserve.InvalidRewardPayment.selector);
            _act(action, 0);
            assertEq(_stateHash(), beforeState);
        }
    }

    function testInsufficientAllowanceUndoesTheCheckpointAndHarvestThatPrecedeValidation() public {
        bytes32 beforeState = _stateHash();
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 7 ether, 8 ether)
        );
        vault.transferFrom(alice, bob, 8 ether);
        assertEq(_stateHash(), beforeState);
        vm.prank(carol);
        vault.transferFrom(alice, bob, 7 ether);
        assertEq(vault.allowance(alice, carol), 0);
        assertEq(vault.claimableRewards(alice), 10 ether + 1);
        assertEq(vault.claimableRewards(bob), 10 ether + 1);
    }

    function testInsufficientBalanceUndoesCheckpointHarvestAndAccrual() public {
        bytes32 beforeState = _stateHash();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000 ether, 1000 ether + 1
            )
        );
        vault.transfer(bob, 1000 ether + 1);
        assertEq(_stateHash(), beforeState);
        vm.prank(alice);
        vault.transfer(bob, 1000 ether);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(_claim(alice), 10 ether + 1);
    }

    function testNFTTransferFailureRestoresAlreadyHarvestedRewardsAndCheckpoint() public {
        bytes memory transferCall =
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", carol, address(vault), 14);
        vm.mockCallRevert(
            address(nft), transferCall, abi.encodeWithSignature("Error(string)", "NFT transfer failed")
        );
        bytes32 beforeState = _stateHash();
        vm.prank(carol);
        vm.expectRevert("NFT transfer failed");
        vault.deposit(14, 1);
        assertEq(_stateHash(), beforeState);
        vm.clearMockedCalls();
        vm.prank(carol);
        vault.deposit(14, 1000 ether);
        assertEq(vault.claimableRewards(carol), 7 ether);
        assertEq(vault.claimableRewards(alice), 10 ether + 1);
    }

    function testNoOpNFTTransferCannotMintSharesWithoutTheReceiverHandshake() public {
        vm.mockCall(
            address(nft),
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", carol, address(vault), 14),
            ""
        );
        bytes32 beforeState = _stateHash();
        vm.prank(carol);
        vm.expectRevert(HamsterMiningReserve.UnexpectedNFT.selector);
        vault.deposit(14, 1);
        assertEq(_stateHash(), beforeState);
        vm.clearMockedCalls();
        vm.prank(carol);
        vault.deposit(14, 1);
        assertEq(nft.ownerOf(14), address(vault));
    }

    function testCorrectReceiverCallbackAloneDoesNotProveCustody() public {
        // Use a fresh reserve so the faulty dependency is tested solely on admission.
        HamsterMiningReserve fresh = new HamsterMiningReserve(owner);
        vm.prank(owner);
        fresh.activate();
        vm.etch(address(nft), address(new CallbackWithoutCustodyNFT(carol)).code);
        vm.prank(carol);
        vm.expectRevert(HamsterMiningReserve.UnexpectedNFT.selector);
        fresh.deposit(14, 0);
        assertEq(fresh.totalSupply(), 0);
        assertEq(fresh.totalWeight(), 0);
        assertEq(fresh.reserveCount(), 0);
        assertEq(fresh.totalRewardsReceived(), 0);
    }

    function testReceiverHandshakeCannotBeConsumedTwiceDuringOneDeposit() public {
        nft.setCallback(
            address(vault), abi.encodeCall(vault.onERC721Received, (address(vault), carol, 14, ""))
        );
        bytes32 beforeState = _stateHash();
        vm.prank(carol);
        vm.expectRevert(HamsterMiningReserve.UnexpectedNFT.selector);
        vault.deposit(14, 1);
        assertEq(_stateHash(), beforeState);
        assertFalse(nft.callbackAttempted(), "reverted NFT callback state leaked");
        nft.setCallback(address(0), "");
        vm.prank(carol);
        vault.deposit(14, 1);
        assertEq(vault.balanceOf(carol), 1000 ether);
    }

    function testWrongOperatorCallbackCannotConsumeTheExpectedReceipt() public {
        _rejectForgedCallback(alice, carol, 14);
    }

    function testWrongDepositorCallbackCannotConsumeTheExpectedReceipt() public {
        _rejectForgedCallback(address(vault), alice, 14);
    }

    function testWrongIdCallbackCannotConsumeTheExpectedReceipt() public {
        _rejectForgedCallback(address(vault), carol, 12);
    }

    function _rejectForgedCallback(address operator, address from, uint256 id) private {
        nft.setCallback(address(vault), abi.encodeCall(vault.onERC721Received, (operator, from, id, "")));
        vm.prank(carol);
        vault.deposit(14, 1000 ether);
        assertTrue(nft.callbackAttempted());
        assertFalse(nft.callbackSucceeded());
        assertEq(vault.balanceOf(carol), 1000 ether);
        assertEq(nft.ownerOf(14), address(vault));
        assertEq(vault.reserveCount(), 3);
        assertEq(vault.claimableRewards(carol), 7 ether);
    }

    function _allActionsRevertWithoutChange(bytes memory error) private {
        bytes32 beforeState = _stateHash();
        for (uint256 action; action < 5; ++action) {
            uint256 supply = vault.totalSupply();
            vm.prank(_actor(action));
            vm.expectRevert(error);
            _act(action, supply);
            assertEq(_stateHash(), beforeState, "failed action changed reserve or dependency state");
        }
    }

    function _retryEveryAction() private {
        for (uint256 action; action < 5; ++action) {
            uint256 supply = vault.totalSupply();
            vm.prank(_actor(action));
            _act(action, supply);
        }
        assertEq(mining.checkpointBacklog(), 0);
        assertEq(vault.reserveCount(), 2);
        assertEq(vault.totalWeight(), 4000);
        assertEq(vault.totalSupply(), 2999 ether);
        assertEq(vault.totalRewardsReceived(), 27 ether + 2);
        _assertSolvent();
    }

    function _actor(uint256 action) private view returns (address) {
        if (action == 0 || action == 2) return carol;
        if (action == 4) return owner;
        return alice;
    }

    function _act(uint256 action, uint256 supply) private {
        if (action == 0) vault.deposit(14, 1000 ether);
        else if (action == 1) vault.transfer(bob, 1 ether);
        else if (action == 2) vault.transferFrom(alice, bob, 1 ether);
        else if (action == 3) vault.renounceShares(1 ether);
        else vault.merge(12, 13, supply);
    }

    function _stateHash() private view returns (bytes32) {
        bytes32 reserve = keccak256(
            abi.encode(
                vault.totalSupply(),
                vault.totalWeight(),
                vault.rewardPerShare(),
                vault.totalRewardsReceived(),
                vault.totalRewardsPaid(),
                vault.liveTokenIds(),
                vault.reserveLevel(12),
                vault.reserveLevel(13),
                vault.reserveLevel(14),
                vault.allowance(alice, carol)
            )
        );
        bytes32 accounts = keccak256(abi.encode(_accountHash(alice), _accountHash(bob), _accountHash(carol)));
        bytes32 dependencies = keccak256(
            abi.encode(
                mining.position(0, 12),
                mining.position(0, 13),
                mining.position(0, 14),
                mining.checkpoints(),
                mining.checkpointBacklog(),
                mining.claimCalls(),
                sqk.balanceOf(address(vault)),
                sqk.balanceOf(address(mining)),
                sqk.totalSupply()
            )
        );
        return keccak256(
            abi.encode(
                reserve,
                accounts,
                dependencies,
                nft.ownerOf(12),
                nft.ownerOf(13),
                nft.ownerOf(14),
                nft.getApproved(14)
            )
        );
    }

    function _accountHash(address who) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                vault.balanceOf(who),
                vault.accruedRewards(who),
                vault.rewardIndex(who),
                vault.rewardFraction(who),
                vault.claimableRewards(who),
                sqk.balanceOf(who)
            )
        );
    }
}
