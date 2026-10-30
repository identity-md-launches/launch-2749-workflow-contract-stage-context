// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterMiningReserve} from "../src/HamsterMiningReserve.sol";
import {IGraphAMining} from "../src/interfaces/IGraphA.sol";
import {MockSQK, MockCore, MockNFT, MockMining} from "./mocks/GraphAMocks.sol";

abstract contract ReserveTestBase is Test {
    HamsterMiningReserve internal vault;
    MockSQK internal sqk;
    MockCore internal core;
    MockNFT internal nft;
    MockMining internal mining;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        vm.chainId(11155111);
        vault = new HamsterMiningReserve(owner);
        vm.etch(vault.CORE(), address(new MockCore()).code);
        vm.etch(vault.NFT(), address(new MockNFT()).code);
        vm.etch(vault.MINING(), address(new MockMining()).code);
        core = MockCore(vault.CORE());
        nft = MockNFT(vault.NFT());
        mining = MockMining(vault.MINING());
        sqk = new MockSQK();
        core.configure();
        mining.configure(address(sqk));
        vm.prank(owner);
        vault.activate();
    }

    function _mintNFT(address who, uint256 id, uint8 level) internal {
        nft.mint(who, id);
        mining.register(id, level);
        vm.prank(who);
        nft.approve(address(vault), id);
    }

    function _deposit(address who, uint256 id, uint8 level) internal returns (uint256 shares) {
        _mintNFT(who, id, level);
        vm.prank(who);
        shares = vault.deposit(id, 1);
    }

    function _twoDepositors() internal {
        _deposit(alice, 12, 1);
        _deposit(bob, 13, 1);
    }

    function _claim(address who) internal returns (uint256) {
        vm.prank(who);
        return vault.claimRewards();
    }

    function _assertSolvent() internal view {
        uint256 owing =
            vault.claimableRewards(alice) + vault.claimableRewards(bob) + vault.claimableRewards(carol);
        assertLe(owing, sqk.balanceOf(address(vault)));
        assertEq(vault.totalRewardsReceived(), vault.totalRewardsPaid() + sqk.balanceOf(address(vault)));
    }
}
