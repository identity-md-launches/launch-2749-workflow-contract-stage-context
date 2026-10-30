// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Graph A's externally deployed contracts. Tuples match the verified v6/v3 ABIs.
interface IGraphAMining {
    struct Position {
        uint64 activeWeight;
        uint64 pendingWeight;
        uint40 pendingRound;
        uint48 nextMergeBlock;
        uint8 level;
        uint256 lastIndex;
        uint256 accruedScaled;
    }

    struct Configuration {
        address core;
        bytes32 streamId;
        address governance;
        address token;
        address genesisCollection;
        uint64 genesisTimestamp;
        uint16 genesisMaxSupply;
        uint64 maxWorkPerRound;
        uint64 minimumTimelockDelay;
        uint128 supplyCap;
        uint8 genesisMaximumLevel;
        uint32 initialWorkPerThousandBlocks;
    }

    function core() external view returns (address);
    function implementationCodeVersion() external view returns (uint64);
    function implementationCodeAddress() external view returns (address);
    function deploymentIdentity() external view returns (address implementation, address admin);
    function configuration() external view returns (Configuration memory);
    function MAX_LEVELS() external view returns (uint256);
    function MAX_CLAIMS() external view returns (uint256);
    function weightForLevel(uint8 collection, uint8 level) external view returns (uint64);
    function position(uint8 collection, uint256 tokenId) external view returns (Position memory);
    function claimable(uint8 collection, uint256[] calldata tokenIds) external view returns (uint256);
    function merge(uint8 collection, uint256 survivorId, uint256 donorId) external;
    function claim(uint8 collection, uint256[] calldata tokenIds) external returns (uint256 paid);
    function checkpoint() external;
    function checkpointStatus() external view returns (bool corePaused, uint64 nextRound, bool roundSettled);
}

interface IGraphACore {
    struct State {
        uint64 settledThroughRound;
        uint64 cumulativeWork;
        uint96 cumulativeBlockUnits;
        uint64 blockHeight;
        uint96 blockProgress;
        uint32 workPerThousandBlocks;
        uint256 authorizationNonce;
        bool paused;
    }

    function implementationCodeVersion() external view returns (uint64);
    function state() external view returns (State memory);
}

interface IGraphANFT is IERC721 {
    function mining() external view returns (address);
    function sqkCore() external view returns (address);
    function publicMinted() external view returns (uint16);
    function totalSupply() external view returns (uint256);
}
