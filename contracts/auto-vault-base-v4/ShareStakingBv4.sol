// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "../v4/V4Deployments8453.sol";
import "./libraries/LiquidityLibraryV4.sol";
import "./interfaces/IShareStakingBv4.sol";
import "./interfaces/IAutoStrategyBv4.sol";
import "./interfaces/IAutoSwapRouterBv4.sol";
import "./interfaces/ILiquidSharesBv4.sol";

/// @title ShareStakingBv4
/// @notice Per-vault LiquidSharesBv4 staking with fixed-length epochs (Base V4).
/// @dev Weight = amount × seconds in epoch. Rewards paid in WETH after epoch ends.
///      No early exit: stake locks until that epoch's end. Stake is non-transferable.
///      EPOCH_DURATION is 2 days for real-world testing; switch back to 30 days for production.
///      ASSET→WETH uses AutoSwapRouterBv4 with the package PoolKey (not native ETH pairs).
contract ShareStakingBv4 is Ownable, ReentrancyGuard, IShareStakingBv4 {
    using SafeERC20 for IERC20;

    uint256 public constant DIVISOR = 10_000;
    uint256 public constant EPOCH_DURATION = 2 days;
    /// @notice Hard cap on owner cut of epoch WETH rewards (30%).
    uint256 public constant MAX_OWNER_REWARD_BPS = 3_000;

    IERC20 public immutable weth;
    ILiquidSharesBv4 public liquidShares;
    IAutoSwapRouterBv4 public swapRouter;
    address public strategy;
    address public asset;
    LiquidityLibraryV4.PoolKey public poolKey;
    bytes public hookData;
    address public immutable factory;
    bool public bootstrapped;
    /// @notice After one factory ownership transfer (e.g. to ERC-6551), ownership cannot move again.
    bool public ownershipLocked;
    /// @notice One-shot open switch. Starts false; activate() can flip to true once.
    bool public active;

    /// @notice Share of each epoch's WETH pot credited to `ownerRewardRecipient` at finalize. Default 0; max 10%.
    /// @dev Only settable after ownership is locked (second/last owner). Deployer cannot raise above 0.
    uint256 public ownerRewardBps;
    /// @notice Recipient of the owner cut at epoch finalize. If zero, uses `owner()`.
    address public ownerRewardRecipient;

    uint256 public epoch0Start;
    uint256 public currentEpoch;
    uint256 public lastGlobalCheckpoint;
    uint256 public totalStaked;

    /// @dev Claimable stake-seconds accrued in the active epoch.
    uint256 public totalWeightCurrent;

    /// @dev WETH owed to stakers (sum of epochRewardWeth) + pendingOwnerReward. Rescue may only skim surplus.
    uint256 public accountedWeth;

    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public userLastCheckpoint;
    /// @dev Earliest timestamp the user may unstake (end of epoch in which they last acquired stake).
    mapping(address => uint256) public lockedUntil;
    /// @dev Pull-based owner cut so a reverting recipient cannot brick epoch finalization.
    mapping(address => uint256) public pendingOwnerReward;

    mapping(uint256 => uint256) public epochRewardWeth;
    mapping(uint256 => uint256) public epochTotalWeight;
    mapping(uint256 => bool) public epochFinalized;

    mapping(address => mapping(uint256 => uint256)) public userEpochWeight;
    mapping(address => mapping(uint256 => bool)) public epochClaimed;

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error AlreadyBootstrapped();
    error NotBootstrapped();
    error EpochNotEnded();
    error AlreadyClaimed();
    error NothingToClaim();
    error InvalidBps();
    error InsufficientStake();
    error OwnershipIsLocked();
    error AlreadyActive();
    error NotActive();
    error SettingsLockedToDeployer();
    error EpochExitLocked();

    event Staked(address indexed user, uint256 amount);
    event Activated(address indexed by, uint64 timestamp);
    event Unstaked(address indexed user, uint256 amount);
    /// @dev `wethAdded == 0` means ASSET→WETH soft-fail (tokens stranded for `retryAssetRewardSwap`).
    event RewardNotified(address indexed token, uint256 amountIn, uint256 wethAdded, uint256 epoch);
    event EpochFinalized(
        uint256 indexed epoch, uint256 stakerRewardWeth, uint256 ownerRewardWeth, uint256 totalWeight
    );
    /// @dev Owner-cut pulls use `epoch == type(uint256).max`.
    event Claimed(address indexed user, uint256 indexed epoch, uint256 wethAmount);

    modifier onlyStrategy() {
        if (msg.sender != strategy) revert Unauthorized();
        _;
    }

    constructor(address factory_) Ownable(msg.sender) {
        if (factory_ == address(0)) revert ZeroAddress();
        weth = IERC20(V4Deployments8453.WETH);
        factory = factory_;
    }

    function bootstrap(
        address owner_,
        address liquidShares_,
        address strategy_,
        address asset_,
        address swapRouter_,
        LiquidityLibraryV4.PoolKey calldata key,
        bytes calldata hookData_
    ) external {
        if (bootstrapped) revert AlreadyBootstrapped();
        if (msg.sender != factory) revert Unauthorized();
        if (
            owner_ == address(0) || liquidShares_ == address(0) || strategy_ == address(0) || asset_ == address(0)
                || swapRouter_ == address(0)
        ) revert ZeroAddress();

        liquidShares = ILiquidSharesBv4(liquidShares_);
        strategy = strategy_;
        asset = asset_;
        swapRouter = IAutoSwapRouterBv4(swapRouter_);
        poolKey = key;
        hookData = hookData_;
        epoch0Start = block.timestamp;
        currentEpoch = 0;
        lastGlobalCheckpoint = block.timestamp;
        bootstrapped = true;
        _transferOwnership(owner_);
    }

    /// @notice One-shot factory ownership move (e.g. package → ERC-6551 TBA). Locks ownership afterward.
    function transferOwnershipFromFactory(address newOwner) external {
        if (msg.sender != factory) revert Unauthorized();
        if (newOwner == address(0)) revert ZeroAddress();
        if (ownershipLocked) revert OwnershipIsLocked();
        _transferOwnership(newOwner);
        ownershipLocked = true;
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        if (ownershipLocked) revert OwnershipIsLocked();
        super.transferOwnership(newOwner);
    }

    function renounceOwnership() public pure override {
        revert OwnershipIsLocked();
    }

    /// @notice One-shot: open staking. Starts inactive; cannot be turned off after activate.
    function activate() external onlyOwner {
        if (active) revert AlreadyActive();
        if (!bootstrapped) revert NotBootstrapped();
        active = true;
        emit Activated(msg.sender, uint64(block.timestamp));
    }

    modifier whenActive() {
        if (!active) revert NotActive();
        _;
    }

    modifier onlyPostTransferOwner() {
        _checkOwner();
        if (!ownershipLocked) revert SettingsLockedToDeployer();
        _;
    }

    function setOwnerRewardBps(uint256 bps) external onlyPostTransferOwner {
        if (bps > MAX_OWNER_REWARD_BPS) revert InvalidBps();
        ownerRewardBps = bps;
    }

    function setOwnerRewardRecipient(address recipient) external onlyPostTransferOwner {
        if (recipient == address(0)) revert ZeroAddress();
        ownerRewardRecipient = recipient;
    }

    function epochStart(uint256 epoch) public view returns (uint256) {
        return epoch0Start + epoch * EPOCH_DURATION;
    }

    function epochEnd(uint256 epoch) public view returns (uint256) {
        return epochStart(epoch) + EPOCH_DURATION;
    }

    function epochAt(uint256 timestamp) public view returns (uint256) {
        if (timestamp <= epoch0Start) return 0;
        return (timestamp - epoch0Start) / EPOCH_DURATION;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _lockToCurrentEpochEnd(address user) internal {
        uint256 end = epochEnd(currentEpoch);
        if (end > lockedUntil[user]) lockedUntil[user] = end;
    }

    function _advanceGlobalTo(uint256 until) internal {
        if (until <= lastGlobalCheckpoint) return;
        uint256 t = lastGlobalCheckpoint;
        while (t < until) {
            uint256 ep = epochAt(t);
            uint256 epEnd_ = epochEnd(ep);
            uint256 to = _min(until, epEnd_);
            if (to > t && totalStaked > 0) {
                uint256 delta = totalStaked * (to - t);
                if (ep == currentEpoch) {
                    totalWeightCurrent += delta;
                } else {
                    epochTotalWeight[ep] += delta;
                }
            }
            t = to;
            if (t >= epEnd_ && ep == currentEpoch && until >= epEnd_) {
                uint256 ownerCut = _takeOwnerEpochCut(currentEpoch);
                epochTotalWeight[currentEpoch] = totalWeightCurrent;
                epochFinalized[currentEpoch] = true;
                emit EpochFinalized(currentEpoch, epochRewardWeth[currentEpoch], ownerCut, totalWeightCurrent);
                currentEpoch += 1;
                totalWeightCurrent = 0;
            }
        }
        lastGlobalCheckpoint = until;
    }

    function _takeOwnerEpochCut(uint256 epoch) internal returns (uint256 ownerCut) {
        uint256 pot = epochRewardWeth[epoch];
        if (pot == 0 || ownerRewardBps == 0) return 0;
        ownerCut = Math.mulDiv(pot, ownerRewardBps, DIVISOR);
        if (ownerCut == 0) return 0;
        epochRewardWeth[epoch] = pot - ownerCut;
        address to = ownerRewardRecipient == address(0) ? owner() : ownerRewardRecipient;
        pendingOwnerReward[to] += ownerCut;
    }

    function _checkpointUser(address user) internal {
        _advanceGlobalTo(block.timestamp);
        uint256 t = userLastCheckpoint[user];
        if (t == 0) {
            userLastCheckpoint[user] = block.timestamp;
            return;
        }
        uint256 bal = stakedBalance[user];
        uint256 until = block.timestamp;
        while (t < until) {
            uint256 ep = epochAt(t);
            uint256 epEnd_ = epochEnd(ep);
            uint256 to = _min(until, epEnd_);
            if (to > t && bal > 0) {
                userEpochWeight[user][ep] += bal * (to - t);
            }
            t = to;
        }
        userLastCheckpoint[user] = until;
    }

    function stake(uint256 amount) external nonReentrant whenActive {
        if (!bootstrapped) revert NotBootstrapped();
        if (amount == 0) revert ZeroAmount();
        _checkpointUser(msg.sender);
        IERC20(address(liquidShares)).safeTransferFrom(msg.sender, address(this), amount);
        stakedBalance[msg.sender] += amount;
        totalStaked += amount;
        _lockToCurrentEpochEnd(msg.sender);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (!bootstrapped) revert NotBootstrapped();
        if (amount == 0) revert ZeroAmount();
        if (amount > stakedBalance[msg.sender]) revert InsufficientStake();

        _checkpointUser(msg.sender);
        if (block.timestamp < lockedUntil[msg.sender]) revert EpochExitLocked();

        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;
        if (stakedBalance[msg.sender] == 0) lockedUntil[msg.sender] = 0;
        IERC20(address(liquidShares)).safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /// @inheritdoc IShareStakingBv4
    function notifyReward(address token, uint256 amount) external override nonReentrant onlyStrategy {
        if (amount == 0) revert ZeroAmount();
        _advanceGlobalTo(block.timestamp);

        uint256 wethAdded;
        if (token == address(weth)) {
            wethAdded = amount;
        } else if (token == asset) {
            if (amount > type(uint128).max) revert ZeroAmount();
            wethAdded = _swapAssetToWeth(uint128(amount));
            if (wethAdded == 0) {
                emit RewardNotified(token, amount, 0, currentEpoch);
                return;
            }
        } else {
            revert Unauthorized();
        }

        if (wethAdded == 0) return;
        epochRewardWeth[currentEpoch] += wethAdded;
        accountedWeth += wethAdded;
        emit RewardNotified(token, amount, wethAdded, currentEpoch);
    }

    function _swapAssetToWeth(uint128 amount) internal returns (uint256 wethAdded) {
        // Strategy owns the pricing and the stale-tick gate; a zero floor means it would refuse to swap too.
        uint256 minOut = IAutoStrategyBv4(strategy).minOutForSwap(asset, amount);
        if (minOut == 0) return 0;
        bool zeroForOne = asset == poolKey.currency0;
        IERC20(asset).forceApprove(address(swapRouter), amount);
        try swapRouter.swapExactInputSingleStrict(
            zeroForOne,
            amount,
            uint128(minOut),
            block.timestamp,
            IAutoSwapRouterBv4.AutoPoolKey({
                currency0: poolKey.currency0,
                currency1: poolKey.currency1,
                fee: poolKey.fee,
                tickSpacing: poolKey.tickSpacing,
                hooks: poolKey.hooks
            }),
            hookData
        ) returns (uint256 out) {
            wethAdded = out;
        } catch {
            IERC20(asset).forceApprove(address(swapRouter), 0);
            return 0;
        }
        IERC20(asset).forceApprove(address(swapRouter), 0);
    }

    function claim(uint256 epoch) external nonReentrant returns (uint256 wethOut) {
        _checkpointUser(msg.sender);
        if (epoch >= currentEpoch) revert EpochNotEnded();
        if (!epochFinalized[epoch]) revert EpochNotEnded();
        if (epochClaimed[msg.sender][epoch]) revert AlreadyClaimed();

        uint256 weight = userEpochWeight[msg.sender][epoch];
        uint256 totalW = epochTotalWeight[epoch];
        if (weight == 0 || totalW == 0) revert NothingToClaim();

        uint256 pot = epochRewardWeth[epoch];
        wethOut = Math.mulDiv(pot, weight, totalW);
        if (wethOut == 0) revert NothingToClaim();

        epochClaimed[msg.sender][epoch] = true;
        epochRewardWeth[epoch] = pot - wethOut;
        epochTotalWeight[epoch] = totalW - weight;
        userEpochWeight[msg.sender][epoch] = 0;
        accountedWeth -= wethOut;

        weth.safeTransfer(msg.sender, wethOut);
        emit Claimed(msg.sender, epoch, wethOut);
    }

    function claimOwnerReward() external nonReentrant returns (uint256 amount) {
        amount = pendingOwnerReward[msg.sender];
        if (amount == 0) revert NothingToClaim();
        pendingOwnerReward[msg.sender] = 0;
        accountedWeth -= amount;
        weth.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, type(uint256).max, amount);
    }


    function retryAssetRewardSwap(uint256 amount) external nonReentrant onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint128).max) revert ZeroAmount();
        _advanceGlobalTo(block.timestamp);
        uint256 wethAdded = _swapAssetToWeth(uint128(amount));
        if (wethAdded == 0) revert ZeroAmount();
        epochRewardWeth[currentEpoch] += wethAdded;
        accountedWeth += wethAdded;
        emit RewardNotified(asset, amount, wethAdded, currentEpoch);
    }
}
