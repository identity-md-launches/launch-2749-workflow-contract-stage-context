// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterMiningReserve} from "src/HamsterMiningReserve.sol";
import {MockSQK, MockCore, MockNFT, MockMining} from "./mocks/GraphAMocks.sol";

/// @dev Drives deposits, merges (with a correct or stale supply guard), burns at and past the
/// precision floor, transfers, funded and certified-but-unfunded rewards and Core pauses. Every
/// expected rejection is predicted independently and compared to the reserve's actual outcome.
contract FloorPauseGuardHandler is Test {
    HamsterMiningReserve internal immutable vault;
    MockMining internal immutable mining;
    MockCore internal immutable core;
    MockNFT internal immutable nft;
    MockSQK internal immutable sqk;
    address internal immutable owner;
    address[3] internal actors;
    uint256 internal nextId = 1;

    uint256 public lastSupply;
    uint256 public lastWeight;
    bool public ratioIncreased;
    bool public burnBrokeFloor;
    bool public checkpointedWhilePaused;
    bool public admittedDuringPausedBacklog;
    bool public guardBypassed;
    uint256 public unexpectedOutcomes;
    uint256 public pausedExits;
    uint256 public pausedAdmissionRejections;
    uint256 public floorRejections;
    uint256 public guardRejections;

    constructor(HamsterMiningReserve vault_, address owner_) {
        vault = vault_;
        owner = owner_;
        mining = MockMining(vault_.MINING());
        core = MockCore(vault_.CORE());
        nft = MockNFT(vault_.NFT());
        sqk = MockSQK(address(vault_.rewardToken()));
        actors = [makeAddr("floor actor 0"), makeAddr("floor actor 1"), makeAddr("floor actor 2")];
        core.setHeight(1_000_000);
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function deposit(uint256 actorSeed, uint8 levelSeed, uint64 carried) external {
        address actor = actors[actorSeed % 3];
        uint8 level = uint8(bound(levelSeed, 1, 10));
        uint256 id = nextId++;
        nft.mint(actor, id);
        mining.register(id, level);
        if (carried != 0) mining.credit(id, carried);
        vm.prank(actor);
        nft.approve(address(vault), id);
        uint256 weight = vault.weightForLevel(level);
        uint256 supply = vault.totalSupply();
        uint256 total = vault.totalWeight();
        bytes4 expected;
        if (vault.reserveCount() == vault.MAX_RESERVE_NFTS()) {
            expected = HamsterMiningReserve.ReserveFull.selector;
        } else if (_pausedBacklog()) {
            expected = HamsterMiningReserve.CheckpointRequired.selector;
        }
        uint256 checkpoints = mining.checkpoints();
        vm.prank(actor);
        try vault.deposit(id, 1) returns (uint256 shares) {
            if (expected != bytes4(0)) {
                ++unexpectedOutcomes;
                if (expected == HamsterMiningReserve.CheckpointRequired.selector) {
                    admittedDuringPausedBacklog = true;
                }
            }
            if (supply != 0) {
                // Independent bounds: floor(weight * S / W) without re-implementing mulDiv.
                assertLe(shares * total, weight * supply, "deposit over-minted");
                assertGt((shares + 1) * total, weight * supply, "deposit under-minted");
            } else {
                assertEq(shares, weight * 1e18);
            }
            assertEq(nft.ownerOf(id), address(vault));
        } catch (bytes memory reason) {
            _expectReason(reason, expected);
            if (expected == HamsterMiningReserve.CheckpointRequired.selector) ++pausedAdmissionRejections;
            assertEq(nft.ownerOf(id), actor, "rejected deposit kept the NFT");
        }
        _afterAction(checkpoints);
    }

    function merge(uint256 seed, bool staleGuard) external {
        uint256[] memory ids = vault.liveTokenIds();
        if (ids.length < 2) return;
        mining.activatePending();
        uint256 survivor = ids[seed % ids.length];
        uint8 level = vault.reserveLevel(survivor);
        if (level >= 10) return;
        uint256 donor;
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] != survivor && vault.reserveLevel(ids[i]) == level) {
                donor = ids[i];
                break;
            }
        }
        if (donor == 0) return;
        uint256 supply = vault.totalSupply();
        uint256 maxSupply = staleGuard ? supply - 1 : supply;
        bytes4 expected;
        if (staleGuard) expected = HamsterMiningReserve.UnexpectedSupply.selector;
        else if (_pausedBacklog()) expected = HamsterMiningReserve.CheckpointRequired.selector;
        uint256 weight = vault.totalWeight();
        uint256 checkpoints = mining.checkpoints();
        vm.prank(owner);
        try vault.merge(survivor, donor, maxSupply) {
            if (expected != bytes4(0)) ++unexpectedOutcomes;
            if (staleGuard) guardBypassed = true;
            if (expected == HamsterMiningReserve.CheckpointRequired.selector) {
                admittedDuringPausedBacklog = true;
            }
            assertEq(vault.totalWeight(), weight + 1000);
            assertEq(vault.totalSupply(), supply, "merge minted shares");
        } catch (bytes memory reason) {
            _expectReason(reason, expected);
            if (staleGuard) ++guardRejections;
            if (expected == HamsterMiningReserve.CheckpointRequired.selector) ++pausedAdmissionRejections;
            assertEq(vault.totalWeight(), weight);
            assertEq(vault.reserveLevel(donor), level);
        }
        _afterAction(checkpoints);
    }

    function burn(uint256 actorSeed, uint256 amountSeed, bool toFloor) external {
        address actor = actors[actorSeed % 3];
        uint256 checkpoints = mining.checkpoints();
        if (toFloor) {
            // A dominant holder gathers the supply and aims at the floor or one unit past it.
            for (uint256 i; i < 3; ++i) {
                uint256 held = vault.balanceOf(actors[i]);
                if (actors[i] == actor || held == 0) continue;
                vm.prank(actors[i]);
                vault.transfer(actor, held);
            }
        }
        uint256 balance = vault.balanceOf(actor);
        uint256 supply = vault.totalSupply();
        uint256 floor = vault.totalWeight() * vault.MIN_SHARES_PER_WEIGHT();
        uint256 amount = bound(amountSeed, 0, balance);
        if (toFloor && supply > floor) amount = supply - floor + (amountSeed % 2);
        if (amount > balance) amount = balance;
        bytes4 expected;
        if (amount == 0 || amount >= supply) expected = HamsterMiningReserve.InvalidExit.selector;
        else if (supply - amount < floor) expected = HamsterMiningReserve.SupplyBelowFloor.selector;
        bool paused = _pausedBacklog();
        vm.prank(actor);
        try vault.renounceShares(amount) {
            if (expected != bytes4(0)) ++unexpectedOutcomes;
            if (vault.totalSupply() < floor) burnBrokeFloor = true;
            if (paused) ++pausedExits;
        } catch (bytes memory reason) {
            _expectReason(reason, expected);
            if (expected == HamsterMiningReserve.SupplyBelowFloor.selector) ++floorRejections;
        }
        _afterAction(checkpoints);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 3];
        address to = actors[toSeed % 3];
        uint256 amount = bound(amountSeed, 0, vault.balanceOf(from));
        uint256 checkpoints = mining.checkpoints();
        bool paused = _pausedBacklog();
        // Exits between holders never wait for a checkpoint, paused or not.
        vm.prank(from);
        assertTrue(vault.transfer(to, amount));
        if (paused && amount != 0 && from != to) ++pausedExits;
        _afterAction(checkpoints);
    }

    function fund(uint256 seed, uint64 amount, bool deferred) external {
        uint256[] memory ids = vault.liveTokenIds();
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        if (deferred) mining.deferCredit(id, amount);
        else mining.credit(id, amount);
    }

    function setPaused(bool paused, uint64 certifiedSeed) external {
        // Often pause with a certified round outstanding, the state the exit/admission split is for.
        uint256[] memory ids = vault.liveTokenIds();
        if (paused && certifiedSeed % 2 == 0 && ids.length != 0) {
            mining.deferCredit(ids[certifiedSeed % ids.length], certifiedSeed);
        }
        core.setPaused(paused);
    }

    function checkpoint() external {
        if (core.state().paused || mining.checkpointBacklog() == 0) return;
        mining.checkpoint();
    }

    function harvest() external {
        uint256 checkpoints = mining.checkpoints();
        vault.harvest();
        _afterAction(checkpoints);
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 expected = vault.claimableRewards(actor);
        vm.prank(actor);
        assertEq(vault.claimRewards(), expected);
    }

    function _pausedBacklog() private view returns (bool) {
        return core.state().paused && mining.checkpointBacklog() != 0;
    }

    function _expectReason(bytes memory reason, bytes4 expected) private {
        bytes4 actual;
        if (reason.length >= 4) actual = bytes4(reason);
        if (expected == bytes4(0) || actual != expected) ++unexpectedOutcomes;
    }

    function _afterAction(uint256 checkpointsBefore) private {
        if (core.state().paused && mining.checkpoints() != checkpointsBefore) checkpointedWhilePaused = true;
        uint256 supply = vault.totalSupply();
        uint256 weight = vault.totalWeight();
        // S/W is non-increasing: deposits round down, merges add weight, burns remove supply.
        if (lastSupply != 0 && supply * lastWeight > lastSupply * weight) ratioIncreased = true;
        lastSupply = supply;
        lastWeight = weight;
    }
}

