// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
/// @dev Weight = amount × seconds in epoch. Rewards paid in ASSET after epoch ends.
///      No early exit: stake locks until that epoch's end. Stake is non-transferable.
///      EPOCH_DURATION is 14 days for production.
///      WETH→ASSET uses AutoSwapRouterBv4 with the package PoolKey (not native ETH pairs).
contract ShareStakingBv4 is Ownable, ReentrancyGuard, IShareStakingBv4 {
    using SafeERC20 for IERC20;

    uint256 public constant DIVISOR = 10_000;
    uint256 public constant EPOCH_DURATION = 14 days;
    /// @notice Hard cap on owner cut of epoch ASSET rewards (30%).
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

    /// @notice Share of each epoch's ASSET pot credited to `ownerRewardRecipient` at finalize. Default 0; max 10%.
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

    /// @dev ASSET owed to stakers (sum of epochRewardAsset) + pendingOwnerReward. Rescue may only skim surplus.
    uint256 public accountedAsset;

    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public userLastCheckpoint;
    /// @dev Earliest timestamp the user may unstake (end of epoch in which they last acquired stake).
    mapping(address => uint256) public lockedUntil;
    /// @dev Pull-based owner cut so a reverting recipient cannot brick epoch finalization.
    mapping(address => uint256) public pendingOwnerReward;

    mapping(uint256 => uint256) public epochRewardAsset;
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
    error UnbackedReward();
    error NothingToRescue();

    event Staked(address indexed user, uint256 amount);
    event Activated(address indexed by, uint64 timestamp);
    event Unstaked(address indexed user, uint256 amount);
    /// @dev `assetAdded == 0` means WETH→ASSET soft-fail (tokens stranded for `retryWethRewardSwap`).
    event RewardNotified(address indexed token, uint256 amountIn, uint256 assetAdded, uint256 epoch);
    event EpochFinalized(
        uint256 indexed epoch, uint256 stakerRewardAsset, uint256 ownerRewardAsset, uint256 totalWeight
    );
    /// @dev Owner-cut pulls use `epoch == type(uint256).max`.
    event Claimed(address indexed user, uint256 indexed epoch, uint256 assetAmount);
    event RewardRolledForward(uint256 indexed fromEpoch, uint256 indexed toEpoch, uint256 assetAmount);
    event Rescued(address indexed token, address indexed to, uint256 amount);

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
        currentEpoch = 0;
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

    /// @notice One-shot: open staking and start epoch 0. Harvests and `boostReward` that arrived while
    ///         inactive stay in epoch 0; the 14-day clock does not run until this call.
    function activate() external onlyOwner {
        if (active) revert AlreadyActive();
        if (!bootstrapped) revert NotBootstrapped();
        epoch0Start = block.timestamp;
        lastGlobalCheckpoint = block.timestamp;
        currentEpoch = 0;
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
        if (!active) return;
        if (until <= lastGlobalCheckpoint) return;
        uint256 t = lastGlobalCheckpoint;
        while (t < until) {
            uint256 ep = epochAt(t);
            uint256 epEnd_ = epochEnd(ep);
            uint256 to = _min(until, epEnd_);
            if (to > t && totalStaked > 0) {
                // `ep != currentEpoch` is unreachable while lastGlobalCheckpoint tracks currentEpoch. Dropping
                // the weight is the safe failure: writing it into an already-finalized epoch would dilute the
                // claimants that epoch was closed with.
                if (ep == currentEpoch) totalWeightCurrent += totalStaked * (to - t);
            }
            t = to;
            if (t >= epEnd_ && ep == currentEpoch && until >= epEnd_) {
                uint256 closing = currentEpoch;
                uint256 ownerCut;
                if (totalWeightCurrent == 0) {
                    // No stake-time means no address can ever satisfy the claim condition for this pot, so
                    // carry it into the next epoch rather than burning it. accountedAsset is unchanged: the
                    // liability only moves epochs. The owner cut travels with it and is taken on the epoch
                    // that actually pays out.
                    uint256 rolled = epochRewardAsset[closing];
                    if (rolled > 0) {
                        epochRewardAsset[closing] = 0;
                        epochRewardAsset[closing + 1] += rolled;
                        emit RewardRolledForward(closing, closing + 1, rolled);
                    }
                } else {
                    ownerCut = _takeOwnerEpochCut(closing);
                }
                epochTotalWeight[closing] = totalWeightCurrent;
                epochFinalized[closing] = true;
                emit EpochFinalized(closing, epochRewardAsset[closing], ownerCut, totalWeightCurrent);
                currentEpoch = closing + 1;
                totalWeightCurrent = 0;
            }
        }
        lastGlobalCheckpoint = until;
    }

    /// @notice Push global epoch accounting to the present. Permissionless so a backlog of unfinalized
    ///         epochs cannot build up unnoticed and make the catch-up loop expensive for the next staker.
    function advance() external nonReentrant {
        if (!bootstrapped) revert NotBootstrapped();
        _advanceGlobalTo(block.timestamp);
    }

    /// @notice Accrue your own stake-seconds up to now without staking, unstaking, or claiming.
    function checkpoint() external nonReentrant {
        if (!bootstrapped) revert NotBootstrapped();
        _checkpointUser(msg.sender);
    }

    function _takeOwnerEpochCut(uint256 epoch) internal returns (uint256 ownerCut) {
        uint256 pot = epochRewardAsset[epoch];
        if (pot == 0 || ownerRewardBps == 0) return 0;
        ownerCut = Math.mulDiv(pot, ownerRewardBps, DIVISOR);
        if (ownerCut == 0) return 0;
        epochRewardAsset[epoch] = pot - ownerCut;
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

        uint256 assetAdded;
        if (token == asset) {
            assetAdded = amount;
        } else if (token == address(weth)) {
            if (amount > type(uint128).max) revert ZeroAmount();
            assetAdded = _swapWethToAsset(uint128(amount));
        } else {
            revert Unauthorized();
        }

        _creditAsset(token, amount, assetAdded);
    }

    /// @notice Permissionless ASSET deposit into the current epoch pot. Anyone, any epoch, including before
    ///         `activate` (then it parks in epoch 0). Shares `nonReentrant` with `claim`, so a deposit cannot
    ///         resize the pot mid-payout.
    function boostReward(uint256 amount) external nonReentrant {
        if (!bootstrapped) revert NotBootstrapped();
        if (amount == 0) revert ZeroAmount();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _advanceGlobalTo(block.timestamp);
        _creditAsset(asset, amount, amount);
    }

    /// @dev Write `added` into the live epoch pot, or emit a zero-credit if the conversion produced nothing.
    function _creditAsset(address tokenIn, uint256 amountIn, uint256 added) internal {
        if (added == 0) {
            emit RewardNotified(tokenIn, amountIn, 0, currentEpoch);
            return;
        }
        epochRewardAsset[currentEpoch] += added;
        accountedAsset += added;
        _assertBacked();
        emit RewardNotified(tokenIn, amountIn, added, currentEpoch);
    }

    /// @dev Every epoch pot and owner-cut balance is drawn from one pooled ASSET balance, so an accounted
    ///      liability that was never funded would let one epoch's claimants spend another's ASSET. The ASSET
    ///      branch of `notifyReward` takes the strategy's `amount` on trust; this makes a fabricated or
    ///      replayed notification revert instead. Strategies wrap this in try/catch, so a harvest or
    ///      withdraw still settles; tokens already transferred here stay for rescue/retry.
    function _assertBacked() internal view {
        if (accountedAsset > IERC20(asset).balanceOf(address(this))) revert UnbackedReward();
    }

    function _swapWethToAsset(uint128 amount) internal returns (uint256 assetAdded) {
        uint256 minOut = IAutoStrategyBv4(strategy).minOutForSwap(address(weth), amount);
        if (minOut == 0) return 0;
        bool zeroForOne = address(weth) == poolKey.currency0;
        IERC20(weth).forceApprove(address(swapRouter), amount);
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
            assetAdded = out;
        } catch {
            IERC20(weth).forceApprove(address(swapRouter), 0);
            return 0;
        }
        IERC20(weth).forceApprove(address(swapRouter), 0);
    }

    function claim(uint256 epoch) external nonReentrant returns (uint256 assetOut) {
        _checkpointUser(msg.sender);
        if (epoch >= currentEpoch) revert EpochNotEnded();
        if (!epochFinalized[epoch]) revert EpochNotEnded();
        if (epochClaimed[msg.sender][epoch]) revert AlreadyClaimed();

        assetOut = _claimEpoch(msg.sender, epoch);
        if (assetOut == 0) revert NothingToClaim();
        IERC20(asset).safeTransfer(msg.sender, assetOut);
    }

    /// @notice Claim several finalized epochs in one transaction and receive one ASSET transfer. Epochs with
    ///         nothing to claim are skipped, so a long-held position can pass a whole range in one call
    ///         instead of one transaction per epoch. Reverts only when no listed epoch pays anything.
    function claimMany(uint256[] calldata epochs) external nonReentrant returns (uint256 assetOut) {
        _checkpointUser(msg.sender);
        for (uint256 i; i < epochs.length; ++i) {
            assetOut += _claimEpoch(msg.sender, epochs[i]);
        }
        if (assetOut == 0) revert NothingToClaim();
        IERC20(asset).safeTransfer(msg.sender, assetOut);
    }

    /// @dev Settles one epoch's claim accounting and returns the amount owed without transferring. Returns 0
    ///      instead of reverting when the epoch pays nothing so `claimMany` can walk a range; `claim` keeps
    ///      its explicit reverts by checking first.
    function _claimEpoch(address user, uint256 epoch) internal returns (uint256 assetOut) {
        if (!epochFinalized[epoch] || epochClaimed[user][epoch]) return 0;

        uint256 weight = userEpochWeight[user][epoch];
        uint256 totalW = epochTotalWeight[epoch];
        if (weight == 0 || totalW == 0) return 0;

        uint256 pot = epochRewardAsset[epoch];
        assetOut = Math.mulDiv(pot, weight, totalW);
        if (assetOut == 0) return 0;

        epochClaimed[user][epoch] = true;
        epochRewardAsset[epoch] = pot - assetOut;
        epochTotalWeight[epoch] = totalW - weight;
        userEpochWeight[user][epoch] = 0;
        accountedAsset -= assetOut;
        emit Claimed(user, epoch, assetOut);
    }

    function claimOwnerReward() external nonReentrant returns (uint256 amount) {
        amount = pendingOwnerReward[msg.sender];
        if (amount == 0) revert NothingToClaim();
        pendingOwnerReward[msg.sender] = 0;
        accountedAsset -= amount;
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, type(uint256).max, amount);
    }

    /// @notice Retry converting stranded WETH rewards into ASSET for the live epoch.
    function retryWethRewardSwap(uint256 amount) external nonReentrant onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint128).max) revert ZeroAmount();
        _advanceGlobalTo(block.timestamp);
        uint256 assetAdded = _swapWethToAsset(uint128(amount));
        if (assetAdded == 0) revert ZeroAmount();
        _creditAsset(address(weth), amount, assetAdded);
    }

    /// @notice Withdraw tokens that are not owed to anyone: ASSET above `accountedAsset`, LiquidShares above
    ///         `totalStaked`, and WETH whose reward swap can never be priced. Staker principal and unclaimed
    ///         reward pots are unreachable here.
    function rescueToken(address token, address to, uint256 amount) external nonReentrant onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _advanceGlobalTo(block.timestamp);

        uint256 reserved;
        if (token == asset) reserved = accountedAsset;
        else if (token == address(liquidShares)) reserved = totalStaked;

        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 surplus = bal > reserved ? bal - reserved : 0;
        if (amount > surplus) revert NothingToRescue();

        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }
}
