// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../interfaces/IPositionManagerV4.sol";
import "../../interfaces/IPoolManagerV4.sol";
import "./UStrategyManager.sol";
import {IUFloatV4StrategySwapRouter} from "./interfaces/IUFloatV4StrategySwapRouter.sol";
import "./interfaces/IOutOfRangeStrategyV4.sol";
import "./interfaces/IUFloatStrategyV4.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./libraries/TrailingFloorLib.sol";
import "../../libraries/LiquidityLibraryV4.sol";
import "../../interfaces/IAllowanceTransfer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import "./V4Deployments8453.sol";

contract UFloatStrategyV4 is IUFloatStrategyV4, UStrategyManager, ReentrancyGuard, IERC721Receiver, IOutOfRangeStrategyV4 {
    error Unauthorized();
    error ZeroValue();
    error ZeroAddress();
    error PositionExists();
    error TokenNotOnRouter();
    error TokenAlreadyAllowed();
    error TokenNotAllowed();
    error CannotRemoveActiveAsset();
    error CannotAllowWeth();
    error PoolKeyInvalid();
    error InvalidSwapToken();
    error SwapAmountTooLarge();
    error AlreadyInitialized();
    error PoolPriceUnavailable();

    using SafeERC20 for IERC20;
    using LiquidityLibraryV4 for LiquidityLibraryV4.PositionState;

    address public immutable factory;
    IPositionManagerV4 public immutable positionManager;
    IPoolManagerV4 private immutable poolManager;
    IERC20 private immutable WETH;
    LiquidityLibraryV4.PositionState private liqPos;
    LiquidityLibraryV4.PoolKey public poolKey;
    IUFloatV4StrategySwapRouter private swapRouterV4;
    mapping(address => bool) public isAllowedToken;
    address[] public allowedTokens;
    mapping(address => uint256) private _allowedTokenIndex;
    IERC20 public ASSET;
    address private constant PERMIT2 = V4Deployments8453.PERMIT2;
    address private tritonAddr;
    address private keeperStratAddr;
    bool private _initialized;
    uint256 public lastOffensiveTime;
    uint256 public lastHarvest;
    uint256 public PrevHarvestTime;
    uint256 public UniswapFeesCollected;
    uint256 public lastUniswapFeeTotal;
    enum Mode { NORMAL, DEFENSIVE, OFFENSIVE, STABLE }
    Mode internal stratMode;
    uint256 public defensiveEnteredAt;
    uint256 public consecutiveOffensiveCount;
    uint256 public prevConsecutiveOffensiveCount;

    function _lpModeActive() internal view returns (bool) {
        return stratMode == Mode.NORMAL || stratMode == Mode.OFFENSIVE;
    }

    function _idlePaused() internal view returns (bool) {
        Mode m = stratMode;
        return m == Mode.DEFENSIVE || m == Mode.STABLE;
    }

    function mode() external view override returns (uint8) {
        return uint8(uint256(stratMode));
    }

    function _readSlot0() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        if (poolKey.currency0 == address(0) && poolKey.currency1 == address(0)) {
            return (0, 0);
        }
        (sqrtPriceX96, tick) = LiquidityLibraryV4.getSlot0(poolManager, poolKey);
    }

    function _poolHookData() internal view returns (bytes memory) {
        if (poolKey.currency0 == address(0) && poolKey.currency1 == address(0)) {
            return "";
        }
        (, bytes memory hookData) = swapRouterV4.getV4PoolConfig(address(ASSET));
        return hookData;
    }

    function _requireAuthorized() internal view {
        address s = _msgSender();
        if (s != tritonAddr && s != keeperStratAddr && s != owner()) revert Unauthorized();
    }

    modifier onlyAuthorized() {
        _requireAuthorized();
        _;
    }

    /// @dev Implementation only — clones are bootstrapped by the factory.
    constructor(address _factory) {
        if (_factory == address(0)) revert ZeroAddress();
        factory = _factory;
        WETH = IERC20(V4Deployments8453.WETH);
        positionManager = IPositionManagerV4(V4Deployments8453.POSITION_MANAGER);
        poolManager = IPoolManagerV4(V4Deployments8453.POOL_MANAGER);
        _initialized = true;
    }

    /// @dev Called once by factory after clone. Wires infra, allowlist, and `tokens[0]` as ASSET (LP on first `depositWeth`).
    function bootstrapStrategy(
        address owner_,
        address swapRouter,
        address triton,
        address keeper,
        address[] calldata tokens
    ) external {
        if (_initialized) revert AlreadyInitialized();
        if (msg.sender != factory) revert Unauthorized();
        if (owner_ == address(0) || swapRouter == address(0)) revert ZeroAddress();
        if (tokens.length == 0) revert TokenNotAllowed();

        _initialized = true;
        tritonAddr = triton;
        keeperStratAddr = keeper;
        swapRouterV4 = IUFloatV4StrategySwapRouter(swapRouter);
        _initStrategyDefaults();

        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            _addAllowedToken(tokens[i]);
        }
        _configureAsset(tokens[0]);
        stratMode = Mode.NORMAL;
        defensiveEnteredAt = 0;
        _transferOwnership(owner_);
    }

    function _initStrategyDefaults() private {
        // Clones start with zeroed storage — field initializers on UStrategyManager do not apply.
        targetAssetBps = 5000;
        offensiveAssetBps = 4000;
        rangeBelowBps = 1000;
        rangeAboveBps = 2000;
        minFloorTickCount = 2;
        offensiveStaleDuration = 3 hours;
        slippageBps = 100;
        minHarvestDelay = 2 hours;
    }

    function _setPoolKey(LiquidityLibraryV4.PoolKey memory key) internal {
        poolKey = key;
        poolFeePips = key.fee;
        tickSpacing = key.tickSpacing;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function addAllowedToken(address token) external onlyOwner {
        _addAllowedToken(token);
    }

    function _addAllowedToken(address token) internal {
        if (token == address(0)) revert ZeroAddress();
        if (token == address(WETH)) revert CannotAllowWeth();
        if (isAllowedToken[token]) revert TokenAlreadyAllowed();
        if (!swapRouterV4.hasV4PoolConfig(token)) revert TokenNotOnRouter();
        isAllowedToken[token] = true;
        allowedTokens.push(token);
        _allowedTokenIndex[token] = allowedTokens.length;
    }

    function _configureAsset(address assetAddr) internal {
        if (assetAddr == address(WETH)) revert CannotAllowWeth();
        if (!isAllowedToken[assetAddr]) revert TokenNotAllowed();
        ASSET = IERC20(assetAddr);
        _setPoolKey(_poolKeyFromRouter(assetAddr));
        _giveAllowances();
    }

    function removeAllowedToken(address token) external onlyOwner {
        if (token == address(ASSET) && liqPos.positionId != 0) revert CannotRemoveActiveAsset();
        uint256 idx = _allowedTokenIndex[token];
        if (idx == 0) revert TokenNotAllowed();
        uint256 last = allowedTokens.length;
        if (idx != last) {
            address moved = allowedTokens[last - 1];
            allowedTokens[idx - 1] = moved;
            _allowedTokenIndex[moved] = idx;
        }
        allowedTokens.pop();
        delete _allowedTokenIndex[token];
        delete isAllowedToken[token];
    }

    function allowedTokenCount() external view returns (uint256) {
        return allowedTokens.length;
    }

    function mintPosition(address token) external onlyOwner nonReentrant {
        if (liqPos.positionId != 0) revert PositionExists();
        if (stratMode != Mode.STABLE) revert TokenNotAllowed();
        _changeAsset(token);
    }

    function depositWeth(uint256 amount) external override onlyOwner nonReentrant {
        if (amount == 0) revert ZeroValue();
        WETH.safeTransferFrom(_msgSender(), address(this), amount);
        _processDeposit();
    }

    function withdrawWeth(uint256 wethAmount) external override onlyOwner nonReentrant {
        if (wethAmount == 0) revert ZeroValue();
        uint256 totalValue = totalValueWeth();
        if (totalValue == 0) revert ZeroValue();
        if (wethAmount > totalValue) wethAmount = totalValue;
        _withdrawWethNotional(wethAmount, totalValue, _msgSender());
    }

    function totalValueWeth() public view returns (uint256) {
        return balanceOfIdle() + poolValue();
    }

    function _unwindPoolNotional(uint256 wethNotional, uint256 totalValue)
        internal
        returns (uint256 wethFromPool, uint256 assetFromPool, uint256 idleWethBefore, uint256 idleAssetBefore)
    {
        idleAssetBefore = ASSET.balanceOf(address(this));
        idleWethBefore = WETH.balanceOf(address(this));
        if (liqPos.positionId != 0) {
            uint256 poolVal = poolValue();
            if (poolVal > 0) {
                uint256 amountFromPool = Math.mulDiv(poolVal, wethNotional, totalValue);
                if (amountFromPool > 0) {
                    _decreaseLiquidity(amountFromPool);
                }
            }
        }
        uint256 assetAfter = ASSET.balanceOf(address(this));
        uint256 wethAfter = WETH.balanceOf(address(this));
        assetFromPool = assetAfter > idleAssetBefore ? assetAfter - idleAssetBefore : 0;
        wethFromPool = wethAfter > idleWethBefore ? wethAfter - idleWethBefore : 0;
    }

    function _withdrawWethNotional(uint256 wethNotional, uint256 totalValue, address receiver) internal {
        uint256 totalUserWeth;
        uint256 wethFee;
        if (stratMode == Mode.STABLE) {
            (uint256 wethFromPool, , uint256 idleWethBefore, ) = _unwindPoolNotional(wethNotional, totalValue);
            totalUserWeth = wethFromPool + Math.mulDiv(idleWethBefore, wethNotional, totalValue);
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
            (uint256 wethFromPool, uint256 assetFromPool, uint256 idleWethBefore, uint256 idleAssetBefore) =
                _unwindPoolNotional(wethNotional, totalValue);
            totalUserAsset = assetFromPool + Math.mulDiv(idleAssetBefore, wethNotional, totalValue);
            totalUserWeth = wethFromPool + Math.mulDiv(idleWethBefore, wethNotional, totalValue);
        }
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

    function _processDeposit() internal {
        if (stratMode == Mode.STABLE) {
            return;
        }
        if (liqPos.positionId == 0 || _lpModeActive()) {
            _deposit();
            return;
        }
        if (stratMode == Mode.DEFENSIVE) {
            (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
            if (assetBal > 0 || wethBal > 0) {
                _balanceTokens(assetBal, wethBal);
            }
        }
    }

    function harvestBoolean(bool skipIncreaseLiquidity) external nonReentrant returns (uint256 newAssets) {
        if (msg.sender != address(this)) {
            _requireAuthorized();
        }
        _harvest(skipIncreaseLiquidity);
        return poolValue();
    }

    uint256 private constant LIQUIDITY_DUST = 1_000_000_000_000;

    function _noteHarvestActivity() internal {
        PrevHarvestTime = lastHarvest;
        lastHarvest = block.timestamp;
    }

    function _harvest(bool skipIncreaseLiquidity) internal {
        if (minHarvestDelay > 0 && lastHarvest != 0 && block.timestamp - lastHarvest < minHarvestDelay) {
            return;
        }
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
        if (valueInWeth == 0) {
            return;
        }
        if (!skipIncreaseLiquidity && _lpModeActive()) {
            (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
            _balanceTokens(assetBal, wethBal);
            if (_increaseLiquidityInternal() > 0) {
                _noteHarvestActivity();
            }
        }
    }

    function _inRange() internal view returns (bool) {
        if (liqPos.positionId == 0) return false;
        (, int24 poolTick) = _readSlot0();
        (int24 posTickLower, int24 posTickUpper) = (liqPos.tickLower, liqPos.tickUpper);
        return poolTick >= posTickLower && poolTick < posTickUpper;
    }

    function _isAllWeth(uint256 assetBal, uint256 wethBal) internal pure returns (bool) {
        return wethBal > LIQUIDITY_DUST && assetBal <= LIQUIDITY_DUST;
    }

    function _isAllAsset(uint256 assetBal, uint256 wethBal) internal pure returns (bool) {
        return assetBal > LIQUIDITY_DUST && wethBal <= LIQUIDITY_DUST;
    }

    function _handleOutOfRange() internal returns (bool) {
        if (liqPos.positionId == 0) return false;
        uint128 remainingLiq = _drainPositionLiquidity(6);
        if (remainingLiq != 0) return true;
        liqPos.positionId = 0;
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        if (_isAllWeth(assetBal, wethBal)) {
            _enterOffensive();
            return liqPos.positionId != 0;
        }
        if (_isAllAsset(assetBal, wethBal)) {
            _enterDefensive();
            return false;
        }
        return false;
    }

    function _handleOffensiveStale() internal returns (bool) {
        if (stratMode == Mode.OFFENSIVE
                && block.timestamp - lastOffensiveTime > offensiveStaleDuration
                && consecutiveOffensiveCount == prevConsecutiveOffensiveCount + 1) {
            _decreaseAllLiquidity();
            liqPos.positionId = 0;
            stratMode = Mode.NORMAL;
            consecutiveOffensiveCount = 0;
            prevConsecutiveOffensiveCount = 0;
            (uint256 staleAssetBal, uint256 staleWethBal) = _getTokenBalances();
            _balanceTokens(staleAssetBal, staleWethBal);
            _mintAsymmetricPosition();
            _noteHarvestActivity();
            return true;
        }
        return false;
    }

    function keeperCheck() external nonReentrant returns (bool) {
        if (stratMode == Mode.STABLE) return false;
        if (_handleOffensiveStale()) return true;
        if (liqPos.positionId == 0) return false;
        if (_inRange()) return true;
        return _handleOutOfRange();
    }

    function _enterDefensive() internal {
        if (liqPos.positionId != 0) revert PositionExists();
        consecutiveOffensiveCount = 0;
        defensiveEnteredAt = block.timestamp;
        stratMode = Mode.DEFENSIVE;
    }

    function _enterOffensive() internal {
        if (liqPos.positionId != 0) revert PositionExists();
        prevConsecutiveOffensiveCount = consecutiveOffensiveCount;
        lastOffensiveTime = block.timestamp;
        consecutiveOffensiveCount++;
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        uint256 p = _spotPrice1e18();
        uint256 totalValue = assetBal + (p == 0 ? 0 : Math.mulDiv(wethBal, p, 1e18));
        if (assetBal == 0 && wethBal == 0 || p == 0 || totalValue == 0) {
            _enterDefensive();
            return;
        }
        stratMode = Mode.OFFENSIVE;
        _balanceTokens(assetBal, wethBal);
        _mintAsymmetricPosition();
        if (liqPos.positionId != 0) {
            defensiveEnteredAt = 0;
        } else {
            _enterDefensive();
        }
    }

    function _asymmetricTicks(int24 currentTick) internal view returns (int24 lower, int24 upper) {
        int24 spacing = poolKey.tickSpacing;
        uint256 belowBps = _effectiveRangeBelowBps();
        uint256 aboveBps = rangeAboveBps;
        if (aboveBps == 0 || aboveBps >= 10_000) aboveBps = 2000;
        lower = TrailingFloorLib.alignDown(
            TrailingFloorLib.floorTickBelowCurrentByBps(currentTick, belowBps),
            spacing
        );
        upper = TrailingFloorLib.alignUp(
            TrailingFloorLib.ceilTickAboveCurrentByBps(currentTick, aboveBps),
            spacing
        );
        if (lower >= upper) upper = lower + spacing;
    }

    function _mintAsymmetricPosition() internal {
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        if (assetBal == 0 && wethBal == 0) return;
        (, int24 currentTick) = _readSlot0();
        (int24 lower, int24 upper) = _asymmetricTicks(currentTick);
        (uint256 bal0, uint256 bal1) = _poolBalances(assetBal, wethBal);
        LiquidityLibraryV4.MintContext memory ctx = LiquidityLibraryV4.MintContext({
            posm: positionManager,
            poolManager: poolManager,
            poolKey: poolKey,
            m: 1,
            slippageBps: slippageBps,
            dust: LIQUIDITY_DUST,
            hookData: _poolHookData()
        });
        (uint256 newId, uint128 liq) = liqPos.mintNewPositionWithRange(ctx, bal0, bal1, lower, upper);
        if (newId == 0 || liq == 0) {
            liqPos.positionId = 0;
        }
    }

    function _poolBalances(uint256 assetBal, uint256 wethBal) internal view returns (uint256 bal0, uint256 bal1) {
        address p0 = poolKey.currency0;
        bal0 = p0 == address(WETH) ? wethBal : assetBal;
        bal1 = p0 == address(WETH) ? assetBal : wethBal;
    }

    function _deposit() internal {
        if (stratMode == Mode.STABLE) {
            return;
        }
        if (liqPos.positionId != 0 && _idlePaused()) {
            return;
        }
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        if (assetBal == 0 && wethBal == 0) return;
        _balanceTokens(assetBal, wethBal);
        if (liqPos.positionId == 0) {
            _mintAsymmetricPosition();
        } else {
            _increaseLiquidityInternal();
        }
    }

    function _collectAllFees(bool trackFees) internal returns (uint256 amount0, uint256 amount1, uint256 valueInWeth) {
        if (liqPos.positionId == 0) return (0, 0, 0);
        if (liqPos.getPositionLiquidity(positionManager) == 0) return (0, 0, 0);
        LiquidityLibraryV4.DecreaseContext memory dctx = LiquidityLibraryV4.DecreaseContext({
            posm: positionManager,
            poolManager: poolManager,
            poolKey: poolKey,
            hookData: _poolHookData()
        });
        (amount0, amount1) = LiquidityLibraryV4.collectAllFees(liqPos, dctx, address(this));
        valueInWeth = 0;
        if (amount0 > 0 || amount1 > 0) {
            address p0 = poolKey.currency0;
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
        wethBal = WETH.balanceOf(address(this));
    }

    function _assetTargetBps() internal view returns (uint256) {
        if (stratMode == Mode.OFFENSIVE && consecutiveOffensiveCount >= minFloorTickCount) {
            if (offensiveAssetBps != 0) return offensiveAssetBps;
        }
        if (targetAssetBps != 0) return targetAssetBps;
        return 5000;
    }

    uint256 private constant MIN_RANGE_BELOW_BPS = 200;
    uint256 private constant MAX_OFFENSIVE_RATCHET_COUNT = 4;

    /// @dev After `minFloorTickCount` OFFENSIVE re-mints, tighten below-range by 2/3 per step; caps at 4th offensive.
    function _effectiveRangeBelowBps() internal view returns (uint256) {
        uint256 base = rangeBelowBps;
        if (base == 0 || base >= 10_000) base = 1000;
        if (consecutiveOffensiveCount < minFloorTickCount) return base;

        uint256 count = consecutiveOffensiveCount;
        if (count > MAX_OFFENSIVE_RATCHET_COUNT) count = MAX_OFFENSIVE_RATCHET_COUNT;
        uint256 steps = count - minFloorTickCount + 1;
        uint256 effective = base;
        for (uint256 i = 0; i < steps; i++) {
            effective = effective * 2 / 3;
            if (effective < MIN_RANGE_BELOW_BPS) return MIN_RANGE_BELOW_BPS;
        }
        return effective;
    }

    function _balanceTokens(uint256 assetBal, uint256 wethBal) internal {
        if (assetBal == 0 && wethBal == 0) return;
        uint256 p = _spotPrice1e18();
        if (p == 0) {
            if (wethBal > LIQUIDITY_DUST || assetBal > LIQUIDITY_DUST) revert PoolPriceUnavailable();
            return;
        }
        uint256 wethAsTokens = Math.mulDiv(wethBal, p, 1e18);
        uint256 totalValue = assetBal + wethAsTokens;
        if (totalValue == 0) return;
        uint256 target = Math.mulDiv(totalValue, _assetTargetBps(), 10_000);
        if (assetBal > target) {
            uint256 toSell = assetBal - target;
            if (toSell > 0) _swap(ASSET, toSell);
        } else if (assetBal < target) {
            uint256 deficit = target - assetBal;
            uint256 wethToSell = Math.mulDiv(deficit, 1e18, p);
            if (wethToSell > wethBal) wethToSell = wethBal;
            if (wethToSell > 0) _swap(WETH, wethToSell);
        }
    }

    function _increaseLiquidityInternal() internal returns (uint128 liqAdded) {
        if (liqPos.positionId == 0) return 0;
        address p0 = poolKey.currency0;
        address p1 = poolKey.currency1;
        LiquidityLibraryV4.IncreaseContext memory ctx = LiquidityLibraryV4.IncreaseContext({
            posm: positionManager,
            poolManager: poolManager,
            poolKey: poolKey,
            slippageBps: slippageBps,
            dust: LIQUIDITY_DUST,
            hookData: _poolHookData()
        });
        return liqPos.increaseLiquidityInternal(ctx, IERC20(p0), IERC20(p1));
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
        LiquidityLibraryV4.DecreaseContext memory ctx = LiquidityLibraryV4.DecreaseContext({
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

    function _swap(IERC20 tokenIn, uint256 amount) internal {
        if (amount == 0) return;
        uint256 bal = tokenIn.balanceOf(address(this));
        if (amount > bal) amount = bal;
        if (amount <= LIQUIDITY_DUST) return;
        if (address(tokenIn) != poolKey.currency0 && address(tokenIn) != poolKey.currency1) {
            revert InvalidSwapToken();
        }
        if (amount > type(uint128).max) revert SwapAmountTooLarge();
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
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = LiquidityLibraryV4.getSqrtRatios(liqPos.tickLower, liqPos.tickUpper);
        (uint256 amount0, uint256 amount1) = LiquidityLibraryV4.getAmountsForLiquidity(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, liquidity);
        address p0 = poolKey.currency0;
        return p0 == address(WETH) ? (amount1, amount0) : (amount0, amount1);
    }

    function totalLiquidity() external view override returns (uint128) {
        return liqPos.getPositionLiquidity(positionManager);
    }

    function _calculateLiquidityToRemove(uint256 amount) internal view returns (uint256) {
        if (liqPos.positionId == 0) return 0;
        (int24 _tickLower, int24 _tickUpper, uint128 liquidity) =
            (liqPos.tickLower, liqPos.tickUpper, LiquidityLibraryV4.getPositionLiquidity(liqPos, positionManager));
        (uint160 sqrtP, ) = _readSlot0();
        uint128 positionLiquidity = liqPos.getPositionLiquidity(positionManager);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = LiquidityLibraryV4.getSqrtRatios(_tickLower, _tickUpper);
        (uint256 amount0, uint256 amount1) = LiquidityLibraryV4.getAmountsForLiquidity(sqrtP, sqrtLowerX96, sqrtUpperX96, positionLiquidity);
        address p0 = poolKey.currency0;
        (uint256 assetAmt, uint256 wethAmt) = p0 == address(WETH) ? (amount1, amount0) : (amount0, amount1);
        uint256 p = _spotPrice1e18();
        uint256 assetAsWeth = p != 0 ? Math.mulDiv(assetAmt, 1e18, p) : 0;
        uint256 totalValue = wethAmt + assetAsWeth;
        if (totalValue == 0 || liquidity == 0) return 0;
        uint256 proportion = Math.mulDiv(amount, 1e18, totalValue);
        uint256 targetTokenAmt = Math.mulDiv(assetAmt, proportion, 1e18);
        uint256 targetWethAmt = Math.mulDiv(wethAmt, proportion, 1e18);
        (uint256 bal0, uint256 bal1) = p0 == address(WETH) ? (targetWethAmt, targetTokenAmt) : (targetTokenAmt, targetWethAmt);
        uint128 liqNeeded = LiquidityLibraryV4.getLiquidityForAmounts(sqrtP, sqrtLowerX96, sqrtUpperX96, bal0, bal1);
        if (liqNeeded > liquidity) return liquidity;
        return liqNeeded;
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

    function _fromV4PoolKey(PoolKey memory key) internal pure returns (LiquidityLibraryV4.PoolKey memory) {
        return LiquidityLibraryV4.PoolKey({
            currency0: Currency.unwrap(key.currency0),
            currency1: Currency.unwrap(key.currency1),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: address(key.hooks)
        });
    }

    function _poolKeyFromRouter(address asset) internal view returns (LiquidityLibraryV4.PoolKey memory key) {
        (PoolKey memory routerKey, ) = swapRouterV4.getV4PoolConfig(asset);
        key = _fromV4PoolKey(routerKey);
        address w = address(WETH);
        if (key.currency0 >= key.currency1) revert PoolKeyInvalid();
        if (!((key.currency0 == asset && key.currency1 == w) || (key.currency1 == asset && key.currency0 == w))) {
            revert PoolKeyInvalid();
        }
    }

    function _flattenAllAndClearPosition() internal {
        _decreaseAllLiquidity();
        if (liqPos.positionId != 0 && liqPos.getPositionLiquidity(positionManager) == 0) {
            liqPos.positionId = 0;
        }
    }

    function changeAsset(address _newAssetAddr) external override onlyAuthorized {
        _changeAsset(_newAssetAddr);
    }

    function exitToStable() external {
        address s = _msgSender();
        if (s != tritonAddr && s != owner()) revert Unauthorized();
        _changeAsset(address(WETH));
    }

    function _changeAsset(address _newAssetAddr) internal {
        if (_newAssetAddr == address(0)) revert ZeroAddress();
        address w = address(WETH);
        if (_newAssetAddr == w) {
            consecutiveOffensiveCount = 0;
            _flattenAllAndClearPosition();
            if (address(ASSET) != w) {
                uint256 oldAssetBal = ASSET.balanceOf(address(this));
                if (oldAssetBal > 0) _swap(ASSET, oldAssetBal);
            }
            stratMode = Mode.STABLE;
            defensiveEnteredAt = block.timestamp;
            return;
        }
        if (!isAllowedToken[_newAssetAddr]) revert TokenNotAllowed();
        LiquidityLibraryV4.PoolKey memory key = _poolKeyFromRouter(_newAssetAddr);
        consecutiveOffensiveCount = 0;
        _flattenAllAndClearPosition();
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        if (assetBal > 0 && address(ASSET) != w) {
            _swap(ASSET, assetBal);
        }
        ASSET = IERC20(_newAssetAddr);
        _setPoolKey(key);
        _giveAllowances();
        (assetBal, wethBal) = _getTokenBalances();
        stratMode = Mode.NORMAL;
        defensiveEnteredAt = 0;
        if (wethBal == 0 && assetBal == 0) {
            return;
        }
        _balanceTokens(assetBal, wethBal);
        _mintAsymmetricPosition();
    }
}
