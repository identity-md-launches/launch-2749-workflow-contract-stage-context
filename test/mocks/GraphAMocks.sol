// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IGraphAMining, IGraphACore, IGraphANFT} from "../../src/interfaces/IGraphA.sol";

contract MockSQK is ERC20 {
    bool public failTransfer;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bool public callbackAttempted;
    bool private calling;

    constructor() ERC20("Mock SQK", "SQK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailTransfer(bool fail) external {
        failTransfer = fail;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
        callbackSucceeded = false;
        callbackAttempted = false;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (failTransfer) return false;
        if (callbackTarget != address(0) && !calling) {
            calling = true;
            callbackAttempted = true;
            (callbackSucceeded,) = callbackTarget.call(callbackData);
            calling = false;
        }
        return super.transfer(to, value);
    }
}

contract MockCore is IGraphACore {
    uint64 public version;
    State private _state;

    function configure() external {
        version = 3;
        _state.blockHeight = 100_000;
    }

    function setVersion(uint64 value) external {
        version = value;
    }

    function setHeight(uint64 value) external {
        _state.blockHeight = value;
    }

    function setPaused(bool value) external {
        _state.paused = value;
    }

    function implementationCodeVersion() external view returns (uint64) {
        return version;
    }

    function state() external view returns (State memory) {
        return _state;
    }
}

