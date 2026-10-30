// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReserveTestBase} from "./ReserveTestBase.sol";
import {HamsterMiningReserve} from "../src/HamsterMiningReserve.sol";
import {IGraphAMining} from "../src/interfaces/IGraphA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AccessAndReentrancyTest is ReserveTestBase {
    function testFactoryNeverOwnsSharesOrRolesAndConstructorDoesNotCallGraph() public {
        vm.etch(vault.MINING(), "");
        vm.etch(vault.CORE(), "");
        vm.etch(vault.NFT(), "");
        HamsterMiningReserve fresh = new HamsterMiningReserve(owner);
        assertEq(fresh.owner(), owner);
        assertEq(fresh.strategist(), owner);
        assertEq(fresh.totalSupply(), 0);
        assertFalse(fresh.activated());
        assertEq(address(fresh.rewardToken()), address(0));
        vm.expectRevert(HamsterMiningReserve.NotActivated.selector);
        fresh.deposit(12, 0);
        vm.expectRevert(HamsterMiningReserve.NotActivated.selector);
        fresh.harvest();
        vm.expectRevert(HamsterMiningReserve.NotActivated.selector);
        fresh.claimRewards();
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.UnsupportedImplementation.selector);
        fresh.activate();
        assertFalse(fresh.activated());
    }

    function testZeroOwnerRejected() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new HamsterMiningReserve(address(0));
    }

    function testActivationRestrictedOnceAndSepoliaOnly() public {
        HamsterMiningReserve fresh = new HamsterMiningReserve(owner);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.activate();
        vm.chainId(1);
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.WrongChain.selector);
        fresh.activate();
        vm.chainId(11155111);
        vm.prank(owner);
        fresh.activate();
        assertEq(address(fresh.rewardToken()), address(sqk));
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.AlreadyActivated.selector);
        fresh.activate();
    }

    function testActivationRejectsWrongImplementationCoreVersionAndWiring() public {
        HamsterMiningReserve fresh = new HamsterMiningReserve(owner);
        mining.setIdentity(3, vault.MINING_IMPLEMENTATION());
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.UnsupportedImplementation.selector);
        fresh.activate();
        mining.setIdentity(6, vault.CORE());
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.UnsupportedImplementation.selector);
        fresh.activate();
        mining.setIdentity(6, vault.MINING_IMPLEMENTATION());
        core.setVersion(6);
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.UnsupportedImplementation.selector);
        fresh.activate();
        core.setVersion(3);
        IGraphAMining.Configuration memory cfg = mining.configuration();
        cfg.genesisCollection = alice;
        mining.setConfiguration(cfg);
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.InvalidGraph.selector);
        fresh.activate();
        assertFalse(fresh.activated());
    }

    function testOnlyOwnerCanChangeStrategistAndOwnershipNeedsAcceptance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setStrategist(alice);
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.InvalidStrategist.selector);
        vault.setStrategist(address(0));
        vm.prank(owner);
        vault.setStrategist(carol);
        vm.prank(owner);
        vault.transferOwnership(bob);
        assertEq(vault.owner(), owner);
        assertEq(vault.pendingOwner(), bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.acceptOwnership();
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.owner(), bob);
        assertEq(vault.strategist(), carol);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.setStrategist(alice);
        _twoDepositors();
        vm.prank(carol);
        vault.merge(12, 13);
    }

    function testProxyImplementationMustMatchEvenIfLogicSpoofsItsIdentity() public {
        HamsterMiningReserve fresh = new HamsterMiningReserve(owner);
        mining.setIdentity(6, address(mining));
        vm.mockCall(
            address(mining),
            abi.encodeCall(mining.implementationCodeAddress, ()),
            abi.encode(vault.MINING_IMPLEMENTATION())
        );
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.UnsupportedImplementation.selector);
        fresh.activate();
        assertFalse(fresh.activated());
    }

    function testActivationRejectsIncorrectLevelTableAndTokenWithoutCode() public {
        HamsterMiningReserve fresh = new HamsterMiningReserve(owner);
        vm.mockCall(address(mining), abi.encodeCall(mining.weightForLevel, (0, 2)), abi.encode(uint64(3001)));
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.InvalidGraph.selector);
        fresh.activate();
        vm.clearMockedCalls();
        IGraphAMining.Configuration memory cfg = mining.configuration();
        cfg.token = alice;
        mining.setConfiguration(cfg);
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.InvalidGraph.selector);
        fresh.activate();
    }

    function testTokenCannotReenterClaimsOrShareMovementDuringHarvest() public {
        _twoDepositors();
        mining.credit(12, 25 ether);
        sqk.setCallback(address(vault), abi.encodeCall(vault.claimRewards, ()));
        vault.harvest();
        assertTrue(sqk.callbackAttempted());
        assertFalse(sqk.callbackSucceeded());
        mining.credit(12, 25 ether);
        vm.prank(alice);
        vault.approve(address(sqk), 1000 ether);
        sqk.setCallback(address(vault), abi.encodeCall(vault.transferFrom, (alice, bob, 1000 ether)));
        vault.harvest();
        assertTrue(sqk.callbackAttempted());
        assertFalse(sqk.callbackSucceeded());
        assertEq(vault.balanceOf(alice), 1000 ether);
        _assertSolvent();
    }

    function testTokenCannotReenterDuringRewardPayout() public {
        _deposit(alice, 12, 1);
        mining.credit(12, 25 ether);
        vault.harvest();
        sqk.setCallback(address(vault), abi.encodeCall(vault.harvest, ()));
        assertEq(_claim(alice), 25 ether);
        assertTrue(sqk.callbackAttempted());
        assertFalse(sqk.callbackSucceeded());
        assertEq(_claim(alice), 0);
        _assertSolvent();
    }

    function testNFTCannotReenterDuringDeposit() public {
        _mintNFT(alice, 12, 1);
        nft.setCallback(address(vault), abi.encodeCall(vault.deposit, (12, 0)));
        vm.prank(alice);
        vault.deposit(12, 0);
        assertTrue(nft.callbackAttempted());
        assertFalse(nft.callbackSucceeded());
        assertEq(vault.totalSupply(), 1000 ether);
        assertEq(vault.reserveCount(), 1);
    }

    function testRuntimeFitsLaunchLimitAndContainsNoEscapeOpcodes() public view {
        bytes memory code = address(vault).code;
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                reachable = false;
            }
        }
    }
}