/// forge-config: default.invariant.runs = 200
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract FloorPauseGuardInvariantTest is Test {
    HamsterMiningReserve internal vault;
    FloorPauseGuardHandler internal handler;
    MockSQK internal sqk;

    function setUp() public {
        vm.chainId(11155111);
        address owner = makeAddr("floor owner");
        vault = new HamsterMiningReserve(owner);
        vm.etch(vault.CORE(), address(new MockCore()).code);
        vm.etch(vault.NFT(), address(new MockNFT()).code);
        vm.etch(vault.MINING(), address(new MockMining()).code);
        sqk = new MockSQK();
        MockCore(vault.CORE()).configure();
        MockMining(vault.MINING()).configure(address(sqk));
        vm.prank(owner);
        vault.activate();
        handler = new FloorPauseGuardHandler(vault, owner);
        targetContract(address(handler));
    }

    /// @dev Proves the rejection branches the invariants rely on are reachable through this handler.
    function testHandlerReachesEveryGuardedBranch() public {
        handler.deposit(0, 1, 5);
        handler.deposit(1, 1, 0);
        handler.deposit(2, 2, 0);
        handler.merge(0, true);
        assertEq(handler.guardRejections(), 1);
        handler.burn(0, 1, true);
        assertEq(handler.floorRejections(), 1);
        handler.burn(0, 0, true);
        assertEq(vault.totalSupply(), vault.totalWeight() * vault.MIN_SHARES_PER_WEIGHT());
        handler.setPaused(true, 2);
        handler.deposit(1, 3, 0);
        handler.merge(0, false);
        assertEq(handler.pausedAdmissionRejections(), 2);
        handler.transfer(0, 1, 1e9);
        assertEq(handler.pausedExits(), 1);
        handler.setPaused(false, 1);
        handler.merge(0, false);
        handler.claim(0);
        handler.claim(1);
        assertEq(handler.unexpectedOutcomes(), 0);
        assertFalse(handler.ratioIncreased());
        assertFalse(handler.checkpointedWhilePaused());
        invariant_RewardsAreConservedAndBacked();
        invariant_SharesPerWeightNeverIncreaseAndStayQuotable();
    }

    function invariant_EveryOutcomeMatchesTheIndependentPrediction() public view {
        assertEq(handler.unexpectedOutcomes(), 0);
        assertFalse(handler.guardBypassed(), "stale maxSupply did not stop a merge");
        assertFalse(handler.admittedDuringPausedBacklog(), "admission into an unfunded certified round");
    }

    function invariant_BurnsNeverTakeSupplyBelowTheFloor() public view {
        assertFalse(handler.burnBrokeFloor());
    }

    function invariant_SharesPerWeightNeverIncreaseAndStayQuotable() public view {
        assertFalse(handler.ratioIncreased());
        uint256 supply = vault.totalSupply();
        if (supply == 0) return;
        // Burns stop at 1e9 per weight unit; merges can then lower it by at most a few orders.
        assertGe(supply, vault.totalWeight() * 1e6, "later deposits lost their pricing precision");
    }

    function invariant_NoCheckpointIsAttemptedWhileCoreIsPaused() public view {
        assertFalse(handler.checkpointedWhilePaused());
    }

    function invariant_RewardsAreConservedAndBacked() public view {
        uint256 held = sqk.balanceOf(address(vault));
        assertEq(vault.totalRewardsReceived(), vault.totalRewardsPaid() + held);
        uint256 owed;
        uint256 shares;
        for (uint256 i; i < 3; ++i) {
            owed += vault.claimableRewards(handler.actorAt(i));
            shares += vault.balanceOf(handler.actorAt(i));
        }
        assertLe(owed, held);
        assertEq(shares, vault.totalSupply());
    }
}
