// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ReserveTestBase} from "./ReserveTestBase.sol";
import {HamsterMiningReserve} from "../src/HamsterMiningReserve.sol";
import {MockSQK, MockCore, MockNFT, MockMining} from "./mocks/GraphAMocks.sol";

contract ReserveHandler is Test {
    HamsterMiningReserve public immutable vault;
    MockNFT public immutable nft;
    MockMining public immutable mining;
    MockCore public immutable core;
    address[3] public actors;
    uint256 public nextId = 100;
    uint256 public funded;

    constructor(HamsterMiningReserve vault_, address[3] memory actors_) {
        vault = vault_;
        nft = MockNFT(vault_.NFT());
        mining = MockMining(vault_.MINING());
        core = MockCore(vault_.CORE());
        actors = actors_;
    }

    function deposit(uint8 actorSeed, uint8 levelSeed, uint96 carriedSeed) external {
        if (vault.reserveCount() == vault.MAX_RESERVE_NFTS()) return;
        address actor = actors[actorSeed % 3];
        uint8 level = uint8(bound(levelSeed, 1, 5));
        // A voluntary burn can leave too little supply to quote even one share unit.
        if (vault.weightForLevel(level) * vault.totalSupply() < vault.totalWeight()) return;
        uint256 amount = bound(carriedSeed, 0, 1e24);
        uint256 id = nextId++;
        nft.mint(actor, id);
        mining.register(id, level);
        if (amount != 0) {
            mining.credit(id, amount);
            funded += amount;
        }
        vm.startPrank(actor);
        nft.approve(address(vault), id);
        vault.deposit(id, 0);
        vm.stopPrank();
    }

    function reward(uint8 idSeed, uint96 amountSeed) external {
        uint256[] memory ids = vault.liveTokenIds();
        if (ids.length == 0) return;
        uint256 amount = bound(amountSeed, 1, 1e24);
        mining.credit(ids[idSeed % ids.length], amount);
        funded += amount;
    }

    function harvest() external {
        vault.harvest();
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint96 amountSeed) external {
        address from = actors[fromSeed % 3];
        address to = actors[toSeed % 3];
        uint256 balance = vault.balanceOf(from);
        uint256 amount = bound(amountSeed, 0, balance);
        vm.prank(from);
        vault.transfer(to, amount);
    }

    function claim(uint8 actorSeed) external {
        vm.prank(actors[actorSeed % 3]);
        vault.claimRewards();
    }

    function burn(uint8 actorSeed, uint96 amountSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 limit = vault.balanceOf(actor);
        if (limit >= vault.totalSupply()) limit = vault.totalSupply() - 1;
        if (limit == 0) return;
        uint256 amount = bound(amountSeed, 1, limit);
        vm.prank(actor);
        vault.renounceShares(amount);
    }

    function merge(uint8 seed) external {
        uint256[] memory ids = vault.liveTokenIds();
        if (ids.length < 2) return;
        // Advance the mock's external activation/cooldown before a valid merge.
        mining.activatePending();
        core.setHeight(1_000_000);
        uint256 survivor = ids[seed % ids.length];
        uint8 level = vault.reserveLevel(survivor);
        if (level >= 10) return;
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == survivor || vault.reserveLevel(ids[i]) != level) continue;
            vault.merge(survivor, ids[i]);
            break;
        }
    }
}

contract ReserveInvariantTest is StdInvariant, ReserveTestBase {
    ReserveHandler internal handler;

    function setUp() public override {
        super.setUp();
        _twoDepositors();
        handler = new ReserveHandler(vault, [alice, bob, carol]);
        vm.prank(owner);
        vault.setStrategist(address(handler));
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.reward.selector;
        selectors[2] = handler.harvest.selector;
        selectors[3] = handler.transfer.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.burn.selector;
        selectors[6] = handler.merge.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantRewardsAreConservedAndEveryClaimIsBacked() public view {
        uint256 vaultBalance = sqk.balanceOf(address(vault));
        uint256 paid = vault.totalRewardsPaid();
        assertEq(vault.totalRewardsReceived(), paid + vaultBalance);
        assertEq(handler.funded(), paid + vaultBalance + sqk.balanceOf(address(mining)));
        assertEq(paid, sqk.balanceOf(alice) + sqk.balanceOf(bob) + sqk.balanceOf(carol));
        assertLe(
            vault.claimableRewards(alice) + vault.claimableRewards(bob) + vault.claimableRewards(carol),
            vaultBalance
        );
    }

    function invariantPermanentCustodyLevelsWeightAndSortedLiveIdsAgree() public view {
        uint256[] memory ids = vault.liveTokenIds();
        assertGt(ids.length, 0);
        assertLe(ids.length, 32);
        uint256 weight;
        uint256 previous;
        for (uint256 i; i < ids.length; ++i) {
            assertGt(ids[i], previous);
            assertEq(nft.ownerOf(ids[i]), address(vault));
            uint8 level = vault.reserveLevel(ids[i]);
            assertEq(level, mining.position(0, ids[i]).level);
            weight += vault.weightForLevel(level);
            previous = ids[i];
        }
        assertEq(vault.totalWeight(), weight);
    }

    function invariantSharesExistOnlyInDepositorOrTransfereeBalances() public view {
        assertEq(vault.totalSupply(), vault.balanceOf(alice) + vault.balanceOf(bob) + vault.balanceOf(carol));
        assertGt(vault.totalSupply(), 0);
        assertEq(vault.balanceOf(owner), 0);
        assertEq(vault.balanceOf(address(vault)), 0);
    }
}
