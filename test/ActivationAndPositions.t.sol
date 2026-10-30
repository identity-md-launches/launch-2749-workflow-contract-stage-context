// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReserveTestBase} from "./ReserveTestBase.sol";
import {HamsterMiningReserve} from "src/HamsterMiningReserve.sol";
import {IGraphAMining} from "src/interfaces/IGraphA.sol";

contract ActivationAndPositionsTest is ReserveTestBase {
    function testEveryInvalidConfigurationIsRejectedWithoutPartiallyActivating() public {
        HamsterMiningReserve fresh = new HamsterMiningReserve(owner);
        IGraphAMining.Configuration memory valid = mining.configuration();
        for (uint256 fault; fault < 7; ++fault) {
            // Read anew each time: memory assignment between structs would alias the baseline.
            IGraphAMining.Configuration memory cfg = mining.configuration();
            if (fault == 0) cfg.core = alice;
            else if (fault == 1) cfg.genesisCollection = alice;
            else if (fault == 2) cfg.token = address(0);
            else if (fault == 3) cfg.token = address(fresh);
            else if (fault == 4) cfg.token = alice;
            else if (fault == 5) cfg.genesisMaximumLevel = 9;
            else cfg.genesisMaximumLevel = 11;
            mining.setConfiguration(cfg);
            _expectInvalidGraph(fresh);
            mining.setConfiguration(valid);
        }
        vm.prank(owner);
        fresh.activate();
        assertTrue(fresh.activated());
        assertEq(address(fresh.rewardToken()), address(sqk));
    }

    function testEveryWeightTableEntryIsValidatedAtActivation() public {
        HamsterMiningReserve fresh = new HamsterMiningReserve(owner);
        for (uint8 level = 1; level <= 10; ++level) {
            uint64 incorrect = uint64(vault.weightForLevel(level) + 1);
            vm.mockCall(
                address(mining), abi.encodeCall(mining.weightForLevel, (0, level)), abi.encode(incorrect)
            );
            _expectInvalidGraph(fresh);
            vm.clearMockedCalls();
        }
        vm.prank(owner);
        fresh.activate();
        assertTrue(fresh.activated());
    }

    function testActivationRejectsWrongNFTPointersAndExternalBatchLimits() public {
        HamsterMiningReserve fresh = new HamsterMiningReserve(owner);
        vm.mockCall(address(nft), abi.encodeWithSignature("mining()"), abi.encode(alice));
        _expectInvalidGraph(fresh);
        vm.clearMockedCalls();
        vm.mockCall(address(nft), abi.encodeWithSignature("sqkCore()"), abi.encode(alice));
        _expectInvalidGraph(fresh);
        vm.clearMockedCalls();
        vm.mockCall(address(mining), abi.encodeCall(mining.MAX_LEVELS, ()), abi.encode(uint256(11)));
        _expectInvalidGraph(fresh);
        vm.clearMockedCalls();
        vm.mockCall(address(mining), abi.encodeCall(mining.MAX_CLAIMS, ()), abi.encode(uint256(31)));
        _expectInvalidGraph(fresh);
        vm.clearMockedCalls();
        vm.prank(owner);
        fresh.activate();
        assertTrue(fresh.activated());
    }

    function testEachMissingDependencyPreventsActivationButConstructorRemainsUsable() public {
        address[3] memory dependencies = [address(core), address(mining), address(nft)];
        for (uint256 i; i < dependencies.length; ++i) {
            bytes memory original = dependencies[i].code;
            vm.etch(dependencies[i], "");
            HamsterMiningReserve fresh = new HamsterMiningReserve(owner);
            assertEq(fresh.owner(), owner);
            vm.prank(owner);
            vm.expectRevert(HamsterMiningReserve.UnsupportedImplementation.selector);
            fresh.activate();
            assertFalse(fresh.activated());
            assertEq(address(fresh.rewardToken()), address(0));
            vm.etch(dependencies[i], original);
            vm.prank(owner);
            fresh.activate();
            assertTrue(fresh.activated());
        }
    }

    function testPendingRoundAndPendingWeightIndependentlyBlockDepositsAndPreviews() public {
        _mintNFT(alice, 12, 1);
        IGraphAMining.Position memory position = mining.position(0, 12);
        position.pendingRound = 1;
        mining.setPosition(12, position);
        _expectInvalidPosition(HamsterMiningReserve.PendingActivation.selector);
        position.pendingRound = 0;
        position.pendingWeight = 1;
        mining.setPosition(12, position);
        _expectInvalidPosition(HamsterMiningReserve.PendingActivation.selector);
        position.pendingWeight = 0;
        mining.setPosition(12, position);
        assertEq(vault.previewDeposit(12), 1000 ether);
        vm.prank(alice);
        vault.deposit(12, 1000 ether);
        assertEq(vault.balanceOf(alice), 1000 ether);
    }

    function testOutOfRangeLevelsAndWeightBoundariesCannotEnterCustody() public {
        _mintNFT(alice, 12, 1);
        IGraphAMining.Position memory position = mining.position(0, 12);
        uint8[3] memory invalidLevels = [uint8(0), uint8(11), type(uint8).max];
        for (uint256 i; i < invalidLevels.length; ++i) {
            position.level = invalidLevels[i];
            mining.setPosition(12, position);
            _expectInvalidPosition(HamsterMiningReserve.InvalidPosition.selector);
            vm.expectRevert(HamsterMiningReserve.InvalidMerge.selector);
            vault.weightForLevel(invalidLevels[i]);
        }
        position.level = 1;
        uint64[4] memory invalidWeights = [uint64(0), uint64(999), uint64(1001), type(uint64).max];
        for (uint256 i; i < invalidWeights.length; ++i) {
            position.activeWeight = invalidWeights[i];
            mining.setPosition(12, position);
            _expectInvalidPosition(HamsterMiningReserve.InvalidPosition.selector);
        }
        position.activeWeight = 1000;
        mining.setPosition(12, position);
        vm.prank(alice);
        vault.deposit(12, 1000 ether);
        assertEq(vault.totalWeight(), 1000);
    }

    function testStrategistRevocationTakesEffectBeforeAnyMergeOrHarvest() public {
        _twoDepositors();
        mining.credit(12, 20 ether);
        vm.prank(owner);
        vault.setStrategist(carol);
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.OnlyStrategist.selector);
        vault.merge(12, 13);
        assertEq(vault.totalRewardsReceived(), 0);
        assertEq(vault.pendingMiningRewards(), 20 ether);
        assertEq(vault.reserveCount(), 2);
        vm.prank(carol);
        vault.merge(12, 13);
        assertEq(vault.totalWeight(), 3000);
        assertEq(vault.claimableRewards(alice), 10 ether);
        assertEq(vault.claimableRewards(bob), 10 ether);
        assertEq(vault.balanceOf(carol), 0);
    }

    function _expectInvalidGraph(HamsterMiningReserve fresh) private {
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.InvalidGraph.selector);
        fresh.activate();
        assertFalse(fresh.activated());
        assertEq(address(fresh.rewardToken()), address(0));
        assertEq(fresh.totalSupply(), 0);
        assertEq(fresh.owner(), owner);
    }

    function _expectInvalidPosition(bytes4 selector) private {
        vm.expectRevert(abi.encodeWithSelector(selector, 12));
        vault.previewDeposit(12);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(selector, 12));
        vault.deposit(12, 0);
        assertEq(nft.ownerOf(12), alice);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalWeight(), 0);
        assertEq(vault.reserveCount(), 0);
    }
}