contract MockNFT is ERC721 {
    address public constant mining = 0x3beE588fC20dE788Bac17d33b41Da7346cb27EC4;
    address public constant sqkCore = 0x74665dAecA35A2303e767E76a2FF1FB6F93e119f;
    bool public failBurn;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bool public callbackAttempted;
    constructor() ERC721("Mock Squeek", "SQUEEK") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function setFailBurn(bool fail) external {
        failBurn = fail;
    }

    function burnForMerge(uint256 id) external {
        require(msg.sender == mining, "mining only");
        require(!failBurn, "burn failed");
        _burn(id);
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
        callbackSucceeded = false;
        callbackAttempted = false;
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public override {
        if (callbackTarget != address(0)) {
            callbackAttempted = true;
            (callbackSucceeded,) = callbackTarget.call(callbackData);
        }
        super.safeTransferFrom(from, to, id, data);
    }
}

/// @dev Deliberately controllable local dependency; no production authority or deployment role.
contract MockMining is IGraphAMining {
    address public constant core = 0x74665dAecA35A2303e767E76a2FF1FB6F93e119f;
    address public constant NFT = 0x0eAF3E0d40A0a8E5a6Ac030b2459E9FB0B7905c6;
    uint256 public constant MAX_LEVELS = 10;
    uint256 public constant MAX_CLAIMS = 32;
    uint256 private constant Q128 = 1 << 128;
    uint64 public version;
    address public implementation;
    Configuration private _configuration;
    mapping(uint256 => Position) private _positions;
    mapping(uint256 => uint256) private _deferred;
    uint256[] private _registered;
    uint256 public checkpointBacklog;
    bool public failClaim;
    bool public misreportClaim;
    bool public corruptMerge;
    uint256 public claimCalls;
    uint256 public checkpoints;

    function configure(address token) external {
        version = 6;
        implementation = 0x08890b360C65FD878344Bf6e23d1c36358433B4E;
        _configuration.core = core;
        _configuration.token = token;
        _configuration.genesisCollection = NFT;
        _configuration.genesisMaximumLevel = 10;
    }

    function configuration() external view returns (Configuration memory) {
        return _configuration;
    }

    function implementationCodeVersion() external view returns (uint64) {
        return version;
    }

    function implementationCodeAddress() external view returns (address) {
        return implementation;
    }

    function deploymentIdentity() external view returns (address, address) {
        return (implementation, core);
    }

    function setIdentity(uint64 v, address impl) external {
        version = v;
        implementation = impl;
    }

    function setConfiguration(Configuration calldata cfg) external {
        _configuration = cfg;
    }

    function setFailClaim(bool fail) external {
        failClaim = fail;
    }

    function setMisreportClaim(bool fail) external {
        misreportClaim = fail;
    }

    function setCorruptMerge(bool fail) external {
        corruptMerge = fail;
    }

    function setBacklog(uint256 rounds) external {
        checkpointBacklog = rounds;
    }

    function register(uint256 id, uint8 level) external {
        _positions[id] = Position(uint64(weightForLevel(0, level)), 0, 0, 0, level, 0, 0);
        _registered.push(id);
    }

    function setPosition(uint256 id, Position calldata pos) external {
        _positions[id] = pos;
    }

    function credit(uint256 id, uint256 amount) public {
        _positions[id].accruedScaled += amount * Q128;
        MockSQK(_configuration.token).mint(address(this), amount);
    }

    function deferCredit(uint256 id, uint256 amount) external {
        _deferred[id] += amount;
        checkpointBacklog = 1;
    }

    function weightForLevel(uint8 collection, uint8 level) public pure returns (uint64) {
        require(collection == 0 && level > 0 && level <= 10, "level");
        return uint64(1000 * ((uint256(1) << level) - 1));
    }

    function position(uint8 collection, uint256 id) external view returns (Position memory) {
        require(collection == 0, "collection");
        return _positions[id];
    }

    function claimable(uint8 collection, uint256[] calldata ids) external view returns (uint256 total) {
        require(collection == 0 && ids.length > 0 && ids.length <= 32, "batch");
        uint256 previous;
        for (uint256 i; i < ids.length; ++i) {
            require(ids[i] > previous && _positions[ids[i]].level != 0, "ids");
            total += _positions[ids[i]].accruedScaled;
            previous = ids[i];
        }
        return total / Q128;
    }

    function claim(uint8 collection, uint256[] calldata ids) external returns (uint256 paid) {
        require(!failClaim, "claim failed");
        require(collection == 0 && ids.length > 0 && ids.length <= 32, "batch");
        uint256 scaled;
        uint256 previous;
        for (uint256 i; i < ids.length; ++i) {
            require(ids[i] > previous && _positions[ids[i]].level != 0, "ids");
            require(IGraphANFT(NFT).ownerOf(ids[i]) == msg.sender, "owner");
            scaled += _positions[ids[i]].accruedScaled;
            _positions[ids[i]].accruedScaled = 0;
            previous = ids[i];
        }
        paid = scaled / Q128;
        _positions[ids[0]].accruedScaled = scaled % Q128;
        ++claimCalls;
        if (paid != 0) require(MockSQK(_configuration.token).transfer(msg.sender, paid), "transfer failed");
        if (misreportClaim) ++paid;
    }

    function merge(uint8 collection, uint256 survivorId, uint256 donorId) external {
        require(collection == 0 && survivorId != donorId, "collection/id");
        Position storage s = _positions[survivorId];
        Position memory d = _positions[donorId];
        require(s.level != 0 && s.level == d.level && s.level < 10, "level");
        require(s.pendingRound == 0 && d.pendingRound == 0, "pending");
        require(IGraphANFT(NFT).ownerOf(survivorId) == msg.sender, "owner");
        require(IGraphANFT(NFT).ownerOf(donorId) == msg.sender, "owner");
        uint64 height = IGraphACore(core).state().blockHeight;
        require(height >= s.nextMergeBlock && height >= d.nextMergeBlock, "cooldown");
        s.activeWeight += d.activeWeight;
        s.accruedScaled += d.accruedScaled;
        ++s.level;
        s.pendingWeight = weightForLevel(0, s.level);
        s.pendingRound = 2;
        s.nextMergeBlock = 100_001;
        if (corruptMerge) s.pendingWeight += 1;
        delete _positions[donorId];
        MockNFT(NFT).burnForMerge(donorId);
    }

    function activatePending() external {
        for (uint256 i; i < _registered.length; ++i) {
            Position storage p = _positions[_registered[i]];
            if (p.pendingRound == 0) continue;
            p.activeWeight = p.pendingWeight;
            p.pendingWeight = 0;
            p.pendingRound = 0;
        }
    }

    function checkpointStatus() external view returns (bool corePaused, uint64 nextRound, bool roundSettled) {
        return (IGraphACore(core).state().paused, 1, checkpointBacklog != 0);
    }

    function checkpoint() external {
        require(!IGraphACore(core).state().paused, "core paused");
        require(checkpointBacklog != 0, "not settled");
        --checkpointBacklog;
        ++checkpoints;
        if (checkpointBacklog == 0) {
            for (uint256 i; i < _registered.length; ++i) {
                uint256 id = _registered[i];
                if (_deferred[id] == 0) continue;
                credit(id, _deferred[id]);
                _deferred[id] = 0;
            }
        }
    }
}
