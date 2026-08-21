// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../v4/V4Deployments8453.sol";
import "../v4/libraries/TrailingFloorLib.sol";
import "./libraries/LiquidityLibraryV4.sol";
import "./interfaces/IPositionManagerV4.sol";
import "./interfaces/IPoolManagerV4.sol";
import "./interfaces/IAllowanceTransfer.sol";

import "./AutoStrategyManagerV2.sol";
import "./libraries/AutoBandLib.sol";
import "./interfaces/IAutoVault.sol";
import "./interfaces/IAutoVaultV2.sol";
import "./interfaces/IAutoStrategy.sol";
import "./interfaces/IAutoSwapRouter.sol";
import "./interfaces/IAutoOperatorRegistry.sol";

/// @title AutoStrategyV2
/// @notice AutoStrategy with dual-bucket reserve: `reserveBps` of deposits/fees stay idle (ASSET+WETH);
///         remint pulls deficit from reserve before swapping. Reserve is not re-seeded after remint.
contract AutoStrategyV2 is AutoStrategyManagerV2, ReentrancyGuard, IERC721Receiver, IAutoStrategy {
    using SafeERC20 for IERC20;
    using LiquidityLibraryV4 for LiquidityLibraryV4.PositionState;

    error E();

    address public immutable feeManager = 0x9f6e579117BeAd116E25CfeC43e319637DE0bCEe;
    address public immutable factory;
    IPositionManagerV4 public immutable positionManager;
    IPoolManagerV4 private immutable poolManager;
    IERC20 private immutable WETH;
    address private constant PERMIT2 = V4Deployments8453.PERMIT2;

    LiquidityLibraryV4.PositionState private liqPos;
    LiquidityLibraryV4.PoolKey private _poolKey;
    bytes private _hookData;
    IERC20 private _asset;
    IAutoSwapRouter public swapRouter;
    IAutoOperatorRegistry public operatorRegistry;

    address public vault;
    address public keeper;
    bool public watched;
    bool public bootstrapped;

    Mode internal stratMode;
    int24 public lastBandBaseTick;
    bool public hasBandBase;

    uint256 public lastHarvest;
    uint256 public lastRebalanceTime;
    uint256 public UniswapFeesCollected;
    uint256 private constant LIQUIDITY_DUST = 1_000_000_000_000;

    /// @notice LP-owned idle reserve (excluded from mint/increase/swap).
    uint256 public reservedAsset;
    uint256 public reservedWeth;

    constructor(address factory_) AutoStrategyManagerV2() {
        factory = factory_;
        WETH = IERC20(V4Deployments8453.WETH);
        positionManager = IPositionManagerV4(V4Deployments8453.POSITION_MANAGER);
        poolManager = IPoolManagerV4(V4Deployments8453.POOL_MANAGER);
        _initAutoDefaults();
    }

    function bootstrap(
        address owner_,
        address vault_,
        address swapRouter_,
        address operatorRegistry_,
        address keeper_,
        address asset_,
        LiquidityLibraryV4.PoolKey calldata key,
        bytes calldata hookData_
    ) external {
        if (bootstrapped) revert E();
        if (msg.sender != factory) revert E();
        if (
            owner_ == address(0) || vault_ == address(0) || swapRouter_ == address(0)
                || operatorRegistry_ == address(0) || keeper_ == address(0) || asset_ == address(0)
        ) revert E();
        if (
            !((key.currency0 == asset_ && key.currency1 == address(WETH))
                || (key.currency1 == asset_ && key.currency0 == address(WETH)))
        ) revert E();

        vault = vault_;
        swapRouter = IAutoSwapRouter(swapRouter_);
        operatorRegistry = IAutoOperatorRegistry(operatorRegistry_);
        keeper = keeper_;
        _asset = IERC20(asset_);
        _poolKey = key;
        _hookData = hookData_;
        if (key.tickSpacing > 0) tickSpacing = key.tickSpacing;
        _initAutoDefaults();
        if (key.tickSpacing > 0) tickSpacing = key.tickSpacing;
        stratMode = Mode.NORMAL;
        bootstrapped = true;
        _giveAllowances();
        _transferOwnership(owner_);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function ASSET() external view override returns (address) {
        return address(_asset);
    }

    function mode() external view override returns (uint8) {
        return uint8(uint256(stratMode));
    }

    function poolKey() external view override returns (LiquidityLibraryV4.PoolKey memory) {
        return _poolKey;
    }

    function hookData() external view override returns (bytes memory) {
        return _hookData;
    }

    function setWatched(bool status) external override {
        if (msg.sender != keeper && msg.sender != factory && msg.sender != owner()) revert E();
        watched = status;
    }

    function _onlyVault() internal view {
        if (msg.sender != vault) revert E();
    }

    function _onlyKeeper() internal view {
        address s = msg.sender;
        if (s != keeper && s != address(this) && !operatorRegistry.isOperator(s) && s != owner()) {
            revert E();
        }
    }

    function _readSlot0() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick) = LiquidityLibraryV4.getSlot0(poolManager, _poolKey);
    }

    function _inOuterRange() internal view returns (bool) {
        if (liqPos.positionId == 0) return false;
        (, int24 poolTick) = _readSlot0();
        return AutoBandLib.inBand(poolTick, liqPos.tickLower, liqPos.tickUpper);
    }

    function _inInnerComfort() internal view returns (bool) {
        if (liqPos.positionId == 0 || !hasBandBase) return false;
        (, int24 poolTick) = _readSlot0();
        (int24 lower, int24 upper) =
            AutoBandLib.innerTicks(lastBandBaseTick, _spacing(), innerBelowTicks, innerAboveTicks);
        return AutoBandLib.inBand(poolTick, lower, upper);
    }

    /// @dev Remint if OOR (outer) or tick left inner comfort band.
    function keeperCheck() external override nonReentrant returns (bool) {
        _onlyKeeper();
        if (stratMode == Mode.NEUTRAL) return false;
        if (liqPos.positionId == 0) {
            (uint256 a, uint256 w) = _getDeployableBalances();
            if (a <= LIQUIDITY_DUST && w <= LIQUIDITY_DUST) {
                if (reservedAsset <= LIQUIDITY_DUST && reservedWeth <= LIQUIDITY_DUST) return false;
            }
            _remintAtTarget();
            return liqPos.positionId != 0;
        }
        if (_inOuterRange() && _inInnerComfort()) return false;
        return _remintAtTarget();
    }

    function harvestBoolean(bool skipIncreaseLiquidity)
        external
        override
        nonReentrant
        returns (uint256)
    {
        _onlyKeeper();
        if (stratMode == Mode.NEUTRAL) return poolValue();
        if (liqPos.positionId == 0) return poolValue();
        (, , uint256 valueInWeth) = _collectAllFees(true);
        if (skipIncreaseLiquidity) return poolValue();
        if (minHarvestDelay > 0 && lastHarvest != 0 && block.timestamp - lastHarvest < minHarvestDelay) {
            return poolValue();
        }
        if (valueInWeth == 0) return poolValue();
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        _balanceTokens(assetBal, wethBal);
        _increaseLiquidityInternal();
        lastHarvest = block.timestamp;
        return poolValue();
    }

    function deposit(uint256 amount) external override nonReentrant {
        _onlyVault();
        if (amount == 0) revert E();
        if (stratMode == Mode.NEUTRAL) return;
        WETH.safeTransferFrom(msg.sender, address(this), amount);
        _deposit();
    }

    function ingestAndDeploy() external override nonReentrant {
        _onlyVault();
        if (stratMode == Mode.NEUTRAL) return;
        _deposit();
    }

    function withdraw(
        uint256 userShares,
        address receiver,
        WithdrawToken outToken
    ) external override nonReentrant {
        _onlyVault();
        if (receiver == address(0)) revert E();

        IAutoVault v = IAutoVault(vault);
        uint256 totalSupply_ = v.totalSupply();
        if (userShares == 0 || totalSupply_ == 0 || userShares > v.balanceOf(receiver)) revert E();

        if (userShares == totalSupply_) {
            if (liqPos.positionId != 0) {
                _decreaseAllLiquidity();
                liqPos.positionId = 0;
            }
            _setReserved(0, 0);
            _payWithdraw(
                receiver,
                outToken,
                _asset.balanceOf(address(this)),
                WETH.balanceOf(address(this))
            );
            return;
        }

        uint256 idleAssetBefore = _asset.balanceOf(address(this));
        uint256 idleWethBefore = WETH.balanceOf(address(this));
        if (liqPos.positionId != 0) {
            uint256 poolVal = _poolValueOnly();
            if (poolVal > 0) {
                uint256 amountFromPool = Math.mulDiv(poolVal, userShares, totalSupply_);
                if (amountFromPool > 0) _decreaseLiquidity(amountFromPool);
            }
        }
        uint256 assetAfter = _asset.balanceOf(address(this));
        uint256 wethAfter = WETH.balanceOf(address(this));
        uint256 totalUserAsset =
            (assetAfter > idleAssetBefore ? assetAfter - idleAssetBefore : 0)
                + Math.mulDiv(idleAssetBefore, userShares, totalSupply_);
        uint256 totalUserWeth =
            (wethAfter > idleWethBefore ? wethAfter - idleWethBefore : 0)
                + Math.mulDiv(idleWethBefore, userShares, totalSupply_);

        _consumeReservedShare(userShares, totalSupply_);
        _payWithdraw(receiver, outToken, totalUserAsset, totalUserWeth);
    }

    function _payWithdraw(
        address receiver,
        WithdrawToken outToken,
        uint256 totalUserAsset,
        uint256 totalUserWeth
    ) internal {
        // Reserved share already consumed in accounting; payout may use those tokens.
        uint256 assetFee = Math.mulDiv(totalUserAsset, withdrawalFeeBps, DIVISOR);
        uint256 wethFee = Math.mulDiv(totalUserWeth, withdrawalFeeBps, DIVISOR);
        totalUserAsset -= assetFee;
        totalUserWeth -= wethFee;
        if (assetFee > 0) _asset.safeTransfer(feeManager, assetFee);
        if (wethFee > 0) WETH.safeTransfer(feeManager, wethFee);

        if (outToken == WithdrawToken.WETH) {
            if (totalUserAsset > 0) {
                uint256 assetBal = _asset.balanceOf(address(this));
                uint256 toSwap = totalUserAsset > assetBal ? assetBal : totalUserAsset;
                uint256 assetBefore = _asset.balanceOf(address(this));
                uint256 wethBefore = WETH.balanceOf(address(this));
                _swap(_asset, toSwap);
                totalUserWeth += WETH.balanceOf(address(this)) - wethBefore;
                uint256 sold = assetBefore - _asset.balanceOf(address(this));
                uint256 unsold = toSwap > sold ? toSwap - sold : 0;
                if (unsold > 0) {
                    uint256 left = _asset.balanceOf(address(this));
                    if (unsold > left) unsold = left;
                    if (unsold > 0) _asset.safeTransfer(receiver, unsold);
                }
            }
            if (totalUserWeth > 0) {
                uint256 wethBal = WETH.balanceOf(address(this));
                if (totalUserWeth > wethBal) totalUserWeth = wethBal;
                if (totalUserWeth > 0) WETH.safeTransfer(receiver, totalUserWeth);
            }
        } else {
            if (totalUserWeth > 0) {
                uint256 wethBal = WETH.balanceOf(address(this));
                uint256 toSwap = totalUserWeth > wethBal ? wethBal : totalUserWeth;
                uint256 wethBefore = WETH.balanceOf(address(this));
                uint256 assetBefore = _asset.balanceOf(address(this));
                _swap(WETH, toSwap);
                totalUserAsset += _asset.balanceOf(address(this)) - assetBefore;
                uint256 sold = wethBefore - WETH.balanceOf(address(this));
                uint256 unsold = toSwap > sold ? toSwap - sold : 0;
                if (unsold > 0) {
                    uint256 left = WETH.balanceOf(address(this));
                    if (unsold > left) unsold = left;
                    if (unsold > 0) WETH.safeTransfer(receiver, unsold);
                }
            }
            if (totalUserAsset > 0) {
                uint256 assetBal = _asset.balanceOf(address(this));
                if (totalUserAsset > assetBal) totalUserAsset = assetBal;
                if (totalUserAsset > 0) _asset.safeTransfer(receiver, totalUserAsset);
            }
        }
    }

    function enterNeutralFromVault() external override {
        _onlyVault();
        stratMode = Mode.NEUTRAL;
    }

    function resumeNormalFromVault() external override {
        _onlyVault();
        if (stratMode != Mode.NEUTRAL) revert E();
        stratMode = Mode.NORMAL;
        lastRebalanceTime = block.timestamp;
    }

    /// @dev Drain LP, fund `targetAssetBps` deficit from reserve then swap, mint deployable only. Does not refill reserve.
    function _remintAtTarget() internal returns (bool) {
        if (liqPos.positionId != 0) {
            _decreaseAllLiquidity();
            liqPos.positionId = 0;
        }

        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        if (assetBal <= LIQUIDITY_DUST && wethBal <= LIQUIDITY_DUST) {
            if (reservedAsset <= LIQUIDITY_DUST && reservedWeth <= LIQUIDITY_DUST) return false;
            // Only reserve left — release into deployable so capital can remint into LP.
            _setReserved(0, 0);
            (assetBal, wethBal) = _getDeployableBalances();
        }

        _fundDeficitFromReserve(assetBal, wethBal);
        (assetBal, wethBal) = _getDeployableBalances();
        if (assetBal <= LIQUIDITY_DUST && wethBal <= LIQUIDITY_DUST) return false;
        _balanceTokens(assetBal, wethBal);
        _mintPosition();
        if (liqPos.positionId != 0) {
            lastRebalanceTime = block.timestamp;
            return true;
        }
        return false;
    }

    /// @dev Pull the short side from reserve toward `targetAssetBps` of current deployable value.
    function _fundDeficitFromReserve(uint256 assetBal, uint256 wethBal) internal {
        uint256 p = _spotPrice1e18();
        if (p == 0) return;
        uint256 wethAsTokens = Math.mulDiv(wethBal, p, 1e18);
        uint256 totalValue = assetBal + wethAsTokens;
        if (totalValue == 0) return;
        uint256 targetAsset = Math.mulDiv(totalValue, targetAssetBps, DIVISOR);

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

    function _deposit() internal {
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        if (assetBal == 0 && wethBal == 0) return;
        _balanceTokens(assetBal, wethBal);
        _peelReserveFromDeployable();
        (assetBal, wethBal) = _getDeployableBalances();
        if (assetBal == 0 && wethBal == 0) return;
        if (liqPos.positionId == 0) {
            _mintPosition();
        } else if (_inOuterRange()) {
            _increaseLiquidityInternal();
        } else {
            _remintAtTarget();
        }
    }

    /// @dev After target balance of deployable, credit `reserveBps` of each leg into reserved buckets.
    function _peelReserveFromDeployable() internal {
        if (reserveBps == 0) return;
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        uint256 ra = Math.mulDiv(assetBal, reserveBps, DIVISOR);
        uint256 rw = Math.mulDiv(wethBal, reserveBps, DIVISOR);
        if (ra == 0 && rw == 0) return;
        _setReserved(reservedAsset + ra, reservedWeth + rw);
    }

    function _mintPosition() internal {
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        if (assetBal == 0 && wethBal == 0) return;
        (, int24 currentTick) = _readSlot0();
        (int24 lower, int24 upper) =
            AutoBandLib.outerTicks(currentTick, _spacing(), rangeBelowTicks, rangeAboveTicks);
        (uint256 bal0, uint256 bal1) = _poolBalances(assetBal, wethBal);
        LiquidityLibraryV4.MintContext memory ctx = LiquidityLibraryV4.MintContext({
            posm: positionManager,
            poolManager: poolManager,
            poolKey: _poolKey,
            m: 1,
            slippageBps: slippageBps,
            dust: LIQUIDITY_DUST,
            hookData: _hookData
        });
        (uint256 newId, uint128 liq) = liqPos.mintNewPositionWithRange(ctx, bal0, bal1, lower, upper);
        if (newId != 0 && liq > 0) {
            lastBandBaseTick = TrailingFloorLib.alignDown(currentTick, _spacing());
            hasBandBase = true;
        }
    }

    function _poolBalances(uint256 assetBal, uint256 wethBal) internal view returns (uint256 bal0, uint256 bal1) {
        address p0 = _poolKey.currency0;
        bal0 = p0 == address(WETH) ? wethBal : assetBal;
        bal1 = p0 == address(WETH) ? assetBal : wethBal;
    }

    function _balanceTokens(uint256 assetBal, uint256 wethBal) internal {
        if (assetBal == 0 && wethBal == 0) return;
        uint256 p = _spotPrice1e18();
        if (p == 0) return;
        uint256 wethAsTokens = Math.mulDiv(wethBal, p, 1e18);
        uint256 totalValue = assetBal + wethAsTokens;
        if (totalValue == 0) return;
        uint256 target = Math.mulDiv(totalValue, targetAssetBps, DIVISOR);
        if (assetBal > target) {
            uint256 toSell = assetBal - target;
            if (toSell > 0) _swap(_asset, toSell);
        } else if (assetBal < target) {
            uint256 deficit = target - assetBal;
            uint256 wethToSell = Math.mulDiv(deficit, 1e18, p);
            if (wethToSell > wethBal) wethToSell = wethBal;
            if (wethToSell > 0) _swap(WETH, wethToSell);
        }
    }

    /// @dev Caps to deployable (`balance - reserved`). After withdraw consume, released reserve is spendable.
    function _swap(IERC20 tokenIn, uint256 amount) internal {
        if (amount == 0) return;
        uint256 bal = _spendable(tokenIn);
        if (amount > bal) amount = bal;
        if (amount <= LIQUIDITY_DUST) return;
        require(amount <= type(uint128).max, "amt");
        bool zeroForOne = address(tokenIn) == _poolKey.currency0;
        IERC20(_poolKey.currency0).forceApprove(address(swapRouter), 0);
        IERC20(_poolKey.currency1).forceApprove(address(swapRouter), 0);
        tokenIn.forceApprove(address(swapRouter), amount);
        swapRouter.swapExactInputSingleStrict(
            zeroForOne,
            uint128(amount),
            IAutoSwapRouter.AutoPoolKey({
                currency0: _poolKey.currency0,
                currency1: _poolKey.currency1,
                fee: _poolKey.fee,
                tickSpacing: _poolKey.tickSpacing,
                hooks: _poolKey.hooks
            }),
            _hookData
        );
    }

    function _collectAllFees(bool trackFees) internal returns (uint256 amount0, uint256 amount1, uint256 valueInWeth) {
        if (liqPos.positionId == 0) return (0, 0, 0);
        if (liqPos.getPositionLiquidity(positionManager) == 0) return (0, 0, 0);
        LiquidityLibraryV4.DecreaseContext memory dctx = LiquidityLibraryV4.DecreaseContext({
            posm: positionManager,
            poolManager: poolManager,
            poolKey: _poolKey,
            hookData: _hookData
        });
        (amount0, amount1) = LiquidityLibraryV4.collectAllFees(liqPos, dctx, address(this));
        if (amount0 == 0 && amount1 == 0) return (0, 0, 0);

        address p0 = _poolKey.currency0;
        address p1 = _poolKey.currency1;
        if (trackFees && protocolFeeBps > 0) {
            uint256 fee0 = Math.mulDiv(amount0, protocolFeeBps, DIVISOR);
            uint256 fee1 = Math.mulDiv(amount1, protocolFeeBps, DIVISOR);
            if (fee0 > 0) IERC20(p0).safeTransfer(feeManager, fee0);
            if (fee1 > 0) IERC20(p1).safeTransfer(feeManager, fee1);
            amount0 -= fee0;
            amount1 -= fee1;
        }

        // After protocol skim: reserveBps of each remaining leg → reserved buckets (rest stays deployable).
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
        if (feesAsset > 0 && p > 0) valueInWeth += Math.mulDiv(feesAsset, 1e18, p);
        if (trackFees) UniswapFeesCollected += valueInWeth;
    }

    function _decreaseAllLiquidity() internal {
        if (liqPos.positionId != 0) _collectAllFees(true);
        _decreaseLiquidityInternal(0, true);
    }

    function _decreaseLiquidity(uint256 amount) internal {
        uint256 liqToRemove = _calculateLiquidityToRemove(amount);
        if (liqToRemove == 0) return;
        _decreaseLiquidityInternal(uint128(liqToRemove), false);
    }

    function _decreaseLiquidityInternal(uint128 liquidityToRemove, bool removeAll) internal {
        if (liqPos.positionId == 0) return;
        LiquidityLibraryV4.DecreaseContext memory ctx = LiquidityLibraryV4.DecreaseContext({
            posm: positionManager,
            poolManager: poolManager,
            poolKey: _poolKey,
            hookData: _hookData
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

    function _increaseLiquidityInternal() internal returns (uint128 liqAdded) {
        if (liqPos.positionId == 0) return 0;
        // Library reads full ERC20 balances — park reserved tokens on the vault for the call.
        (uint256 parkedAsset, uint256 parkedWeth) = _parkReservedToVault();
        LiquidityLibraryV4.IncreaseContext memory ctx = LiquidityLibraryV4.IncreaseContext({
            posm: positionManager,
            poolManager: poolManager,
            poolKey: _poolKey,
            slippageBps: slippageBps,
            dust: LIQUIDITY_DUST,
            hookData: _hookData
        });
        liqAdded = liqPos.increaseLiquidityInternal(
            ctx, IERC20(_poolKey.currency0), IERC20(_poolKey.currency1)
        );
        _unparkReservedFromVault(parkedAsset, parkedWeth);
    }

    function _parkReservedToVault() internal returns (uint256 parkedAsset, uint256 parkedWeth) {
        parkedAsset = reservedAsset;
        parkedWeth = reservedWeth;
        if (parkedAsset > 0) {
            uint256 bal = _asset.balanceOf(address(this));
            if (parkedAsset > bal) parkedAsset = bal;
            if (parkedAsset > 0) _asset.safeTransfer(vault, parkedAsset);
        }
        if (parkedWeth > 0) {
            uint256 bal = WETH.balanceOf(address(this));
            if (parkedWeth > bal) parkedWeth = bal;
            if (parkedWeth > 0) WETH.safeTransfer(vault, parkedWeth);
        }
    }

    function _unparkReservedFromVault(uint256 parkedAsset, uint256 parkedWeth) internal {
        if (parkedAsset > 0) IAutoVaultV2(vault).strategyPull(address(_asset), parkedAsset);
        if (parkedWeth > 0) IAutoVaultV2(vault).strategyPull(address(WETH), parkedWeth);
    }

    function _calculateLiquidityToRemove(uint256 amountWeth) internal view returns (uint256) {
        if (liqPos.positionId == 0) return 0;
        uint128 liquidity = liqPos.getPositionLiquidity(positionManager);
        if (liquidity == 0 || amountWeth == 0) return 0;

        (uint160 sqrtP,) = _readSlot0();
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) =
            LiquidityLibraryV4.getSqrtRatios(liqPos.tickLower, liqPos.tickUpper);
        (uint256 amount0, uint256 amount1) =
            LiquidityLibraryV4.getAmountsForLiquidity(sqrtP, sqrtLowerX96, sqrtUpperX96, liquidity);

        address p0 = _poolKey.currency0;
        (uint256 assetAmt, uint256 wethAmt) =
            p0 == address(WETH) ? (amount1, amount0) : (amount0, amount1);
        uint256 p = _spotPrice1e18();
        uint256 assetAsWeth = p != 0 ? Math.mulDiv(assetAmt, 1e18, p) : 0;
        uint256 totalValue = wethAmt + assetAsWeth;
        if (totalValue == 0) return 0;

        uint256 proportion = Math.mulDiv(amountWeth, 1e18, totalValue);
        if (proportion > 1e18) proportion = 1e18;
        uint256 targetTokenAmt = Math.mulDiv(assetAmt, proportion, 1e18);
        uint256 targetWethAmt = Math.mulDiv(wethAmt, proportion, 1e18);
        (uint256 bal0, uint256 bal1) =
            p0 == address(WETH) ? (targetWethAmt, targetTokenAmt) : (targetTokenAmt, targetWethAmt);
        uint128 liqNeeded =
            LiquidityLibraryV4.getLiquidityForAmounts(sqrtP, sqrtLowerX96, sqrtUpperX96, bal0, bal1);
        if (liqNeeded > liquidity) return liquidity;
        return liqNeeded;
    }

    function _getTokenBalances() internal view returns (uint256 assetBal, uint256 wethBal) {
        assetBal = _asset.balanceOf(address(this));
        wethBal = WETH.balanceOf(address(this));
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
        } else if (address(token) == address(_asset)) {
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

    function _spotPrice1e18() internal view returns (uint256) {
        (uint160 sqrtP,) = _readSlot0();
        uint256 price = Math.mulDiv(uint256(sqrtP), uint256(sqrtP), (uint256(1) << 192) / 1e18);
        if (_poolKey.currency0 == address(WETH)) return price;
        if (price == 0) return 0;
        return Math.mulDiv(1e18, 1e18, price);
    }

    function _poolValueOnly() internal view returns (uint256) {
        (uint256 assetInPool, uint256 wethInPool) = balanceOfPool();
        uint256 price = _spotPrice1e18();
        uint256 assetAsWeth = price != 0 ? Math.mulDiv(assetInPool, 1e18, price) : 0;
        return wethInPool + assetAsWeth;
    }

    function poolValue() public view override returns (uint256) {
        return _poolValueOnly() + balanceOfIdle();
    }

    function balance() external view override returns (uint256) {
        return poolValue();
    }

    /// @notice Idle capital including reserved buckets (NAV).
    function balanceOfIdle() public view returns (uint256) {
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        uint256 p = _spotPrice1e18();
        uint256 assetAsWeth = p != 0 ? Math.mulDiv(assetBal, 1e18, p) : 0;
        return wethBal + assetAsWeth;
    }

    function balanceOfPool() public view returns (uint256 assetAmt, uint256 wethAmt) {
        if (liqPos.positionId == 0) return (0, 0);
        uint128 liquidity = liqPos.getPositionLiquidity(positionManager);
        (uint160 sqrtPriceX96,) = _readSlot0();
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) =
            LiquidityLibraryV4.getSqrtRatios(liqPos.tickLower, liqPos.tickUpper);
        (uint256 amount0, uint256 amount1) =
            LiquidityLibraryV4.getAmountsForLiquidity(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, liquidity);
        return _poolKey.currency0 == address(WETH) ? (amount1, amount0) : (amount0, amount1);
    }

    function _giveAllowances() internal {
        _asset.forceApprove(address(positionManager), type(uint256).max);
        WETH.forceApprove(address(positionManager), type(uint256).max);
        _asset.forceApprove(PERMIT2, type(uint256).max);
        WETH.forceApprove(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(address(_asset), address(positionManager), type(uint160).max, type(uint48).max);
        IAllowanceTransfer(PERMIT2).approve(address(WETH), address(positionManager), type(uint160).max, type(uint48).max);
    }
}
