// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IPositionManagerV4.sol";
import "./interfaces/IPoolManagerV4.sol";
import "./StrategyManagerV5.sol";
import {IV4StrategySwapRouterStrict} from "./interfaces/IFloatV4StrategySwapRouter.sol";
import "./interfaces/IOutOfRangeStrategyV4.sol";
import "./interfaces/IFloatStrategyV4.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./libraries/TrailingFloorLib.sol";
import "./libraries/LiquidityLibraryV5.sol"; 
import "./interfaces/IAllowanceTransfer.sol";

/// @title FloatStrategyV5
/// @notice Float v4 strategy with Auto-style dual-bucket ERC20 reserve + changeAsset-safe clear.
/// @dev STABLE is WETH-park (no LP) — unlike V2 STABLE (USDC/WETH LP). Rotate remint peels reserveBps like V2.
contract FloatStrategyV5 is IFloatStrategyV4, StrategyManagerV5, ReentrancyGuard, IERC721Receiver, IOutOfRangeStrategyV4 {
    error E();
    error PositionExists();
    error MustBeNeutral();

    /// @notice Emitted when the strategy rotates ASSET (or exits to WETH/STABLE).
    event AssetChanged(
        address indexed oldAsset,
        address indexed newAsset,
        uint256 poolValue,
        uint64 timestamp
    );

    using SafeERC20 for IERC20;
    using LiquidityLibraryV5 for LiquidityLibraryV5.PositionState;
    address public immutable feeManager;
    IPositionManagerV4 public immutable positionManager;
    LiquidityLibraryV5.PositionState private liqPos;
    IPoolManagerV4 private poolManager;
    LiquidityLibraryV5.PoolKey public poolKey;
    IV4StrategySwapRouterStrict private swapRouterV4;
    address public managerAddress;
    IERC20 public ASSET;
    IERC20 private WETH;
    address private vaultAddr;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private demeterAddr;
    address private keeperStratAddr;
    bool public harvestOnDeposit = true;
    uint256 public lastOffensiveTime;
    uint256 public prevOffensiveTime;
    uint256 public lastHarvest;
    uint256 public PrevHarvestTime;
    uint256 public baseTokenShareBps = 5_000;
    uint256 public UniswapFeesCollected;
    uint256 public lastUniswapFeeTotal;
    /// @notice LP-owned idle reserve (excluded from mint/increase/swap).
    uint256 public reservedAsset;
    uint256 public reservedWeth;
    uint256 private constant LIQUIDITY_DUST = 1_000_000_000_000;
    enum Mode { NORMAL, DEFENSIVE, OFFENSIVE, NEUTRAL, STABLE }
    Mode internal stratMode;
    uint256 public lastRebalanceTime;
    uint256 public defensiveEnteredAt;
    uint256 public consecutiveOffensiveCount;
    uint256 public prevConsecutiveOffensiveCount;
    function _lpModeActive() internal view returns (bool) {
        return stratMode == Mode.NORMAL || stratMode == Mode.OFFENSIVE;
    }
    function _idlePaused() internal view returns (bool) {
        Mode m = stratMode;
        return m == Mode.DEFENSIVE || m == Mode.NEUTRAL || m == Mode.STABLE;
    }
    function tickRange() external view returns (int24 lower, int24 upper) {
        return (liqPos.tickLower, liqPos.tickUpper);
    }
    function mode() external view override returns (uint8) {
        return uint8(uint256(stratMode));
    }
    function _readSlot0() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        if (liqPos.positionId == 0) {
            (sqrtPriceX96, tick) = LiquidityLibraryV5.getSlot0Safe(poolManager, poolKey);
        } else {
            (sqrtPriceX96, tick) = LiquidityLibraryV5.getSlot0(poolManager, poolKey);
        }
    }
    function _poolHookData() internal view returns (bytes memory) {
        (, bytes memory hookData) = swapRouterV4.getV4PoolConfig(address(ASSET));
        return hookData;
    }
    modifier onlyAuthorized() {
        address s = _msgSender();
        if (s != vaultAddr && s != demeterAddr && s != keeperStratAddr && s != managerAddress && s != owner()) revert E();
        _;
    }
    constructor(
        address weth_,
        address positionManager_,
        address poolManager_,
        address _assetAddr,
        uint24 _poolFeePips,
        int24 _tickSpacing,
        address _hooks,
        address _managerAddr,
        address _swapRouterAddr,
        address _vaultAddr,
        address _demeterAddr,
        address _keeperStrategyAddr,
        address _feeManagerAddr
    ) StrategyManagerV5() {
        if (weth_ == address(0) || positionManager_ == address(0) || poolManager_ == address(0)) revert E();
        WETH = IERC20(weth_);
        positionManager = IPositionManagerV4(positionManager_);
        poolManager = IPoolManagerV4(poolManager_);
        managerAddress = _managerAddr;
        vaultAddr = _vaultAddr;
        demeterAddr = _demeterAddr;
        keeperStratAddr = _keeperStrategyAddr;
        feeManager = _feeManagerAddr;
        swapRouterV4 = IV4StrategySwapRouterStrict(_swapRouterAddr);
        ASSET = IERC20(_assetAddr);
        _setPoolKey(LiquidityLibraryV5.PoolKey({
            currency0: _assetAddr < weth_ ? _assetAddr : weth_,
            currency1: _assetAddr < weth_ ? weth_ : _assetAddr,
            fee: _poolFeePips,
            tickSpacing: _tickSpacing,
            hooks: _hooks
        }));
        _giveAllowances();
        lastRebalanceTime = block.timestamp;
    }
    function _setPoolKey(LiquidityLibraryV5.PoolKey memory key) internal {
        poolKey = key;
        poolFeePips = key.fee;
        tickSpacing = key.tickSpacing;
    }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
    function beforeDeposit() external override onlyAuthorized {
        if (harvestOnDeposit) {
            try this.harvestBoolean(true) returns (uint256) {
            } catch {
            }
        }
    }
    function deposit(uint256 amount) external override onlyAuthorized nonReentrant {
        if (amount == 0) revert E();
        // STABLE: accept WETH from vault but do not mint; call `changeAsset(newToken)` to deploy LP.
        if (stratMode == Mode.STABLE) {
            return;
        }
        if (liqPos.positionId == 0) {
            if (_idlePaused()) {
                (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
                if (assetBal > 0 || wethBal > 0) {
                    _balanceTokens(assetBal, wethBal);
                }
                return;
            }
            _deposit();
            return;
        }
        if (_lpModeActive() && _inRange()) {
            _deposit();
            return;
        }
        if (_lpModeActive() && !_inRange() && liqPos.positionId != 0) {
            _deposit();
            return;
        }
        if (stratMode == Mode.DEFENSIVE || stratMode == Mode.NEUTRAL) {
            (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
            if (assetBal > 0 || wethBal > 0) {
                _balanceTokens(assetBal, wethBal);
            }
            return;
        }
    }
    function withdraw(uint256 userShares, uint256 totalSupply_, address receiver) external override onlyAuthorized nonReentrant {
        if (userShares == 0) revert E();
        if (totalSupply_ == 0) revert E();
        if (receiver == address(0)) revert E();
        uint256 totalUserWeth;
        uint256 wethFee;
        if (stratMode == Mode.STABLE) {
            uint256 idleWethBefore = WETH.balanceOf(address(this));
            if (liqPos.positionId != 0) {
                uint256 poolVal = poolValue();
                if (poolVal > 0) {
                    uint256 amountFromPool = Math.mulDiv(poolVal, userShares, totalSupply_);
                    if (amountFromPool > 0) {
                        _decreaseLiquidity(amountFromPool);
                    }
                }
            }
            uint256 wethAfter = WETH.balanceOf(address(this));
            uint256 wethFromPool = wethAfter > idleWethBefore ? wethAfter - idleWethBefore : 0;
            totalUserWeth = wethFromPool + Math.mulDiv(idleWethBefore, userShares, totalSupply_);
            _consumeReservedShare(userShares, totalSupply_);
            wethFee = Math.mulDiv(totalUserWeth, withdrawalFeeBps, DIVISOR);
            totalUserWeth -= wethFee;
            if (wethFee > 0) {
                WETH.safeTransfer(owner(), wethFee);
            }
            WETH.safeTransfer(receiver, totalUserWeth);
            return;
        }
        uint256 totalUserAsset;
        {
            uint256 idleAssetBefore = ASSET.balanceOf(address(this));
            uint256 idleWethBefore  = WETH.balanceOf(address(this));
            if (liqPos.positionId != 0) {
                uint256 poolVal = poolValue();
                if (poolVal > 0) {
                    uint256 amountFromPool = Math.mulDiv(poolVal, userShares, totalSupply_);
                    if (amountFromPool > 0) {
                        _decreaseLiquidity(amountFromPool);
                    }
                }
            }
            uint256 assetAfter = ASSET.balanceOf(address(this));
            uint256 wethAfter  = WETH.balanceOf(address(this));
            uint256 assetFromPool = assetAfter > idleAssetBefore ? assetAfter - idleAssetBefore : 0;
            uint256 wethFromPool  = wethAfter  > idleWethBefore  ? wethAfter  - idleWethBefore  : 0;
            totalUserAsset = assetFromPool + Math.mulDiv(idleAssetBefore, userShares, totalSupply_);
            totalUserWeth  = wethFromPool + Math.mulDiv(idleWethBefore, userShares, totalSupply_);
        }
        _consumeReservedShare(userShares, totalSupply_);
        uint256 assetFee = Math.mulDiv(totalUserAsset, withdrawalFeeBps, DIVISOR);
        wethFee = Math.mulDiv(totalUserWeth, withdrawalFeeBps, DIVISOR);
        totalUserAsset -= assetFee;
        totalUserWeth -= wethFee;
        {
            uint256 wethBeforeSwap = WETH.balanceOf(address(this));
            _swap(ASSET, totalUserAsset);
            totalUserWeth += WETH.balanceOf(address(this)) - wethBeforeSwap;
        }
        if (assetFee > 0) {
            ASSET.safeTransfer(owner(), assetFee);
        }
        if (wethFee > 0) {
            WETH.safeTransfer(owner(), wethFee);
        }
        WETH.safeTransfer(receiver, totalUserWeth);
    }
    function harvestBoolean(bool skipIncreaseLiquidity) external nonReentrant returns (uint256 newAssets) {
        address s = _msgSender();
        if (s != address(this)) {
            if (s != vaultAddr && s != demeterAddr && s != keeperStratAddr && s != managerAddress && s != owner()) revert E();
        }
        _harvest(skipIncreaseLiquidity);
        return poolValue();
    }
    function _noteHarvestActivity() internal {
        PrevHarvestTime = lastHarvest;
        lastHarvest = block.timestamp;
    }
    function _handleOffensiveStale() internal returns (bool) {
        if (stratMode == Mode.OFFENSIVE
                && block.timestamp - lastOffensiveTime > offensiveStaleDuration
                && consecutiveOffensiveCount == prevConsecutiveOffensiveCount + 1) {
            _decreaseAllLiquidity();
            liqPos.positionId = 0;
            stratMode = Mode.NORMAL;
            baseTokenShareBps = targetAssetBps != 0 ? targetAssetBps : 5000;
            consecutiveOffensiveCount = 0;
            prevConsecutiveOffensiveCount = 0;
            (uint256 staleAssetBal, uint256 staleWethBal) = _getDeployableBalances();
            _fundDeficitFromReserve(staleAssetBal, staleWethBal);
            (staleAssetBal, staleWethBal) = _getDeployableBalances();
            _balanceTokens(staleAssetBal, staleWethBal);
            _mintAsymmetricPosition();
            _noteHarvestActivity();
            return true;
        }
        return false;
    }
    function _harvest(bool skipIncreaseLiquidity) internal  {
        if (_idlePaused()) {
            if (liqPos.positionId != 0) {
                _collectAllFees(true);
            }
            return;
        }
        if (liqPos.positionId == 0) {
            return;
        }
        (, , uint256 valueInWeth) = _collectAllFees(true);
        if (skipIncreaseLiquidity || !_lpModeActive()) {
            return;
        }
        if (minHarvestDelay > 0 && lastHarvest != 0 && block.timestamp - lastHarvest < minHarvestDelay) {
            return;
        }
        if (valueInWeth == 0) {
            return;
        }
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        _balanceTokens(assetBal, wethBal);
        uint128 added = _increaseLiquidityInternal();
        if (added > 0) {
            _noteHarvestActivity();
        }
    }
    function _inRange() internal view returns (bool) {
        if (liqPos.positionId == 0) return false;
        (, int24 poolTick) = _readSlot0();
        (int24 posTickLower, int24 posTickUpper) = (liqPos.tickLower, liqPos.tickUpper);
        return poolTick >= posTickLower && poolTick < posTickUpper;
    }
    function readInRange() external view override returns (bool) {
        return _inRange();
    }
    function keeperCheck() external nonReentrant returns (bool) {
        if (stratMode == Mode.STABLE || stratMode == Mode.NEUTRAL) return false;
        if (_handleOffensiveStale()) return true;
        if (liqPos.positionId == 0) {
            return _handleIdleNoPosition();
        }
        if (_inRange()) return true;
        return _handleOutOfRange();
    }

    /// @dev Idle capital with no LP — vault strategies enter DEFENSIVE for operator `changeAsset`.
    ///      Tick-based offensive/defensive runs only in `_handleOutOfRange` after an active drain.
    ///      (UFloat idle re-evaluates the last band; vault depositors should not auto-remint from stale ticks.)
    function _handleIdleNoPosition() internal returns (bool) {
        if (stratMode != Mode.NORMAL && stratMode != Mode.OFFENSIVE) return false;
        if (liqPos.tickLower == 0 && liqPos.tickUpper == 0) return false;
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        if (assetBal <= LIQUIDITY_DUST && wethBal <= LIQUIDITY_DUST) {
            if (reservedAsset <= LIQUIDITY_DUST && reservedWeth <= LIQUIDITY_DUST) return false;
        }
        _enterDefensive();
        return true;
    }

    /// @dev Raw OOR side vs last LP band (Uniswap tick space).
    function _oorExitSide() internal view returns (bool exitedAbove, bool exitedBelow) {
        (int24 lower, int24 upper) = (liqPos.tickLower, liqPos.tickUpper);
        if (lower == 0 && upper == 0) return (false, false);
        (, int24 poolTick) = _readSlot0();
        exitedAbove = poolTick >= upper;
        exitedBelow = poolTick < lower;
    }

    /// @dev Maps OOR exit side to asset strength using WETH as numéraire and stored pool token order.
    function _assetStrengthAfterOor() internal view returns (bool assetStrong, bool assetWeak) {
        (bool exitedAbove, bool exitedBelow) = _oorExitSide();
        address weth = address(WETH);
        if (poolKey.currency0 == weth) {
            assetStrong = exitedBelow;
            assetWeak = exitedAbove;
        } else if (poolKey.currency1 == weth) {
            assetStrong = exitedAbove;
            assetWeak = exitedBelow;
        }
    }

    function _handleOffensiveDefensiveOor() internal returns (bool) {
        (bool assetStrong, bool assetWeak) = _assetStrengthAfterOor();
        if (assetStrong) {
            _enterOffensive();
            return liqPos.positionId != 0;
        }
        if (assetWeak) {
            _enterDefensive();
            return true;
        }
        return _remintAtTarget();
    }

    function _remintAtTarget() internal returns (bool) {
        stratMode = Mode.NORMAL;
        consecutiveOffensiveCount = 0;
        prevConsecutiveOffensiveCount = 0;
        baseTokenShareBps = targetAssetBps != 0 ? targetAssetBps : 5000;
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        if (assetBal <= LIQUIDITY_DUST && wethBal <= LIQUIDITY_DUST) {
            if (reservedAsset <= LIQUIDITY_DUST && reservedWeth <= LIQUIDITY_DUST) return false;
            _setReserved(0, 0);
            (assetBal, wethBal) = _getDeployableBalances();
        }
        _fundDeficitFromReserve(assetBal, wethBal);
        (assetBal, wethBal) = _getDeployableBalances();
        if (assetBal <= LIQUIDITY_DUST && wethBal <= LIQUIDITY_DUST) return false;
        _balanceTokens(assetBal, wethBal);
        _mintAsymmetricPosition();
        if (liqPos.positionId != 0) {
            _noteHarvestActivity();
            lastRebalanceTime = block.timestamp;
        }
        return liqPos.positionId != 0;
    }

    function _handleOutOfRange() internal returns (bool) {
        if (liqPos.positionId == 0) return false;
        uint128 remainingLiq = _drainPositionLiquidity(6);
        if (remainingLiq != 0) return true;
        liqPos.positionId = 0;
        return _handleOffensiveDefensiveOor();
    }
    function _enterDefensive() internal {
        if (liqPos.positionId != 0) revert PositionExists();
        consecutiveOffensiveCount = 0;
        defensiveEnteredAt = block.timestamp;
        stratMode = Mode.DEFENSIVE;
    }

    function _enterOffensive() internal {
        if (liqPos.positionId != 0) revert PositionExists();
        prevOffensiveTime = lastOffensiveTime;
        lastOffensiveTime = block.timestamp;
        prevConsecutiveOffensiveCount = consecutiveOffensiveCount;
        consecutiveOffensiveCount++;
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        _fundDeficitFromReserve(assetBal, wethBal);
        (assetBal, wethBal) = _getDeployableBalances();
        uint256 p = _spotPrice1e18();
        uint256 totalValue = assetBal + (p == 0 ? 0 : Math.mulDiv(wethBal, p, 1e18));
        if (assetBal == 0 && wethBal == 0 || p == 0 || totalValue == 0) {
            _offensiveFailedFallback();
            return;
        }
        stratMode = Mode.OFFENSIVE;
        _balanceTokens(assetBal, wethBal);
        _mintAsymmetricPosition();
        if (liqPos.positionId != 0) {
            baseTokenShareBps = _assetTargetBps();
            defensiveEnteredAt = 0;
            lastRebalanceTime = block.timestamp;
        } else {
            _offensiveFailedFallback();
        }
    }

    /// @dev Vault LP: remint at target on failed offensive mint rather than idle DEFENSIVE.
    function _offensiveFailedFallback() internal {
        _remintAtTarget();
    }

    function _assetTargetBps() internal view returns (uint256) {
        if (stratMode == Mode.OFFENSIVE && consecutiveOffensiveCount >= minFloorTickCount) {
            if (offensiveAssetBps != 0) return offensiveAssetBps;
        }
        if (targetAssetBps != 0) return targetAssetBps;
        return 5000;
    }

    /// @dev After `minFloorTickCount` OFFENSIVE re-mints, tighten below-range by `ratchetNumerator/ratchetDenominator` per step.
    function _effectiveRangeBelowTicks() internal view returns (uint256) {
        uint256 base = rangeBelowTicks;
        if (base == 0 || base >= 10_000) base = 400;
        if (consecutiveOffensiveCount < minFloorTickCount) {
            return TrailingFloorLib.alignTicksDownToSpacing(base, poolKey.tickSpacing);
        }

        uint256 count = consecutiveOffensiveCount;
        if (count > maxOffensiveRatchetCount) count = maxOffensiveRatchetCount;
        uint256 steps = count - minFloorTickCount + 1;
        uint256 effective = base;
        uint256 floorTicks = minRangeBelowTicks != 0 ? minRangeBelowTicks : 200;
        uint256 num = ratchetNumerator != 0 ? ratchetNumerator : 1;
        uint256 den = ratchetDenominator != 0 ? ratchetDenominator : 4;
        for (uint256 i = 0; i < steps; i++) {
            effective = effective * num / den;
            if (effective < floorTicks) {
                return TrailingFloorLib.alignTicksDownToSpacing(floorTicks, poolKey.tickSpacing);
            }
        }
        return TrailingFloorLib.alignTicksDownToSpacing(effective, poolKey.tickSpacing);
    }

    /// @dev Exact tick distances on the pool spacing grid (no silent rounding).
    function _asymmetricTicks(int24 currentTick) internal view returns (int24 lower, int24 upper) {
        uint256 belowTicks = _effectiveRangeBelowTicks();
        uint256 aboveTicks = rangeAboveTicks;
        if (aboveTicks == 0 || aboveTicks >= 10_000) aboveTicks = 600;
        return TrailingFloorLib.asymmetricSpacedTicks(currentTick, poolKey.tickSpacing, belowTicks, aboveTicks);
    }

    function _poolBalances(uint256 assetBal, uint256 wethBal) internal view returns (uint256 bal0, uint256 bal1) {
        address p0 = poolKey.currency0;
        bal0 = p0 == address(WETH) ? wethBal : assetBal;
        bal1 = p0 == address(WETH) ? assetBal : wethBal;
    }

    function _mintAsymmetricPosition() internal {
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        if (assetBal == 0 && wethBal == 0) return;
        (, int24 currentTick) = _readSlot0();
        (int24 lower, int24 upper) = _asymmetricTicks(currentTick);
        (uint256 bal0, uint256 bal1) = _poolBalances(assetBal, wethBal);
        LiquidityLibraryV5.MintContext memory ctx = LiquidityLibraryV5.MintContext({
            posm: positionManager,
            poolManager: poolManager,
            poolKey: poolKey,
            m: 1,
            slippageBps: slippageBps,
            dust: LIQUIDITY_DUST,
            hookData: _poolHookData()
        });
        liqPos.mintNewPositionWithRange(ctx, bal0, bal1, lower, upper);
        _handleLeftoverTokensWithLimit(0);
    }

    function _deposit() internal {
        if (stratMode == Mode.STABLE) {
            return;
        }
        if (liqPos.positionId != 0 && _idlePaused()) {
            return;
        }
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        if (assetBal == 0 && wethBal == 0) return;
        _balanceTokens(assetBal, wethBal);
        _peelReserveFromDeployable();
        (assetBal, wethBal) = _getDeployableBalances();
        if (assetBal == 0 && wethBal == 0) return;
        if (liqPos.positionId == 0) {
            _mintAsymmetricPosition();
        } else {
            _increaseLiquidityInternal();
            _handleLeftoverTokensWithLimit(0);
        }
    }
    function _collectAllFees(bool trackFees) internal returns (uint256 amount0, uint256 amount1, uint256 valueInWeth) {
        if (liqPos.positionId == 0) return (0, 0, 0);
        if (liqPos.getPositionLiquidity(positionManager) == 0) return (0, 0, 0);
        if (IERC721(address(positionManager)).ownerOf(liqPos.positionId) != address(this)) {
            revert E();
        }
        LiquidityLibraryV5.DecreaseContext memory dctx = LiquidityLibraryV5.DecreaseContext({
            posm: positionManager,
            poolManager: poolManager,
            poolKey: poolKey,
            hookData: _poolHookData()
        });
        (amount0, amount1) = LiquidityLibraryV5.collectAllFees(liqPos, dctx, address(this));
        valueInWeth = 0;
        if (amount0 == 0 && amount1 == 0) return (0, 0, 0);

        address p0 = poolKey.currency0;
        address p1 = poolKey.currency1;
        // Only skim on fee-only collects. Post-decrease collect can include principal — never skim that.
        if (trackFees && protocolFeeBps > 0) {
            uint256 fee0 = Math.mulDiv(amount0, protocolFeeBps, DIVISOR);
            uint256 fee1 = Math.mulDiv(amount1, protocolFeeBps, DIVISOR);
            if (fee0 > 0) IERC20(p0).safeTransfer(feeManager, fee0);
            if (fee1 > 0) IERC20(p1).safeTransfer(feeManager, fee1);
            amount0 -= fee0;
            amount1 -= fee1;
        }

        // After protocol skim: reserveBps of each remaining leg → reserved buckets.
        if (trackFees && reserveBps > 0) {
            uint256 r0 = Math.mulDiv(amount0, reserveBps, DIVISOR);
            uint256 r1 = Math.mulDiv(amount1, reserveBps, DIVISOR);
            if (r0 > 0 || r1 > 0) {
                if (p0 == address(WETH)) {
                    _setReserved(reservedAsset + r1, reservedWeth + r0);
                } else {
                    _setReserved(reservedAsset + r0, reservedWeth + r1);
                }
            }
        }

        uint256 feesWeth = p0 == address(WETH) ? amount0 : amount1;
        uint256 feesAsset = p0 == address(WETH) ? amount1 : amount0;
        uint256 p = _spotPrice1e18();
        valueInWeth = feesWeth;
        if (feesAsset > 0 && p > 0) {
            valueInWeth += Math.mulDiv(feesAsset, 1e18, p);
        }
        if (trackFees) {
            lastUniswapFeeTotal = UniswapFeesCollected;
            UniswapFeesCollected += valueInWeth;
        }
    }
    function _spotPrice1e18() internal view returns (uint256) {
        (uint160 sqrtP, ) = _readSlot0();
        address p0 = poolKey.currency0;
        uint256 price = Math.mulDiv(uint256(sqrtP), uint256(sqrtP), (uint256(1) << 192) / 1e18);
        if (p0 == address(WETH)) {
            return price;
        } else {
            if (price == 0) return 0;
            return Math.mulDiv(1e18, 1e18, price);
        }
    }
    function _getTokenBalances() internal view returns (uint256 assetBal, uint256 wethBal) {
        assetBal = ASSET.balanceOf(address(this));
        wethBal  = WETH.balanceOf(address(this));
    }
    function _getDeployableBalances() internal view returns (uint256 assetBal, uint256 wethBal) {
        (assetBal, wethBal) = _getTokenBalances();
        if (reservedAsset > 0) assetBal = assetBal > reservedAsset ? assetBal - reservedAsset : 0;
        if (reservedWeth > 0) wethBal = wethBal > reservedWeth ? wethBal - reservedWeth : 0;
    }
    function _spendable(IERC20 token) internal view returns (uint256 bal) {
        bal = token.balanceOf(address(this));
        if (address(token) == address(WETH)) {
            if (reservedWeth > 0) bal = bal > reservedWeth ? bal - reservedWeth : 0;
        } else if (address(token) == address(ASSET)) {
            if (reservedAsset > 0) bal = bal > reservedAsset ? bal - reservedAsset : 0;
        }
    }
    function _setReserved(uint256 newAsset, uint256 newWeth) internal {
        reservedAsset = newAsset;
        reservedWeth = newWeth;
    }
    function _consumeReservedShare(uint256 userShares, uint256 totalSupply_) internal {
        if (totalSupply_ == 0) return;
        if (reservedAsset == 0 && reservedWeth == 0) return;
        uint256 shareA = Math.mulDiv(reservedAsset, userShares, totalSupply_);
        uint256 shareW = Math.mulDiv(reservedWeth, userShares, totalSupply_);
        if (shareA == 0 && shareW == 0) return;
        if (shareA > reservedAsset) shareA = reservedAsset;
        if (shareW > reservedWeth) shareW = reservedWeth;
        _setReserved(reservedAsset - shareA, reservedWeth - shareW);
    }
    /// @dev After target balance of deployable, credit reserveBps of each leg into reserved buckets.
    function _peelReserveFromDeployable() internal {
        if (reserveBps == 0) return;
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        uint256 ra = Math.mulDiv(assetBal, reserveBps, DIVISOR);
        uint256 rw = Math.mulDiv(wethBal, reserveBps, DIVISOR);
        if (ra == 0 && rw == 0) return;
        _setReserved(reservedAsset + ra, reservedWeth + rw);
    }
    /// @dev Pull the short side from reserve toward target of current deployable value.
    function _fundDeficitFromReserve(uint256 assetBal, uint256 wethBal) internal {
        uint256 p = _spotPrice1e18();
        if (p == 0) return;
        uint256 wethAsTokens = Math.mulDiv(wethBal, p, 1e18);
        uint256 totalValue = assetBal + wethAsTokens;
        if (totalValue == 0) return;
        uint256 targetAsset = Math.mulDiv(totalValue, _assetTargetBps(), DIVISOR);
        if (assetBal > targetAsset) {
            uint256 surplusAsset = assetBal - targetAsset;
            uint256 deficitWeth = Math.mulDiv(surplusAsset, 1e18, p);
            if (deficitWeth > 0 && reservedWeth > 0) {
                uint256 pull = deficitWeth > reservedWeth ? reservedWeth : deficitWeth;
                _setReserved(reservedAsset, reservedWeth - pull);
            }
        } else if (assetBal < targetAsset) {
            uint256 deficitAsset = targetAsset - assetBal;
            if (deficitAsset > 0 && reservedAsset > 0) {
                uint256 pull = deficitAsset > reservedAsset ? reservedAsset : deficitAsset;
                _setReserved(reservedAsset - pull, reservedWeth);
            }
        }
    }
    /// @dev Swap reserved ASSET → WETH and credit reservedWeth before liquidating remaining old ASSET.
    function _clearReservedAssetToWeth() internal {
        uint256 pull = reservedAsset;
        if (pull == 0) return;
        uint256 bal = ASSET.balanceOf(address(this));
        if (pull > bal) pull = bal;
        if (pull == 0) {
            _setReserved(0, reservedWeth);
            return;
        }
        _setReserved(0, reservedWeth);
        uint256 wethBefore = WETH.balanceOf(address(this));
        if (pull > LIQUIDITY_DUST && pull <= type(uint128).max) {
            swapRouterV4.swapExactInputSingleStrict(
                address(ASSET),
                address(ASSET) == poolKey.currency0,
                uint128(pull)
            );
        }
        uint256 received = WETH.balanceOf(address(this)) - wethBefore;
        _setReserved(0, reservedWeth + received);
    }
    function _balanceTokens(uint256 assetBal, uint256 wethBal) internal {
        if (assetBal == 0 && wethBal == 0) return;
        uint256 p = _spotPrice1e18();
        if (p == 0) return;
        uint256 wethAsTokens = Math.mulDiv(wethBal, p, 1e18);
        uint256 totalValue   = assetBal + wethAsTokens;
        if (totalValue == 0) return;
        uint256 target = Math.mulDiv(totalValue, _assetTargetBps(), 10_000);
        if (assetBal > target) {
            uint256 toSell = assetBal - target;
            if (toSell > 0) _swap(ASSET, toSell);
        } else if (assetBal < target) {
            uint256 deficit    = target - assetBal;
            uint256 wethToSell = Math.mulDiv(deficit, 1e18, p);
            if (wethToSell > wethBal) wethToSell = wethBal;
            if (wethToSell > 0) _swap(WETH, wethToSell);
        }
    }
    function _increaseLiquidityInternal() internal returns (uint128 liqAdded) {
        if (liqPos.positionId == 0) return 0;
        address p0 = poolKey.currency0;
        address p1 = poolKey.currency1;
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        (uint256 amount0Max, uint256 amount1Max) = p0 == address(WETH)
            ? (wethBal, assetBal)
            : (assetBal, wethBal);
        LiquidityLibraryV5.IncreaseContext memory ctx = LiquidityLibraryV5.IncreaseContext({
            posm: positionManager,
            poolManager: poolManager,
            poolKey: poolKey,
            slippageBps: slippageBps,
            dust: LIQUIDITY_DUST,
            hookData: _poolHookData()
        });
        liqAdded = liqPos.increaseLiquidityInternal(ctx, IERC20(p0), IERC20(p1), amount0Max, amount1Max);
        return liqAdded;
    }
    function _decreaseAllLiquidity() internal {
        if (liqPos.positionId != 0) {
            _collectAllFees(true);
        }
        _decreaseLiquidityInternal(0, true);
    }
    function _drainPositionLiquidity(uint256 maxRounds) internal returns (uint128 remainingLiq) {
        if (liqPos.positionId == 0) return 0;
        for (uint256 i = 0; i < maxRounds; ++i) {
            _decreaseAllLiquidity();
            remainingLiq = liqPos.getPositionLiquidity(positionManager);
            if (remainingLiq == 0) return 0;
        }
    }
    function _decreaseLiquidity(uint256 amount) internal {
        uint256 liqToRemove = _calculateLiquidityToRemove(amount);
        if (liqToRemove == 0) return;
        _decreaseLiquidityInternal(uint128(liqToRemove), false);
    }
    function _decreaseLiquidityInternal(uint128 liquidityToRemove, bool removeAll) internal {
        if (liqPos.positionId == 0) return;
        LiquidityLibraryV5.DecreaseContext memory ctx = LiquidityLibraryV5.DecreaseContext({
            posm: positionManager,
            poolManager: poolManager,
            poolKey: poolKey,
            hookData: _poolHookData()
        });
        if (removeAll) {
            liqPos.decreaseAllLiquidity(ctx);
            if (liqPos.getPositionLiquidity(positionManager) > 0) {
                liqPos.decreaseAllLiquidity(ctx);
            }
        } else {
            if (liquidityToRemove == 0) return;
            liqPos.decreaseLiquidityByAmount(ctx, liquidityToRemove);
        }
        _collectAllFees(false);
    }
    function _handleLeftoverTokensWithLimit(uint256 iter) internal {
        if (iter >= 1) return;
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        uint256 d = LIQUIDITY_DUST;
        if (assetBal <= d && wethBal <= d) return;
        _balanceTokens(assetBal, wethBal);
        if (liqPos.positionId != 0) {
            _increaseLiquidityInternal();
            _handleLeftoverTokensWithLimit(iter + 1);
        }
    }
    function _swap(IERC20 tokenIn, uint256 amount) internal {
        if (amount == 0) return;
        uint256 bal = _spendable(tokenIn);
        if (amount > bal) amount = bal;
        if (amount <= LIQUIDITY_DUST) return;
        if (address(tokenIn) != poolKey.currency0 && address(tokenIn) != poolKey.currency1) revert E();
        if (amount > type(uint128).max) revert E();
        swapRouterV4.swapExactInputSingleStrict(
            address(ASSET),
            address(tokenIn) == poolKey.currency0,
            uint128(amount)
        );
    }
    function poolValue() public view override returns (uint256) {
        (uint256 assetInPool, uint256 wethInPool) = balanceOfPool();
        uint256 price = _spotPrice1e18();
        uint256 assetAsWeth = price != 0 ? Math.mulDiv(assetInPool, 1e18, price) : 0;
        return wethInPool + assetAsWeth;
    }
    function balanceOfIdle() public view override returns (uint256) {
        if (stratMode == Mode.STABLE) {
            return WETH.balanceOf(address(this));
        }
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        uint256 p = _spotPrice1e18();
        uint256 assetAsWeth = p != 0 ? Math.mulDiv(assetBal, 1e18, p) : 0;
        return wethBal + assetAsWeth;
    }
    function balanceOfPool() public view override returns (uint256 assetAmt, uint256 wethAmt) {
        if (liqPos.positionId == 0) return (0, 0);
        uint128 liquidity = liqPos.getPositionLiquidity(positionManager);
        (uint160 sqrtPriceX96, ) = _readSlot0();
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = LiquidityLibraryV5.getSqrtRatios(liqPos.tickLower, liqPos.tickUpper);
        (uint256 amount0, uint256 amount1) = LiquidityLibraryV5.getAmountsForLiquidity(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, liquidity);
        address p0 = poolKey.currency0;
        return p0 == address(WETH) ? (amount1, amount0) : (amount0, amount1);
    }
    function totalLiquidity() external view override returns (uint128) { return liqPos.getPositionLiquidity(positionManager); }
    function _calculateLiquidityToRemove(uint256 amount) internal view returns (uint256) {
        if (liqPos.positionId == 0) return 0;
        (int24 _tickLower, int24 _tickUpper, uint128 liquidity) = (liqPos.tickLower, liqPos.tickUpper, LiquidityLibraryV5.getPositionLiquidity(liqPos, positionManager));
        (uint160 sqrtP, ) = _readSlot0();
        uint128 positionLiquidity = liqPos.getPositionLiquidity(positionManager);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = LiquidityLibraryV5.getSqrtRatios(_tickLower, _tickUpper);
        (uint256 amount0, uint256 amount1) = LiquidityLibraryV5.getAmountsForLiquidity(sqrtP, sqrtLowerX96, sqrtUpperX96, positionLiquidity);
        address p0 = poolKey.currency0;
        (uint256 assetAmt, uint256 wethAmt) = p0 == address(WETH) ? (amount1, amount0) : (amount0, amount1);
        uint256 p = _spotPrice1e18();
        uint256 assetAsWeth = p != 0 ? Math.mulDiv(assetAmt, 1e18, p) : 0;
        uint256 totalValue = wethAmt + assetAsWeth;
        if (totalValue == 0 || liquidity == 0) return 0;
        uint256 proportion = Math.mulDiv(amount, 1e18, totalValue);
        uint256 targetTokenAmt = Math.mulDiv(assetAmt, proportion, 1e18);
        uint256 targetWethAmt = Math.mulDiv(wethAmt,  proportion, 1e18);
        (uint256 bal0, uint256 bal1) = p0 == address(WETH) ? (targetWethAmt, targetTokenAmt) : (targetTokenAmt, targetWethAmt);
        uint128 liqNeeded = LiquidityLibraryV5.getLiquidityForAmounts(sqrtP, sqrtLowerX96, sqrtUpperX96, bal0, bal1);
        if (liqNeeded > liquidity) return liquidity;
        return liqNeeded;
    }
    function setGiveAllowances() external onlyAuthorized {
        _giveAllowances();
    }
    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyAuthorized {
        harvestOnDeposit = _harvestOnDeposit;
    }
    function getPositionId() external view override returns (uint256) {
        return liqPos.positionId;
    }
    function _approveTriple(IERC20 token, address router, address pm) private {
        token.forceApprove(router, type(uint256).max);
        token.forceApprove(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(address(token), pm, type(uint160).max, type(uint48).max);
    }
    function _giveAllowances() internal {
        address pm = address(positionManager);
        address router = address(swapRouterV4);
        if (address(ASSET) != address(0)) _approveTriple(ASSET, router, pm);
        _approveTriple(WETH, router, pm);
    }
    /// @notice Drain LP (if any) and remint current ASSET with current band params (`rangeBelowTicks` / `rangeAboveTicks`).
    function mintNewPosition() external onlyAuthorized {
        changeAsset(address(ASSET), poolKey);
    }

    function changeAsset(address _newAssetAddr, LiquidityLibraryV5.PoolKey memory key)
        public
        override
        onlyAuthorized
    {
        if (_newAssetAddr == address(0)) revert E();
        address oldAsset = address(ASSET);
        address w = address(WETH);
        if (_newAssetAddr == w) {
            // V5 STABLE = WETH park (no LP). Differs from V2 STABLE (USDC/WETH LP mint).
            consecutiveOffensiveCount = 0;
            _decreaseAllLiquidity();
            if (liqPos.positionId != 0 && liqPos.getPositionLiquidity(positionManager) == 0) {
                liqPos.positionId = 0;
            }
            if (oldAsset != w) {
                _clearReservedAssetToWeth();
                uint256 oldAssetBal = _spendable(ASSET);
                if (oldAssetBal > 0) _swap(ASSET, oldAssetBal);
            }
            // Keep ASSET as the prior token so poolKey / router config stay valid; holdings are WETH-only.
            // Clear reserve counters so parked WETH is fully available when leaving STABLE.
            _setReserved(0, 0);
            stratMode = Mode.STABLE;
            defensiveEnteredAt = block.timestamp;
            emit AssetChanged(oldAsset, _newAssetAddr, poolValue(), uint64(block.timestamp));
            return;
        }
        if (key.currency0 >= key.currency1) revert E();
        if (!((key.currency0 == _newAssetAddr && key.currency1 == w) || (key.currency1 == _newAssetAddr && key.currency0 == w))) revert E();
        consecutiveOffensiveCount = 0;
        _decreaseAllLiquidity();
        if (liqPos.positionId != 0 && liqPos.getPositionLiquidity(positionManager) == 0) {
            liqPos.positionId = 0;
        }
        if (oldAsset != w) {
            _clearReservedAssetToWeth();
            if (oldAsset != _newAssetAddr) {
                uint256 oldDeployable = _spendable(ASSET);
                if (oldDeployable > 0) _swap(ASSET, oldDeployable);
            }
        }
        ASSET = IERC20(_newAssetAddr);
        _setPoolKey(key);
        _giveAllowances();
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        stratMode = Mode.NORMAL;
        defensiveEnteredAt = 0;
        baseTokenShareBps = targetAssetBps != 0 ? targetAssetBps : 5000;
        // Leaving STABLE / NORMAL rotate (V2 parity): fund from reserve, balance, peel ~40%, mint ~60%.
        if (wethBal != 0 || assetBal != 0 || reservedAsset > 0 || reservedWeth > 0) {
            _fundDeficitFromReserve(assetBal, wethBal);
            (assetBal, wethBal) = _getDeployableBalances();
            if (assetBal != 0 || wethBal != 0) {
                _balanceTokens(assetBal, wethBal);
                _peelReserveFromDeployable();
                (assetBal, wethBal) = _getDeployableBalances();
                if (assetBal != 0 || wethBal != 0) {
                    _mintAsymmetricPosition();
                    if (liqPos.positionId != 0) {
                        lastRebalanceTime = block.timestamp;
                    }
                }
            }
        }
        emit AssetChanged(oldAsset, _newAssetAddr, poolValue(), uint64(block.timestamp));
    }
    function enterNeutralFromVault() external onlyAuthorized {
        stratMode = Mode.NEUTRAL;
        defensiveEnteredAt = block.timestamp;
        consecutiveOffensiveCount = 0;
    }
    function resumeNormalFromVault() external onlyAuthorized {
        if (stratMode != Mode.NEUTRAL) revert MustBeNeutral();
        stratMode = Mode.NORMAL;
        baseTokenShareBps = targetAssetBps != 0 ? targetAssetBps : 5000;
        defensiveEnteredAt = 0;
        lastRebalanceTime = block.timestamp;
    }

}

