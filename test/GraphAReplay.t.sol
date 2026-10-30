// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GraphAAssertions} from "./helpers/GraphAAssertions.sol";
import {GraphASnapshot} from "./fixtures/GraphASnapshot.sol";

/// @notice Replays the real Sepolia contract runtimes and accessed state without network or filesystem access.
contract GraphAReplayTest is GraphAAssertions {
    function setUp() public override {
        GraphASnapshot.load(vm);
        super.setUp();
    }
}
