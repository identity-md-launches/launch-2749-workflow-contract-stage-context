// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IGraphAMining, IGraphACore, IGraphANFT} from "./interfaces/IGraphA.sol";

/// @title Hamster Mining Reserve
/// @notice Permanent Graph A NFT custody with transferable mining-accounting shares.
/// @dev No NFT redemption, sale, admin sweep, arbitrary call or upgrade path exists.
contract HamsterMiningReserve is ERC20, Ownable2Step, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    uint256 public constant CHAIN_ID = 11155111;
    address public constant CORE = 0x74665dAecA35A2303e767E76a2FF1FB6F93e119f;
    address public constant MINING = 0x3beE588fC20dE788Bac17d33b41Da7346cb27EC4;
    address public constant NFT = 0x0eAF3E0d40A0a8E5a6Ac030b2459E9FB0B7905c6;
    address public constant MINING_IMPLEMENTATION = 0x08890b360C65FD878344Bf6e23d1c36358433B4E;
    uint8 public constant COLLECTION = 0;
    uint8 public constant MAX_LEVELS = 10;
    uint256 public constant MAX_CLAIMS = 32;
    // A full claim must fit in one external batch on every balance/supply change.
    uint256 public constant MAX_RESERVE_NFTS = 32;
    uint256 public constant INITIAL_SHARES_PER_WEIGHT = 1e18;
    /// @notice Voluntary burns may not leave fewer share units per final weight unit than this.
    /// @dev Keeps deposit pricing floor(w*S/W) precise to about 1e-9, so a dominant holder cannot
    /// collapse supply and lock out or under-mint later depositors. Never binding without burns.
    uint256 public constant MIN_SHARES_PER_WEIGHT = 1e9;
    uint256 public constant REWARD_PRECISION = 1e36;

    IERC20 public rewardToken;
    address public strategist;
    bool public activated;
    /// @notice Sum of final level weights, including a merge bonus awaiting activation.
    uint256 public totalWeight;
    uint256 public rewardPerShare;
    uint256 public totalRewardsReceived;
    uint256 public totalRewardsPaid;

    mapping(uint256 tokenId => uint8 level) public reserveLevel;
    mapping(address account => uint256 amount) public accruedRewards;
    mapping(address account => uint256 index) public rewardIndex;
    mapping(address account => uint256 scaledFraction) public rewardFraction;
    uint256[] private _liveIds;

    address private _expectedDepositor;
    uint256 private _expectedId;
    bool private _receiving;

    error NotActivated();
    error AlreadyActivated();
    error WrongChain();
    error InvalidGraph();
    error UnsupportedImplementation();
    error InvalidStrategist();
    error OnlyStrategist();
    error InvalidDeposit();
    error InvalidPosition(uint256 tokenId);
    error PendingActivation(uint256 tokenId);
    error ReserveFull();
    error MinimumSharesNotMet(uint256 actual, uint256 minimum);
    error UnexpectedNFT();
    error InvalidMerge();
    error MergeCooldown(uint256 readyAt, uint256 coreHeight);
    error CheckpointRequired();
    error InvalidRewardPayment();
    error InvalidExit();
    error SupplyBelowFloor(uint256 remainingSupply, uint256 minimumSupply);
    error UnexpectedSupply(uint256 actualSupply, uint256 maximumSupply);
    error InvalidShareRecipient();

    event Activated(address indexed rewardToken);
    event StrategistUpdated(address indexed previousStrategist, address indexed newStrategist);
    event Deposited(
        address indexed depositor,
        uint256 indexed tokenId,
        uint256 weight,
        uint256 shares,
        uint256 carriedRewards
    );
    event Merged(uint256 indexed survivorId, uint256 indexed donorId, uint8 level, uint256 totalWeight);
    event Harvested(uint256 amount, uint256 rewardPerShare);
    event RewardsClaimed(address indexed account, uint256 amount);
    event SharesRenounced(address indexed account, uint256 shares);

    /// @param owner_ Launch owner; neither the deploying factory nor tx.origin receives a role.
    /// @dev No external calls: deployable on an empty chain through the launch factory.
    constructor(address owner_) ERC20("Hamster Mining Reserve Share", "hmSQUEEK") Ownable(owner_) {
        strategist = owner_;
        emit StrategistUpdated(address(0), owner_);
    }

    /// @notice One-time owner activation verifies Graph A and discovers its SQK from Mining.
    /// @dev The token cannot subsequently be redirected, including by the owner.
    function activate() external nonReentrant onlyOwner {
        if (activated) revert AlreadyActivated();
        if (block.chainid != CHAIN_ID) revert WrongChain();
        _validateIdentity();
        IGraphAMining.Configuration memory cfg = IGraphAMining(MINING).configuration();
        if (
            cfg.core != CORE || cfg.genesisCollection != NFT || cfg.token == address(0)
                || cfg.token == address(this) || cfg.token.code.length == 0
                || cfg.genesisMaximumLevel != MAX_LEVELS || IGraphANFT(NFT).mining() != MINING
                || IGraphANFT(NFT).sqkCore() != CORE || IGraphAMining(MINING).MAX_LEVELS() != MAX_LEVELS
                || IGraphAMining(MINING).MAX_CLAIMS() != MAX_CLAIMS
        ) revert InvalidGraph();
        for (uint8 level = 1; level <= MAX_LEVELS; ++level) {
            if (IGraphAMining(MINING).weightForLevel(COLLECTION, level) != weightForLevel(level)) {
                revert InvalidGraph();
            }
        }
        rewardToken = IERC20(cfg.token);
        activated = true;
        emit Activated(cfg.token);
    }

    function setStrategist(address newStrategist) external onlyOwner {
        if (newStrategist == address(0) || newStrategist == address(this)) revert InvalidStrategist();
        emit StrategistUpdated(strategist, newStrategist);
        strategist = newStrategist;
    }

    /// @notice Ownership can be renounced only once the vault is activated; before that it would
    /// make activation, and therefore the whole vault, permanently unreachable.
    function renounceOwnership() public override onlyOwner {
        _requireActive();
        super.renounceOwnership();
    }

    /// @notice Permanently contribute one live, fully activated Genesis NFT owned by the caller.
    /// @param minShares Minimum shares accepted; protects against a preceding merge or burn.
    /// @dev Historical funded SQK carried by this NFT is credited only to the depositor.
    function deposit(uint256 tokenId, uint256 minShares) external nonReentrant returns (uint256 shares) {
        _requireActive();
        if (tokenId == 0 || reserveLevel[tokenId] != 0 || IGraphANFT(NFT).ownerOf(tokenId) != msg.sender) {
            revert InvalidDeposit();
        }
        if (_liveIds.length == MAX_RESERVE_NFTS) revert ReserveFull();
        _prepareShareChange(false);
        IGraphAMining.Position memory pos = IGraphAMining(MINING).position(COLLECTION, tokenId);
        uint256 weight = _settledWeight(tokenId, pos);
        uint256 supply = totalSupply();
        shares = supply == 0 ? weight * INITIAL_SHARES_PER_WEIGHT : Math.mulDiv(weight, supply, totalWeight);
        if (shares == 0 || shares < minShares) revert MinimumSharesNotMet(shares, minShares);

        _expectedDepositor = msg.sender;
        _expectedId = tokenId;
        _receiving = true;
        IGraphANFT(NFT).safeTransferFrom(msg.sender, address(this), tokenId);
        if (_receiving || IGraphANFT(NFT).ownerOf(tokenId) != address(this)) revert UnexpectedNFT();
        delete _expectedDepositor;
        delete _expectedId;

        uint256[] memory incoming = new uint256[](1);
        incoming[0] = tokenId;
        uint256 carried = _collect(incoming);
        _accrue(msg.sender);
        accruedRewards[msg.sender] += carried;
        reserveLevel[tokenId] = pos.level;
        totalWeight += weight;
        _insertId(tokenId);
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, tokenId, weight, shares, carried);
    }

    /// @notice Strategist combines equal levels. The donor is burned by Mining, never withdrawn.
    /// @dev Final weight rises by 1000 immediately for share pricing; active weight rises later.
    /// Mining must still be the pinned v6 implementation: merging is the one call that changes positions.
    /// @param maxSupply Reverts if share supply exceeds it, so a deposit ordered just before this
    /// merge cannot take part of the bonus; pass the supply observed when the merge was prepared.
    function merge(uint256 survivorId, uint256 donorId, uint256 maxSupply) external nonReentrant {
        if (msg.sender != strategist) revert OnlyStrategist();
        _requireActive();
        _validateIdentity();
        uint256 supply = totalSupply();
        if (supply > maxSupply) revert UnexpectedSupply(supply, maxSupply);
        uint8 level = reserveLevel[survivorId];
        if (survivorId == donorId || level == 0 || level != reserveLevel[donorId] || level >= MAX_LEVELS) {
            revert InvalidMerge();
        }
        _prepareShareChange(false);
        IGraphAMining.Position memory survivor = IGraphAMining(MINING).position(COLLECTION, survivorId);
        IGraphAMining.Position memory donor = IGraphAMining(MINING).position(COLLECTION, donorId);
        uint256 combined = _settledWeight(survivorId, survivor) + _settledWeight(donorId, donor);
        if (survivor.level != level || donor.level != level) revert InvalidMerge();
        uint256 height = IGraphACore(CORE).state().blockHeight;
        uint256 readyAt = Math.max(survivor.nextMergeBlock, donor.nextMergeBlock);
        if (height < readyAt) revert MergeCooldown(readyAt, height);

        IGraphAMining(MINING).merge(COLLECTION, survivorId, donorId);
        IGraphAMining.Position memory afterMerge = IGraphAMining(MINING).position(COLLECTION, survivorId);
        uint256 finalWeight = weightForLevel(level + 1);
        if (
            afterMerge.level != level + 1 || afterMerge.activeWeight != combined
                || afterMerge.pendingWeight != finalWeight || afterMerge.pendingRound == 0
                || IGraphAMining(MINING).position(COLLECTION, donorId).level != 0
                || IGraphANFT(NFT).ownerOf(survivorId) != address(this)
        ) revert InvalidMerge();
        reserveLevel[survivorId] = level + 1;
        delete reserveLevel[donorId];
        _removeId(donorId);
        totalWeight += finalWeight - combined;
        emit Merged(survivorId, donorId, level + 1, totalWeight);
    }

    /// @notice Anyone can collect already-funded Mining rewards for every live reserve NFT.
    /// @dev Does not require Core to be unpaused or Mining to keep its pinned identity: only SQK
    /// physically received, matching Mining's reported payment, is distributed. Checkpoint Mining
    /// separately to fund new rounds.
    function harvest() external nonReentrant returns (uint256 amount) {
        _requireActive();
        amount = _harvest();
    }

    /// @notice Pays only the caller's accounted SQK, including after their final share transfer.
    /// @dev Independent of Core availability or Mining upgrades. Call harvest first for new rewards.
    function claimRewards() external nonReentrant returns (uint256 amount) {
        _requireActive();
        _accrue(msg.sender);
        amount = accruedRewards[msg.sender];
        if (amount == 0) return 0;
        accruedRewards[msg.sender] = 0;
        totalRewardsPaid += amount;
        rewardToken.safeTransfer(msg.sender, amount);
        emit RewardsClaimed(msg.sender, amount);
    }

    /// @notice Voluntarily abandon future rewards; NFTs stay in the reserve and accrued SQK stays claimable.
    /// @dev Burning the entire supply is prohibited to prevent a later first depositor taking the reserve,
    /// and the remaining supply must keep at least MIN_SHARES_PER_WEIGHT units per final weight unit so
    /// later deposits are still priced precisely. Ordinary exit is transfer/transferFrom to a willing
    /// recipient, including one's whole balance.
    function renounceShares(uint256 shares) external nonReentrant {
        uint256 supply = totalSupply();
        if (shares == 0 || shares >= supply) revert InvalidExit();
        uint256 remaining = supply - shares;
        uint256 minimum = totalWeight * MIN_SHARES_PER_WEIGHT;
        if (remaining < minimum) revert SupplyBelowFloor(remaining, minimum);
        _prepareShareChange(true);
        _burn(msg.sender, shares);
        emit SharesRenounced(msg.sender, shares);
    }

    function transfer(address to, uint256 value) public override nonReentrant returns (bool) {
        if (to == address(this)) revert InvalidShareRecipient();
        if (value != 0 && to != msg.sender) _prepareShareChange(true);
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value)
        public
        override
        nonReentrant
        returns (bool)
    {
        if (to == address(this)) revert InvalidShareRecipient();
        if (value != 0 && to != from) _prepareShareChange(true);
        return super.transferFrom(from, to, value);
    }

    /// @notice Rejects unsolicited safe transfers; only deposit may enter an NFT.
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (
            msg.sender != NFT || !_receiving || operator != address(this) || from != _expectedDepositor
                || tokenId != _expectedId
        ) revert UnexpectedNFT();
        _receiving = false;
        return IERC721Receiver.onERC721Received.selector;
    }

    function weightForLevel(uint8 level) public pure returns (uint256) {
        if (level == 0 || level > MAX_LEVELS) revert InvalidMerge();
        return 1000 * ((uint256(1) << level) - 1);
    }

    function liveTokenIds() external view returns (uint256[] memory) {
        return _liveIds;
    }

    function reserveCount() external view returns (uint256) {
        return _liveIds.length;
    }

    function previewDeposit(uint256 tokenId) external view returns (uint256 shares) {
        _requireActive();
        IGraphAMining.Position memory pos = IGraphAMining(MINING).position(COLLECTION, tokenId);
        uint256 weight = _settledWeight(tokenId, pos);
        uint256 supply = totalSupply();
        return supply == 0 ? weight * INITIAL_SHARES_PER_WEIGHT : Math.mulDiv(weight, supply, totalWeight);
    }

    /// @notice Accounted rewards only, excluding unharvested SQK and uncertified physical work.
    function claimableRewards(address account) public view returns (uint256) {
        uint256 delta = rewardPerShare - rewardIndex[account];
        uint256 balance = balanceOf(account);
        return accruedRewards[account] + Math.mulDiv(balance, delta, REWARD_PRECISION)
            + (mulmod(balance, delta, REWARD_PRECISION) + rewardFraction[account]) / REWARD_PRECISION;
    }

    /// @notice SQK funded in Mining and currently claimable by the reserve, before vault distribution.
    function pendingMiningRewards() external view returns (uint256) {
        _requireActive();
        if (_liveIds.length == 0) return 0;
        return IGraphAMining(MINING).claimable(COLLECTION, _liveIds);
    }

    /// @notice Actual active/pending weights; final pricing weight is totalWeight().
    function miningWeights() external view returns (uint256 active, uint256 pendingIncrease) {
        _requireActive();
        for (uint256 i; i < _liveIds.length; ++i) {
            IGraphAMining.Position memory pos = IGraphAMining(MINING).position(COLLECTION, _liveIds[i]);
            active += pos.activeWeight;
            if (pos.pendingRound != 0) pendingIncrease += pos.pendingWeight - pos.activeWeight;
        }
    }

    function _requireActive() private view {
        if (!activated) revert NotActivated();
    }

    function _validateIdentity() private view {
        if (
            MINING.code.length == 0 || CORE.code.length == 0 || NFT.code.length == 0
                || IGraphAMining(MINING).implementationCodeVersion() != 6
                || IGraphAMining(MINING).implementationCodeAddress() != MINING_IMPLEMENTATION
                || IGraphAMining(MINING).core() != CORE || IGraphACore(CORE).implementationCodeVersion() != 3
        ) revert UnsupportedImplementation();
        // This selector is implemented by the proxy itself, not its upgradeable logic.
        (address implementation,) = IGraphAMining(MINING).deploymentIdentity();
        if (implementation != MINING_IMPLEMENTATION) revert UnsupportedImplementation();
    }

    /// @dev Advances funded rounds and claims every live NFT before shares move, so already-certified
    /// rewards cannot follow new or transferred shares. Identity is deliberately not re-pinned here:
    /// a Mining upgrade must not strand the reserve's SQK or block the share-transfer exit.
    /// @param exit True for transfers and burns between existing holders. While Core is paused nobody
    /// can checkpoint, so exits proceed on funded state alone and only admissions (deposit, merge) wait.
    function _prepareShareChange(bool exit) private {
        _requireActive();
        (bool corePaused,, bool settled) = IGraphAMining(MINING).checkpointStatus();
        if (settled) {
            if (!corePaused) {
                IGraphAMining(MINING).checkpoint();
                (,, settled) = IGraphAMining(MINING).checkpointStatus();
            }
            if (settled && !(exit && corePaused)) revert CheckpointRequired();
        }
        _harvest();
    }

    function _settledWeight(uint256 id, IGraphAMining.Position memory pos)
        private
        pure
        returns (uint256 weight)
    {
        if (pos.level == 0 || pos.level > MAX_LEVELS) revert InvalidPosition(id);
        if (pos.pendingRound != 0 || pos.pendingWeight != 0) revert PendingActivation(id);
        weight = weightForLevel(pos.level);
        if (pos.activeWeight != weight) revert InvalidPosition(id);
    }

    function _harvest() private returns (uint256 amount) {
        if (_liveIds.length == 0) return 0;
        amount = _collect(_liveIds);
        if (amount != 0) rewardPerShare += Math.mulDiv(amount, REWARD_PRECISION, totalSupply());
        emit Harvested(amount, rewardPerShare);
    }

    function _collect(uint256[] memory ids) private returns (uint256 amount) {
        uint256 beforeBalance = rewardToken.balanceOf(address(this));
        uint256 reported = IGraphAMining(MINING).claim(COLLECTION, ids);
        uint256 afterBalance = rewardToken.balanceOf(address(this));
        if (afterBalance < beforeBalance) revert InvalidRewardPayment();
        amount = afterBalance - beforeBalance;
        if (reported != amount) revert InvalidRewardPayment();
        totalRewardsReceived += amount;
    }

    function _accrue(address account) private {
        uint256 delta = rewardPerShare - rewardIndex[account];
        if (delta == 0) return;
        uint256 balance = balanceOf(account);
        uint256 fractional = mulmod(balance, delta, REWARD_PRECISION) + rewardFraction[account];
        accruedRewards[account] += Math.mulDiv(balance, delta, REWARD_PRECISION) + fractional
        / REWARD_PRECISION;
        rewardFraction[account] = fractional % REWARD_PRECISION;
        rewardIndex[account] = rewardPerShare;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) _accrue(from);
        if (to != address(0)) _accrue(to);
        super._update(from, to, value);
    }

    function _insertId(uint256 id) private {
        _liveIds.push(id);
        uint256 i = _liveIds.length - 1;
        while (i != 0 && _liveIds[i - 1] > id) {
            _liveIds[i] = _liveIds[i - 1];
            --i;
        }
        _liveIds[i] = id;
    }

    function _removeId(uint256 id) private {
        uint256 length = _liveIds.length;
        for (uint256 i; i < length; ++i) {
            if (_liveIds[i] != id) continue;
            for (uint256 j = i; j + 1 < length; ++j) {
                _liveIds[j] = _liveIds[j + 1];
            }
            _liveIds.pop();
            return;
        }
        revert InvalidPosition(id);
    }
}
