// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterMiningReserve} from "../../src/HamsterMiningReserve.sol";
import {IGraphAMining, IGraphACore, IGraphANFT} from "../../src/interfaces/IGraphA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Identical assertions run against the live archive fork and the offline bytecode/storage replay.
abstract contract GraphAAssertions is Test {
    HamsterMiningReserve internal vault;
    IGraphAMining internal mining;
    IGraphACore internal core;
    IGraphANFT internal nft;
    address internal governor = makeAddr("reserve owner");

    function setUp() public virtual {
        require(block.chainid == 11155111 && block.number == 12019224, "use Sepolia block 12019224");
        vault = new HamsterMiningReserve(governor);
        mining = IGraphAMining(vault.MINING());
        core = IGraphACore(vault.CORE());
        nft = IGraphANFT(vault.NFT());
        vm.prank(governor);
        vault.activate();
    }

    function testPinnedGraphAReferenceAndCorrectedContractAttribution() public view {
        assertEq(mining.implementationCodeVersion(), 6);
        assertEq(mining.implementationCodeAddress(), vault.MINING_IMPLEMENTATION());
        assertEq(core.implementationCodeVersion(), 3);
        assertEq(mining.core(), address(core));
        assertEq(nft.mining(), address(mining));
        assertEq(nft.sqkCore(), address(core));
        uint256[] memory ids = new uint256[](2);
        ids[0] = 12;
        ids[1] = 13;
        assertEq(mining.claimable(0, ids), 12461377786582968289288);
        assertEq(nft.publicMinted(), 8888);
        assertEq(nft.totalSupply(), 6910);
        (bool success,) = address(core).staticcall(abi.encodeCall(mining.claimable, (0, ids)));
        assertFalse(success, "Core does not implement the Mining claimable selector");
        assertEq(IGraphAMining.position.selector, bytes4(0x7400ef36));
        assertEq(IGraphAMining.claimable.selector, bytes4(0x5f369bc8));
        assertEq(IGraphAMining.merge.selector, bytes4(0xfaf2e326));
        assertEq(IGraphAMining.claim.selector, bytes4(0x5fd53f4c));
    }

    function testRealDepositMergeClaimAndShareTransfer() public {
        address depositor12 = nft.ownerOf(12);
        address depositor13 = nft.ownerOf(13);
        uint256 supplyBefore = nft.totalSupply();
        _depositReal(depositor12, 12);
        _depositReal(depositor13, 13);
        assertEq(vault.totalWeight(), 2000);
        assertEq(vault.totalSupply(), 2000 ether);
        assertEq(nft.ownerOf(12), address(vault));
        assertEq(nft.ownerOf(13), address(vault));
        uint256 supply = vault.totalSupply();
        vm.prank(governor);
        vault.merge(12, 13, supply);
        assertEq(vault.totalWeight(), 3000);
        assertEq(vault.reserveCount(), 1);
        assertEq(nft.totalSupply(), supplyBefore - 1);
        IGraphAMining.Position memory survivor = mining.position(0, 12);
        assertEq(survivor.level, 2);
        assertEq(survivor.activeWeight, 2000);
        assertEq(survivor.pendingWeight, 3000);
        assertGt(survivor.pendingRound, 0);
        assertEq(mining.position(0, 13).level, 0);
        IERC20 sqk = vault.rewardToken();
        uint256 expected = vault.claimableRewards(depositor12);
        uint256 beforeBalance = sqk.balanceOf(depositor12);
        vm.prank(depositor12);
        assertEq(vault.claimRewards(), expected);
        assertEq(sqk.balanceOf(depositor12) - beforeBalance, expected);
        if (depositor12 != depositor13) {
            expected = vault.claimableRewards(depositor13);
            beforeBalance = sqk.balanceOf(depositor13);
            vm.prank(depositor13);
            assertEq(vault.claimRewards(), expected);
            assertEq(sqk.balanceOf(depositor13) - beforeBalance, expected);
        }
        assertGe(vault.totalRewardsPaid(), 12461377786582968289287);
        assertLe(vault.totalRewardsPaid(), 12461377786582968289288);
        address receiver = makeAddr("share recipient");
        uint256 shares = vault.balanceOf(depositor12);
        vm.prank(depositor12);
        vault.transfer(receiver, shares);
        assertEq(vault.balanceOf(receiver), shares);
        assertEq(nft.ownerOf(12), address(vault));
    }

    function testRealGraphRejectsUnauthorizedUnsortedDuplicateAndDeadIds() public {
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
        address who12 = nft.ownerOf(12);
        address who13 = nft.ownerOf(13);
        _depositReal(who12, 12);
        _depositReal(who13, 13);
        uint256 supply = vault.totalSupply();
        vm.expectRevert(HamsterMiningReserve.OnlyStrategist.selector);
        vault.merge(12, 13, supply);
        vm.prank(governor);
        vault.merge(12, 13, supply);
        vm.expectRevert();
        mining.claimable(0, ids);
        assertEq(vault.pendingMiningRewards(), 0);
    }

    function _depositReal(address depositor, uint256 id) internal {
        vm.startPrank(depositor);
        nft.approve(address(vault), id);
        vault.deposit(id, 1000 ether);
        vm.stopPrank();
    }
}
