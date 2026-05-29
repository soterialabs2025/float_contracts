// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../interfaces/IPositionManagerV4.sol";
import "../../interfaces/IPoolManagerV4.sol";
import "./UStrategyManager.sol";
import {IUfloatV4StrategySwapRouter} from "./interfaces/IUfloatV4StrategySwapRouter.sol";
import "./interfaces/IOutOfRangeStrategyV4.sol";
import "./interfaces/IUfloatStrategyV4.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./libraries/TrailingFloorLib.sol";
import "../../libraries/LiquidityLibraryV4.sol";
import "../../interfaces/IAllowanceTransfer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
contract UfloatStrategyV4 is IUfloatStrategyV4, UStrategyManager, ReentrancyGuard, IERC721Receiver, IOutOfRangeStrategyV4 {
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
    using SafeERC20 for IERC20;
    using LiquidityLibraryV4 for LiquidityLibraryV4.PositionState;
    IPositionManagerV4 public immutable positionManager;
    LiquidityLibraryV4.PositionState private liqPos;
    IPoolManagerV4 private poolManager;
    LiquidityLibraryV4.PoolKey public poolKey;
    IUfloatV4StrategySwapRouter private swapRouterV4;
    mapping(address => bool) public isAllowedToken;
    address[] private _allowedTokens;
    mapping(address => uint256) private _allowedTokenIndex;
    address public managerAddress;
    IERC20 public ASSET;
    IERC20 private WETH;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private demeterAddr;
    address private keeperStratAddr;
    int24 public baselineTick;
    int24 public floorTick;
    uint256 public lastOffensiveTime;
    uint256 public prevOffensiveTime;
    uint256 public lastHarvest; 
    uint256 public PrevHarvestTime;
    uint256 public baseTokenShareBps = 5_000;
    uint256 private tokenShareAnchorBps;
    uint256 public UniswapFeesCollected; 
    uint256 public lastUniswapFeeTotal;
    struct Deposit {address owner; uint128 liquidity; address token0; address token1;}
    mapping(uint256 => Deposit) public deposits;
    enum Mode { NORMAL, DEFENSIVE, OFFENSIVE, STABLE }
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
        return m == Mode.DEFENSIVE || m == Mode.STABLE;
    }
    function mode() external view override returns (uint8) {
        return uint8(uint256(stratMode));
    }
    function _readSlot0() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        if (liqPos.positionId == 0) {
            (sqrtPriceX96, tick) = LiquidityLibraryV4.getSlot0Safe(poolManager, poolKey);
        } else {
            (sqrtPriceX96, tick) = LiquidityLibraryV4.getSlot0(poolManager, poolKey);
        }
    }
    function _poolHookData() internal view returns (bytes memory) {
        (, bytes memory hookData) = swapRouterV4.getV4PoolConfig(address(ASSET));
        return hookData;
    }
    function _requireAuthorized() internal view {
        address s = _msgSender();
        if (s != demeterAddr && s != keeperStratAddr && s != managerAddress && s != owner()) revert Unauthorized();
    }
    modifier onlyAuthorized() {
        _requireAuthorized();
        _;
    }
    constructor(
        address weth_,
        address positionManager_,
        address poolManager_,
        address _assetAddr,
        address _managerAddr,
        address _swapRouterAddr,
        address _demeterAddr,
        address _keeperStrategyAddr
    ) UStrategyManager() {
        if (weth_ == address(0) || positionManager_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        WETH = IERC20(weth_);
        positionManager = IPositionManagerV4(positionManager_);
        poolManager = IPoolManagerV4(poolManager_);
        deviationBands = UStrategyManager.DeviationBands({lowerBps: 200, upperBps: 3000, maxTokenCapBps: 9800});
        offensiveBands = UStrategyManager.DeviationBands({lowerBps: 200, upperBps: 2600, maxTokenCapBps: 9800});
        managerAddress = _managerAddr;
        demeterAddr = _demeterAddr;
        keeperStratAddr = _keeperStrategyAddr;
        swapRouterV4 = IUfloatV4StrategySwapRouter(_swapRouterAddr);
        ASSET = IERC20(_assetAddr);
        _setPoolKey(_poolKeyFromRouter(_assetAddr));
        _giveAllowances();
        lastRebalanceTime = block.timestamp;
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
        if (token == address(0)) revert ZeroAddress();
        if (token == address(WETH)) revert CannotAllowWeth();
        if (isAllowedToken[token]) revert TokenAlreadyAllowed();
        if (!swapRouterV4.hasV4PoolConfig(token)) revert TokenNotOnRouter();
        isAllowedToken[token] = true;
        _allowedTokens.push(token);
        _allowedTokenIndex[token] = _allowedTokens.length;
    }

    function removeAllowedToken(address token) external onlyOwner {
        if (token == address(ASSET)) revert CannotRemoveActiveAsset();
        uint256 idx = _allowedTokenIndex[token];
        if (idx == 0) revert TokenNotAllowed();
        uint256 last = _allowedTokens.length;
        if (idx != last) {
            address moved = _allowedTokens[last - 1];
            _allowedTokens[idx - 1] = moved;
            _allowedTokenIndex[moved] = idx;
        }
        _allowedTokens.pop();
        delete _allowedTokenIndex[token];
        delete isAllowedToken[token];
    }

    function allowedTokenCount() external view returns (uint256) {
        return _allowedTokens.length;
    }

    function depositWeth(uint256 amount) external override onlyOwner nonReentrant {
        if (amount == 0) revert ZeroValue();
        WETH.safeTransferFrom(_msgSender(), address(this), amount);
        _processDeposit();
    }
    function withdrawWeth(uint256 wethAmount, address receiver) external override onlyOwner nonReentrant {
        if (wethAmount == 0) revert ZeroValue();
        if (receiver == address(0)) revert ZeroAddress();
        uint256 totalValue = _totalValueWeth();
        if (totalValue == 0) revert ZeroValue();
        if (wethAmount > totalValue) wethAmount = totalValue;
        _withdrawWethNotional(wethAmount, totalValue, receiver);
    }
    function _totalValueWeth() internal view returns (uint256) {
        return balanceOfIdle() + poolValue();
    }

    /// @dev Pull pro-rata LP and return deltas vs idle balances captured before unwind.
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
    function _noteHarvestActivity() internal {
        PrevHarvestTime = lastHarvest;
        lastHarvest = block.timestamp;
    }
    uint256 private constant LIQUIDITY_DUST = 1_000_000_000_000;
    function _handleOffensiveStale() internal returns (bool) {
        if (stratMode == Mode.OFFENSIVE
                && block.timestamp - lastOffensiveTime > offensiveStaleDuration
                && consecutiveOffensiveCount == prevConsecutiveOffensiveCount + 1) {
            _decreaseAllLiquidity();
            liqPos.positionId = 0;
            stratMode = Mode.NORMAL;
            baseTokenShareBps = 5_000;
            consecutiveOffensiveCount = 0;
            prevConsecutiveOffensiveCount = 0;
            (uint256 staleAssetBal, uint256 staleWethBal) = _getTokenBalances();
            _balanceTokens(staleAssetBal, staleWethBal);
            _mintNewPosition(startM);
            _noteHarvestActivity();
            return true;
        }
        return false;
    }
    function _harvest(bool skipIncreaseLiquidity) internal  {
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
            uint128 added = _increaseLiquidityInternal();
            if (added > 0) {
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
    function _checkInRange() internal returns (bool) {
        if (_idlePaused()) return true;
        if (_inRange()) return false;
        if (liqPos.positionId == 0) {
            _enterDefensive();
            return true;
        }
        uint128 remainingLiq = _drainPositionLiquidity(6);
        if (remainingLiq != 0) return true;
        (int24 posTickUpper) = (liqPos.tickUpper);
        liqPos.positionId = 0;
        _enterOffensiveOrDefensiveByTick(posTickUpper);
        return true;
    }
    function keeperCheck() external nonReentrant returns (bool) {
        if (_idlePaused()) return true;
        bool offensiveStale = _handleOffensiveStale();
        bool floorHit = _checkTrailingPriceFloor();
        bool outOfRange = _checkInRange();
        bool tokenShareIssue = _checkTokenShare();
        return offensiveStale || floorHit || outOfRange || tokenShareIssue;
    }
    function _checkTrailingPriceFloor() internal returns (bool) {
        if (!_lpModeActive() || liqPos.positionId == 0) {
            if (liqPos.positionId == 0) {
                baselineTick = 0;
                floorTick = 0;
            }
            return false;
        }
        (, int24 poolTick) = _readSlot0();
        if (baselineTick == 0) {
            baselineTick = poolTick;
            floorTick = 0;
            return false;
        }
        if (poolTick < baselineTick) {
            baselineTick = poolTick;
            floorTick = 0;
            return false;
        }
        if (floorTick != 0 && poolTick < floorTick) {
            uint128 remainingLiq = _drainPositionLiquidity(6);
            if (remainingLiq != 0) {
                return true;
            }
            liqPos.positionId = 0;
            floorTick = 0;
            _enterDefensive();
            return true;
        }
        uint256 rallyBps = TrailingFloorLib.priceDeviationBpsAbove(baselineTick, poolTick);
        if (rallyBps < minFloorDeviationBps) {
            return false;
        }
        uint256 depthBps = TrailingFloorLib.trailingFloorDepthBps(rallyBps, floorSlopeNumerator, floorSlopeDenominator);
        if (depthBps == 0) {
            return false;
        }
        int24 rawFloor = TrailingFloorLib.floorTickBelowCurrentByBps(poolTick, depthBps);
        int24 candidate = TrailingFloorLib.alignDown(rawFloor, poolKey.tickSpacing);
        if (floorTick == 0 || candidate > floorTick && consecutiveOffensiveCount < minFloorTickCount) {
            floorTick = candidate;
        }
        return false;
    }
    function _enterDefensive() internal {
        if (liqPos.positionId != 0) revert PositionExists();
        floorTick = 0;
        consecutiveOffensiveCount = 0;
        baselineTick = 0;
        defensiveEnteredAt = block.timestamp;
        stratMode = Mode.DEFENSIVE;
        tokenShareAnchorBps = 0;
    }
    function _enterOffensiveOrDefensiveByTick(int24 posTickUpper) internal {
        (, int24 poolTick) = _readSlot0();
        if (poolTick >= posTickUpper) _enterOffensive();
        else _enterDefensive();
    }
    function _enterOffensive() internal {
        if (liqPos.positionId != 0) revert PositionExists();
        prevOffensiveTime = lastOffensiveTime;
        lastOffensiveTime = block.timestamp;
        prevConsecutiveOffensiveCount = consecutiveOffensiveCount;
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
        _mintNewPosition(offensiveM); 
        if (liqPos.positionId != 0) {
            baseTokenShareBps = offensiveTargetAssetBps;
            floorTick = 0;
            defensiveEnteredAt = 0;
            lastRebalanceTime = block.timestamp;
        } else {
            _enterDefensive();
        }
    }
    function _mintNewPosition(int24 mValue) internal {
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        if (assetBal == 0 && wethBal == 0) return;
        uint256 d = LIQUIDITY_DUST;
        LiquidityLibraryV4.MintContext memory ctx = LiquidityLibraryV4.MintContext({
            posm: positionManager,
            poolManager: poolManager,
            poolKey: poolKey,
            m: mValue,
            slippageBps: slippageBps,
            dust: d,
            hookData: _poolHookData()
        });
        (uint256 newId, uint128 liq) = liqPos.mintNewPosition(ctx, assetBal, wethBal);
        if (newId != 0 && liq > 0) {
            deposits[newId] = Deposit(address(this), liq, poolKey.currency0, poolKey.currency1);
            (, int24 poolTickAfterMint) = _readSlot0();
            baselineTick = poolTickAfterMint;
            floorTick = 0;
            (bool ok, uint256 currentBps) = _poolTokenShareBps();
            if (ok) tokenShareAnchorBps = currentBps;
        }
        _handleLeftoverTokensWithLimit(0);
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
            _mintNewPosition(startM);
        } else {
            _increaseLiquidityInternal();
            _handleLeftoverTokensWithLimit(0);
        }
    }
    function _collectAllFees(bool trackFees) internal returns (uint256 amount0, uint256 amount1, uint256 valueInWeth) {
        if (liqPos.positionId == 0) return (0, 0, 0);
        if (liqPos.getPositionLiquidity(positionManager) == 0) return (0, 0, 0);
        if (IERC721(address(positionManager)).ownerOf(liqPos.positionId) != address(this)) {
            revert Unauthorized();
        }
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
            uint256 feesWeth  = p0 == address(WETH) ? amount0 : amount1;
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
        wethBal  = WETH.balanceOf(address(this));
    }
    function _balanceTokens(uint256 assetBal, uint256 wethBal) internal {
        if (assetBal == 0 && wethBal == 0) return;
        uint256 p = _spotPrice1e18();
        if (p == 0) return;
        uint256 wethAsTokens = Math.mulDiv(wethBal, p, 1e18);
        uint256 totalValue   = assetBal + wethAsTokens;
        if (totalValue == 0) return;
        uint256 targetAssetBps = 5_000;
        if (stratMode == Mode.OFFENSIVE && offensiveTargetAssetBps != 0) {
            targetAssetBps = offensiveTargetAssetBps;
        }
        uint256 target = Math.mulDiv(totalValue, targetAssetBps, 10_000);
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
        LiquidityLibraryV4.IncreaseContext memory ctx = LiquidityLibraryV4.IncreaseContext({
            posm: positionManager,
            poolManager: poolManager,
            poolKey: poolKey,
            slippageBps: slippageBps,
            dust: LIQUIDITY_DUST,
            hookData: _poolHookData()
        });
        liqAdded = liqPos.increaseLiquidityInternal(ctx, IERC20(p0), IERC20(p1));
        if (liqAdded > 0) {
            deposits[liqPos.positionId].liquidity += liqAdded;
            (bool ok, uint256 currentBps) = _poolTokenShareBps();
            if (ok) tokenShareAnchorBps = currentBps;
        }
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
        LiquidityLibraryV4.DecreaseContext memory ctx = LiquidityLibraryV4.DecreaseContext({
            posm: positionManager,
            poolManager: poolManager,
            poolKey: poolKey,
            hookData: _poolHookData()
        });
        uint128 removed;
        uint256 positionId = liqPos.positionId; 
        if (removeAll) {
            removed = liqPos.decreaseAllLiquidity(ctx);
            deposits[positionId].liquidity = 0;
            uint128 remainingLiq = liqPos.getPositionLiquidity(positionManager);
            if (remainingLiq > 0) {
                removed = liqPos.decreaseAllLiquidity(ctx);
                deposits[positionId].liquidity = 0;
            }
        } else {
            if (liquidityToRemove == 0) return;
            removed = liqPos.decreaseLiquidityByAmount(ctx, liquidityToRemove);
            deposits[positionId].liquidity = liqPos.getPositionLiquidity(positionManager);
        }
        _collectAllFees(false);
    }
    function _handleLeftoverTokensWithLimit(uint256 iter) internal {
        if (iter >= 1) return;
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        uint256 d = LIQUIDITY_DUST;
        if (assetBal <= d && wethBal <= d) return;
        _balanceTokens(assetBal, wethBal);
        if (liqPos.positionId != 0) {
            _increaseLiquidityInternal();
            _handleLeftoverTokensWithLimit(iter + 1);
        }
    }
    function _checkTokenShare() internal returns (bool) {
        if (liqPos.positionId == 0) return false;
        if (_idlePaused()) return true;
        (bool ok, uint256 currentBps) = _poolTokenShareBps();
        if (!ok) return false;
        uint256 baseline   = tokenShareAnchorBps == 0 ? currentBps : tokenShareAnchorBps;
        DeviationBands storage bands = stratMode == Mode.OFFENSIVE ? offensiveBands : deviationBands;
        if (currentBps >= bands.maxTokenCapBps || currentBps <= bands.lowerBps) {
            _decreaseAllLiquidity();
            liqPos.positionId = 0;
            if (currentBps >= bands.maxTokenCapBps) _enterDefensive();
            else _enterOffensive();
            return true;
        }
        uint256 delta = currentBps > baseline ? (currentBps - baseline) : (baseline - currentBps);
        uint256 maxDev = currentBps > baseline ? bands.upperBps : bands.lowerBps;
        if (delta >= maxDev) {
            _decreaseAllLiquidity();
            liqPos.positionId = 0;
            if (currentBps > baseline) _enterDefensive();
            else _enterOffensive();
            return true;
        }
        return false;
    }
    function _poolTokenShareBps() internal view returns (bool ok, uint256 currentBps) {
        (uint256 assetAmt, uint256 wethAmt) = balanceOfPool();
        uint256 p = _spotPrice1e18();
        if (p == 0) return (false, 0);
        uint256 totalValue = assetAmt + Math.mulDiv(wethAmt, p, 1e18);
        if (totalValue == 0) return (false, 0);
        return (true, Math.mulDiv(assetAmt, 10_000, totalValue));
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
    function totalLiquidity() external view override returns (uint128) { return liqPos.getPositionLiquidity(positionManager); }
    function _calculateLiquidityToRemove(uint256 amount) internal view returns (uint256) {
        if (liqPos.positionId == 0) return 0;
        (int24 _tickLower, int24 _tickUpper, uint128 liquidity) = (liqPos.tickLower, liqPos.tickUpper, LiquidityLibraryV4.getPositionLiquidity(liqPos, positionManager));
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
        uint256 targetWethAmt = Math.mulDiv(wethAmt,  proportion, 1e18);
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
        uint256 pid = liqPos.positionId;
        if (pid != 0 && liqPos.getPositionLiquidity(positionManager) == 0) {
            delete deposits[pid];
            liqPos.positionId = 0;
        }
    }

    function changeAsset(address _newAssetAddr) external override onlyAuthorized {
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
            baselineTick = 0;
            floorTick = 0;
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
        baselineTick = 0;
        floorTick = 0;
        baseTokenShareBps = 5_000;
        tokenShareAnchorBps = 0;
        if (wethBal == 0 && assetBal == 0) {
            return;
        }
        _balanceTokens(assetBal, wethBal);
        _mintNewPosition(startM);
        if (liqPos.positionId != 0) {
            lastRebalanceTime = block.timestamp;
        }
    }
}
