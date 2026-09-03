// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./V3Deployments4663.sol";
import "./AutoStrategyManagerRhV3.sol";
import "./libraries/LiquidityLibraryV2.sol";
import "./libraries/AutoBandLib.sol";
import "./libraries/TrailingFloorLib.sol";
import "./libraries/TickMath.sol";
import "./interfaces/IAutoStrategyRhV3.sol";
import "./interfaces/IAutoSwapRouterRhV3.sol";
import "./interfaces/IAutoOperatorRegistryRhV3.sol";
import "./interfaces/IAutoVaultRhV3.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/IUniswapV3Factory.sol";
import "./interfaces/IUniswapV3PoolMinimal.sol";
import "./interfaces/IShareStakingRhV3.sol";

contract AutoStrategyRhV3 is AutoStrategyManagerRhV3, ReentrancyGuard, IERC721Receiver, IAutoStrategyRhV3 {
    using SafeERC20 for IERC20;
    using LiquidityLibraryV2 for LiquidityLibraryV2.PositionState;

    error E();

    address public immutable factory;
    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Factory public immutable v3Factory;
    IERC20 private immutable WETH;

    LiquidityLibraryV2.PositionState private liqPos;
    IERC20 private _asset;
    IAutoSwapRouterRhV3 public swapRouter;
    IAutoOperatorRegistryRhV3 public operatorRegistry;
    IUniswapV3PoolMinimal private _pool;

    address public vault;
    address public keeper;
    address private _feeManager;
    address private _shareStaking;
    uint24 public poolFee;
    bool public watched;
    bool private _bootstrapped;
    /// @notice After one factory ownership transfer (e.g. to ERC-6551), ownership cannot move again.
    bool public ownershipLocked;
    int24 public lastBandBaseTick;
    bool public hasBandBase;
    uint256 public lastHarvest;
    uint256 public lastRebalanceTime;
    uint256 public UniswapFeesCollected;
    uint256 public reservedAsset;
    uint256 public reservedWeth;
    uint256 private constant LIQUIDITY_DUST = 1_000_000_000_000;

    /// @notice Sets the factory and Rh (4663) Uniswap v3 immutables; package wiring happens in `bootstrap`.
    constructor(address factory_) AutoStrategyManagerRhV3() {
        factory = factory_;
        positionManager = INonfungiblePositionManager(V3Deployments4663.NPM);
        v3Factory = IUniswapV3Factory(V3Deployments4663.FACTORY);
        WETH = IERC20(V3Deployments4663.WETH);
        _initAutoDefaults();
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert E();
        _;
    }

    function bootstrap(
        address owner_,
        address vault_,
        address swapRouter_,
        address operatorRegistry_,
        address keeper_,
        address feeManager_,
        address shareStaking_,
        address asset_,
        uint24 poolFee_
    ) external onlyFactory {
        if (_bootstrapped) revert E();
        if (
            owner_ == address(0) || vault_ == address(0) || swapRouter_ == address(0) || operatorRegistry_ == address(0)
                || keeper_ == address(0) || feeManager_ == address(0) || shareStaking_ == address(0)
                || asset_ == address(0) || asset_ == address(WETH)
        ) revert E();
        address pool_ = v3Factory.getPool(asset_, address(WETH), poolFee_);
        if (pool_ == address(0)) revert E();

        vault = vault_;
        swapRouter = IAutoSwapRouterRhV3(swapRouter_);
        operatorRegistry = IAutoOperatorRegistryRhV3(operatorRegistry_);
        keeper = keeper_;
        _feeManager = feeManager_;
        _shareStaking = shareStaking_;
        _asset = IERC20(asset_);
        _pool = IUniswapV3PoolMinimal(pool_);
        poolFee = poolFee_;
        // Clones do not run constructors — init defaults here (same pattern as Base AutoStrategyV2).
        _initAutoDefaults();
        tickSpacing = _pool.tickSpacing();
        if (tickSpacing <= 0) revert E();
        _bootstrapped = true;
        _asset.forceApprove(address(positionManager), type(uint256).max);
        WETH.forceApprove(address(positionManager), type(uint256).max);
        _transferOwnership(owner_);
    }

    /// @notice One-shot factory ownership move (e.g. package → ERC-6551 TBA). Locks ownership afterward.
    function transferOwnershipFromFactory(address newOwner) external onlyFactory {
        if (newOwner == address(0)) revert E();
        if (ownershipLocked) revert E();
        _transferOwnership(newOwner);
        ownershipLocked = true;
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        if (ownershipLocked) revert E();
        super.transferOwnership(newOwner);
    }

    function renounceOwnership() public pure override {
        revert E();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function ASSET() external view override returns (address) {
        return address(_asset);
    }

    function pool() external view override returns (address) {
        return address(_pool);
    }

    function setWatched(bool status) external override {
        if (msg.sender != keeper && msg.sender != factory && msg.sender != owner()) revert E();
        watched = status;
    }

    function _stakingShareBpsEditable() internal view override returns (bool) {
        return ownershipLocked;
    }

    /// @dev Split protocol fee token amount: stakingShareBps → ShareStakingRhV3 (as epoch rewards), rest → feeManager.
    ///      ShareStakingRhV3 soft-fails ASSET→WETH swaps; try/catch here still protects harvest if notify reverts.
    function _routeProtocolFee(address token, uint256 amount) internal {
        if (amount == 0) return;
        uint256 toStaking = Math.mulDiv(amount, stakingShareBps, DIVISOR);
        uint256 toFeeManager = amount - toStaking;
        if (toStaking > 0 && _shareStaking != address(0)) {
            IERC20(token).safeTransfer(_shareStaking, toStaking);
            try IShareStakingRhV3(_shareStaking).notifyReward(token, toStaking) {}
            catch {
                // Tokens already in ShareStakingRhV3 (WETH credited or ASSET stranded for rescue/retry).
            }
        } else if (toStaking > 0) {
            toFeeManager += toStaking;
        }
        if (toFeeManager > 0) IERC20(token).safeTransfer(_feeManager, toFeeManager);
    }

    function _onlyVault() internal view {
        if (msg.sender != vault) revert E();
    }

    function _onlyKeeper() internal view {
        if (
            msg.sender != keeper && msg.sender != address(this) && !operatorRegistry.isOperator(msg.sender)
                && msg.sender != owner()
        ) revert E();
    }

    function _readSlot0() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,,,,) = _pool.slot0();
    }

    function _inOuterRange() internal view returns (bool) {
        if (liqPos.positionId == 0) return false;
        (, int24 tick) = _readSlot0();
        return _inOuterRange(tick);
    }

    function _inOuterRange(int24 tick) internal view returns (bool) {
        return AutoBandLib.inBand(tick, liqPos.tickLower, liqPos.tickUpper);
    }

    function _inInnerComfort(int24 tick) internal view returns (bool) {
        if (!hasBandBase) return false;
        (int24 lower, int24 upper) =
            AutoBandLib.innerTicks(lastBandBaseTick, _spacing(), innerBelowTicks, innerAboveTicks);
        return AutoBandLib.inBand(tick, lower, upper);
    }

    function keeperCheck() external override nonReentrant returns (bool) {
        _onlyKeeper();
        if (liqPos.positionId == 0) {
            (uint256 a, uint256 w) = _getDeployableBalances();
            if (
                a <= LIQUIDITY_DUST && w <= LIQUIDITY_DUST && reservedAsset <= LIQUIDITY_DUST
                    && reservedWeth <= LIQUIDITY_DUST
            ) return false;
            _remintAtTarget();
            return liqPos.positionId != 0;
        }
        (, int24 tick) = _readSlot0();
        if (_inOuterRange(tick) && _inInnerComfort(tick)) return false;
        return _remintAtTarget();
    }

    function harvestBoolean(bool skipIncreaseLiquidity) external override nonReentrant returns (uint256) {
        _onlyKeeper();
        if (liqPos.positionId == 0) return poolValue();
        (,, uint256 valueInWeth) = _collectAllFees(true);
        if (skipIncreaseLiquidity) return poolValue();
        if (minHarvestDelay > 0 && lastHarvest != 0 && block.timestamp - lastHarvest < minHarvestDelay) {
            return poolValue();
        }
        if (valueInWeth == 0) return poolValue();
        // Deploy at the band's own ratio. Balancing here would swap the whole idle pool to `targetAssetBps`
        // without consulting the reserve, so any imbalance is left for `_remintAtTarget` to close from reserve.
        _increaseLiquidityInternal();
        lastHarvest = block.timestamp;
        return poolValue();
    }

    function deposit(uint256 amount) external override nonReentrant {
        _onlyVault();
        if (amount == 0) revert E();
        WETH.safeTransferFrom(msg.sender, address(this), amount);
        _deposit();
    }

    function withdraw(uint256 userShares, address receiver, WithdrawToken outToken) external override nonReentrant {
        _onlyVault();
        if (receiver == address(0)) revert E();
        IAutoVaultRhV3 v = IAutoVaultRhV3(vault);
        uint256 supply = v.totalSupply();
        if (userShares == 0 || supply == 0 || userShares > v.balanceOf(receiver)) revert E();

        if (userShares == supply) {
            if (liqPos.positionId != 0) {
                _decreaseAllLiquidity();
                liqPos.positionId = 0;
            }
            _setReserved(0, 0);
            _payWithdraw(receiver, outToken, _asset.balanceOf(address(this)), WETH.balanceOf(address(this)));
            return;
        }

        uint256 idleAssetBefore = _asset.balanceOf(address(this));
        uint256 idleWethBefore = WETH.balanceOf(address(this));
        // Share of liquidity units — avoids spot-priced LP exit sizing (H001).
        if (liqPos.positionId != 0) {
            uint128 liquidity = liqPos.getPositionLiquidity(positionManager);
            if (liquidity > 0) {
                uint256 liqToRemove = Math.mulDiv(uint256(liquidity), userShares, supply);
                if (liqToRemove == 0 && userShares > 0) liqToRemove = 1;
                if (liqToRemove > liquidity) liqToRemove = liquidity;
                _decreaseLiquidityInternal(uint128(liqToRemove), false);
            }
        }
        uint256 assetAfter = _asset.balanceOf(address(this));
        uint256 wethAfter = WETH.balanceOf(address(this));
        uint256 userAsset = (assetAfter > idleAssetBefore ? assetAfter - idleAssetBefore : 0)
            + Math.mulDiv(idleAssetBefore, userShares, supply);
        uint256 userWeth = (wethAfter > idleWethBefore ? wethAfter - idleWethBefore : 0)
            + Math.mulDiv(idleWethBefore, userShares, supply);
        _consumeReservedShare(userShares, supply);
        _payWithdraw(receiver, outToken, userAsset, userWeth);
    }

    function _payWithdraw(address receiver, WithdrawToken outToken, uint256 userAsset, uint256 userWeth) internal {
        uint256 assetFee = Math.mulDiv(userAsset, withdrawalFeeBps, DIVISOR);
        uint256 wethFee = Math.mulDiv(userWeth, withdrawalFeeBps, DIVISOR);
        userAsset -= assetFee;
        userWeth -= wethFee;
        if (assetFee > 0) _asset.safeTransfer(_feeManager, assetFee);
        if (wethFee > 0) WETH.safeTransfer(_feeManager, wethFee);

        if (outToken == WithdrawToken.WETH) {
            if (userAsset > 0) {
                uint256 beforeOut = WETH.balanceOf(address(this));
                _swap(_asset, _min(userAsset, _asset.balanceOf(address(this))));
                userWeth += WETH.balanceOf(address(this)) - beforeOut;
            }
            userWeth = _min(userWeth, WETH.balanceOf(address(this)));
            if (userWeth > 0) WETH.safeTransfer(receiver, userWeth);
        } else {
            if (userWeth > 0) {
                uint256 beforeOut = _asset.balanceOf(address(this));
                _swap(WETH, _min(userWeth, WETH.balanceOf(address(this))));
                userAsset += _asset.balanceOf(address(this)) - beforeOut;
            }
            userAsset = _min(userAsset, _asset.balanceOf(address(this)));
            if (userAsset > 0) _asset.safeTransfer(receiver, userAsset);
        }
    }

    function _deposit() internal {
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        if (assetBal == 0 && wethBal == 0) return;
        _balanceTokens(assetBal, wethBal);
        _peelReserveFromDeployable();
        (assetBal, wethBal) = _getDeployableBalances();
        if (assetBal == 0 && wethBal == 0) return;
        if (liqPos.positionId == 0) _mintPosition();
        else if (_inOuterRange()) _increaseLiquidityInternal();
        else _remintAtTarget();
    }

    function _remintAtTarget() internal returns (bool) {
        if (liqPos.positionId != 0) {
            _decreaseAllLiquidity();
            liqPos.positionId = 0;
        }
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
        _mintPosition();
        if (liqPos.positionId == 0) return false;
        lastRebalanceTime = block.timestamp;
        return true;
    }

    function _fundDeficitFromReserve(uint256 assetBal, uint256 wethBal) internal {
        uint256 p = _rebalancePrice1e18();
        if (p == 0) return;
        uint256 totalValue = assetBal + Math.mulDiv(wethBal, p, 1e18);
        if (totalValue == 0) return;
        uint256 target = Math.mulDiv(totalValue, targetAssetBps, DIVISOR);
        if (assetBal > target && reservedWeth > 0) {
            uint256 pull = _min(Math.mulDiv(assetBal - target, 1e18, p), reservedWeth);
            _setReserved(reservedAsset, reservedWeth - pull);
        } else if (assetBal < target && reservedAsset > 0) {
            uint256 pull = _min(target - assetBal, reservedAsset);
            _setReserved(reservedAsset - pull, reservedWeth);
        }
    }

    function _peelReserveFromDeployable() internal {
        if (reserveBps == 0) return;
        (uint256 a, uint256 w) = _getDeployableBalances();
        _setReserved(
            reservedAsset + _min(Math.mulDiv(a, reserveBps, DIVISOR), a),
            reservedWeth + _min(Math.mulDiv(w, reserveBps, DIVISOR), w)
        );
    }

    function _mintPosition() internal {
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        if (assetBal == 0 && wethBal == 0) return;
        (, int24 currentTick) = _readSlot0();
        (int24 lower, int24 upper) = AutoBandLib.outerTicks(currentTick, _spacing(), rangeBelowTicks, rangeAboveTicks);
        LiquidityLibraryV2.MintContext memory ctx = LiquidityLibraryV2.MintContext({
            npm: positionManager,
            factory: v3Factory,
            pool: _pool,
            weth: address(WETH),
            tokens: address(_asset),
            assetPoolV3: address(_pool),
            fee: poolFee,
            tickSpacing: tickSpacing,
            m: 1,
            slippageBps: slippageBps,
            dust: LIQUIDITY_DUST
        });
        (uint256 id, uint128 liquidity) = liqPos.mintNewPositionWithRange(ctx, assetBal, wethBal, lower, upper);
        if (id != 0 && liquidity > 0) {
            lastBandBaseTick = TrailingFloorLib.alignDown(currentTick, _spacing());
            hasBandBase = true;
        }
    }

    function _balanceTokens(uint256 assetBal, uint256 wethBal) internal {
        if (assetBal == 0 && wethBal == 0) return;
        // H001-W2: size inventory swaps from TWAP; skip if oracle missing or spot is far from TWAP.
        uint256 p = _rebalancePrice1e18();
        if (p == 0) return;
        uint256 total = assetBal + Math.mulDiv(wethBal, p, 1e18);
        uint256 target = Math.mulDiv(total, targetAssetBps, DIVISOR);
        if (assetBal > target) _swap(_asset, assetBal - target);
        else if (assetBal < target) _swap(WETH, _min(Math.mulDiv(target - assetBal, 1e18, p), wethBal));
    }

    function _swap(IERC20 tokenIn, uint256 amount) internal {
        amount = _min(amount, _spendable(tokenIn));
        if (amount <= LIQUIDITY_DUST) return;
        if (amount > type(uint128).max) revert E();
        address tokenOut = address(tokenIn) == address(WETH) ? address(_asset) : address(WETH);
        tokenIn.forceApprove(address(swapRouter), amount);
        swapRouter.swapExactInputSingleStrict(address(tokenIn), tokenOut, poolFee, uint128(amount));
    }

    function _collectAllFees(bool trackFees) internal returns (uint256 amount0, uint256 amount1, uint256 valueInWeth) {
        if (liqPos.positionId == 0) return (0, 0, 0);
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: liqPos.positionId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        if (amount0 == 0 && amount1 == 0) return (0, 0, 0);
        address token0 = _pool.token0();
        if (trackFees && protocolFeeBps > 0) {
            uint256 fee0 = Math.mulDiv(amount0, protocolFeeBps, DIVISOR);
            uint256 fee1 = Math.mulDiv(amount1, protocolFeeBps, DIVISOR);
            if (fee0 > 0) _routeProtocolFee(token0, fee0);
            if (fee1 > 0) _routeProtocolFee(_pool.token1(), fee1);
            amount0 -= fee0;
            amount1 -= fee1;
        }
        if (trackFees && reserveBps > 0) {
            uint256 r0 = _min(Math.mulDiv(amount0, reserveBps, DIVISOR), amount0);
            uint256 r1 = _min(Math.mulDiv(amount1, reserveBps, DIVISOR), amount1);
            if (token0 == address(WETH)) _setReserved(reservedAsset + r1, reservedWeth + r0);
            else _setReserved(reservedAsset + r0, reservedWeth + r1);
        }
        uint256 feesWeth = token0 == address(WETH) ? amount0 : amount1;
        uint256 feesAsset = token0 == address(WETH) ? amount1 : amount0;
        uint256 p = _spotPrice1e18();
        valueInWeth = feesWeth + (p == 0 ? 0 : Math.mulDiv(feesAsset, 1e18, p));
        if (trackFees) UniswapFeesCollected += valueInWeth;
    }

    function _decreaseAllLiquidity() internal {
        if (liqPos.positionId != 0) _collectAllFees(true);
        _decreaseLiquidityInternal(0, true);
    }

    function _decreaseLiquidityInternal(uint128 liquidityToRemove, bool removeAll) internal {
        if (liqPos.positionId == 0) return;
        LiquidityLibraryV2.DecreaseContext memory ctx =
            LiquidityLibraryV2.DecreaseContext({npm: positionManager, pool: _pool});
        if (removeAll) {
            liqPos.decreaseAllLiquidity(ctx);
            if (liqPos.getPositionLiquidity(positionManager) > 0) {
                liqPos.decreaseAllLiquidity(ctx);
            }
        } else {
            if (liquidityToRemove == 0) return;
            // Skim protocolFeeBps / reserveBps before principal exit (parity with `_decreaseAllLiquidity`).
            _collectAllFees(true);
            liqPos.decreaseLiquidityByAmount(ctx, liquidityToRemove);
        }
        _collectAllFees(false);
    }

    function _increaseLiquidityInternal() internal returns (uint128) {
        if (liqPos.positionId == 0) return 0;
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        (uint256 amount0, uint256 amount1) = _poolBalances(assetBal, wethBal);
        LiquidityLibraryV2.IncreaseContext memory ctx = LiquidityLibraryV2.IncreaseContext({
            npm: positionManager, pool: _pool, fee: poolFee, slippageBps: slippageBps, dust: LIQUIDITY_DUST
        });
        return liqPos.increaseLiquidityInternal(ctx, IERC20(_pool.token0()), IERC20(_pool.token1()), amount0, amount1);
    }

    function _getDeployableBalances() internal view returns (uint256 assetBal, uint256 wethBal) {
        assetBal = _asset.balanceOf(address(this));
        wethBal = WETH.balanceOf(address(this));
        assetBal = assetBal > reservedAsset ? assetBal - reservedAsset : 0;
        wethBal = wethBal > reservedWeth ? wethBal - reservedWeth : 0;
    }

    function _spendable(IERC20 token) internal view returns (uint256 bal) {
        bal = token.balanceOf(address(this));
        uint256 reserved = address(token) == address(WETH) ? reservedWeth : reservedAsset;
        return bal > reserved ? bal - reserved : 0;
    }

    function _setReserved(uint256 assetAmount, uint256 wethAmount) internal {
        reservedAsset = assetAmount;
        reservedWeth = wethAmount;
    }

    function _consumeReservedShare(uint256 shares, uint256 supply) internal {
        _setReserved(
            reservedAsset - Math.mulDiv(reservedAsset, shares, supply),
            reservedWeth - Math.mulDiv(reservedWeth, shares, supply)
        );
    }

    function _spotPrice1e18() internal view returns (uint256) {
        (uint160 sqrtP,) = _readSlot0();
        return _price1e18FromSqrt(sqrtP);
    }

    /// @dev ASSET per WETH in 1e18 from a Uniswap V3 sqrtPriceX96.
    function _price1e18FromSqrt(uint160 sqrtP) internal view returns (uint256) {
        if (sqrtP == 0) return 0;
        uint256 price = Math.mulDiv(uint256(sqrtP), uint256(sqrtP), (uint256(1) << 192) / 1e18);
        if (_pool.token0() == address(WETH)) return price;
        return price == 0 ? 0 : Math.mulDiv(1e18, 1e18, price);
    }

    /// @dev Arithmetic mean tick TWAP via pool `observe`. Returns 0 if disabled or cardinality insufficient.
    function _twapPrice1e18() internal view returns (uint256) {
        uint32 period = twapSeconds;
        if (period == 0) return 0;
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = period;
        secondsAgos[1] = 0;
        try _pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int56 periodI = int56(uint56(period));
            int24 meanTick = int24(delta / periodI);
            if (delta < 0 && (delta % periodI != 0)) meanTick--;
            return _price1e18FromSqrt(TickMath.getSqrtRatioAtTick(meanTick));
        } catch {
            return 0;
        }
    }

    function _spotAlignedWithTwap(uint256 spot, uint256 twap) internal view returns (bool) {
        if (spot == 0 || twap == 0) return false;
        uint256 hi = spot > twap ? spot : twap;
        uint256 lo = spot > twap ? twap : spot;
        return Math.mulDiv(hi - lo, DIVISOR, twap) <= maxTwapDeviationBps;
    }

    /// @notice TWAP price for rebalance if spot is within `maxTwapDeviationBps`; else 0 (caller skips).
    function _rebalancePrice1e18() internal view returns (uint256) {
        uint256 twap = _twapPrice1e18();
        if (twap == 0) return 0;
        if (!_spotAlignedWithTwap(_spotPrice1e18(), twap)) return 0;
        return twap;
    }

    function _poolBalances(uint256 assetBal, uint256 wethBal) internal view returns (uint256, uint256) {
        return _pool.token0() == address(WETH) ? (wethBal, assetBal) : (assetBal, wethBal);
    }

    function balanceOfPool() public view returns (uint256 assetAmt, uint256 wethAmt) {
        if (liqPos.positionId == 0) return (0, 0);
        uint128 liquidity = liqPos.getPositionLiquidity(positionManager);
        (uint160 sqrtP,) = _readSlot0();
        (uint160 sqrtL, uint160 sqrtU) = LiquidityLibraryV2.getSqrtRatios(liqPos.tickLower, liqPos.tickUpper);
        (uint256 amount0, uint256 amount1) = LiquidityLibraryV2.getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liquidity);
        (assetAmt, wethAmt) = _pool.token0() == address(WETH) ? (amount1, amount0) : (amount0, amount1);
    }

    function _navAtPrice(uint256 p) internal view returns (uint256) {
        if (p == 0) return 0;
        (uint256 assetAmt, uint256 wethAmt) = balanceOfPool();
        uint256 poolWeth = wethAmt + Math.mulDiv(assetAmt, 1e18, p);
        uint256 idleWeth = WETH.balanceOf(address(this)) + Math.mulDiv(_asset.balanceOf(address(this)), 1e18, p);
        return poolWeth + idleWeth;
    }

    function _poolValueOnly() internal view returns (uint256) {
        (uint256 assetAmt, uint256 wethAmt) = balanceOfPool();
        uint256 p = _spotPrice1e18();
        return wethAmt + (p == 0 ? 0 : Math.mulDiv(assetAmt, 1e18, p));
    }

    function balanceOfIdle() public view returns (uint256) {
        uint256 p = _spotPrice1e18();
        return WETH.balanceOf(address(this)) + (p == 0 ? 0 : Math.mulDiv(_asset.balanceOf(address(this)), 1e18, p));
    }

    function poolValue() public view override returns (uint256) {
        return _poolValueOnly() + balanceOfIdle();
    }

    /// @notice NAV using TWAP (same gate as rebalance). `0` if observe fails or spot off TWAP.
    function poolValueTwap() public view override returns (uint256) {
        return _navAtPrice(_rebalancePrice1e18());
    }

    /// @notice NAV at the raw TWAP, with no spot-deviation gate. Zero only when the oracle is unreadable.
    /// @dev The gate on `poolValueTwap` guards the rebalance path, which trades. Minting only prices, and
    ///      `min(spot, twap)` is safe however far apart the two sit: a depressed spot is caught by the TWAP,
    ///      while an inflated one only shorts the depositor who caused it. Refusing the TWAP on deviation is
    ///      therefore not a safeguard here, it is what drops minting into the high-water fallback precisely
    ///      when the market is moving, charging honest depositors the full drawdown.
    function poolValueTwapRaw() public view override returns (uint256) {
        return _navAtPrice(_twapPrice1e18());
    }

    function balance() external view override returns (uint256) {
        return poolValue();
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
