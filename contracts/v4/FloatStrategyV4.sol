// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../interfaces/IPositionManagerV4.sol";
import "../../interfaces/IPoolManagerV4.sol";
import "./StrategyManagerV4.sol";
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
import "../../libraries/LiquidityLibraryV4.sol";
import "../../interfaces/IAllowanceTransfer.sol";


contract FloatStrategyV4 is IFloatStrategyV4, StrategyManagerV4, ReentrancyGuard, IERC721Receiver, IOutOfRangeStrategyV4 {
    error Unauthorized();
    error ZeroValue();
    error ZeroAddress();
    error PositionExists();
    error MustBeNeutral();
    using SafeERC20 for IERC20;
    using LiquidityLibraryV4 for LiquidityLibraryV4.PositionState;
    IPositionManagerV4 public immutable positionManager;
    LiquidityLibraryV4.PositionState private liqPos;
    IPoolManagerV4 private poolManager;
    LiquidityLibraryV4.PoolKey public poolKey;
    IV4StrategySwapRouterStrict private swapRouterV4;
    address public managerAddress;
    /// @dev `public` so external callers replace the previous `assetAddr` getter via `address(ASSET)`.
    IERC20 public ASSET;
    IERC20 private WETH;
    address private vaultAddr;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private demeterAddr;
    address private keeperStratAddr;
    int24 public baselineTick;
    int24 public floorTick;
    bool public harvestOnDeposit = true;
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
    enum Mode { NORMAL, DEFENSIVE, OFFENSIVE, NEUTRAL, STABLE }
    Mode internal stratMode;
    uint256 public lastRebalanceTime;
    uint256 public defensiveEnteredAt;
    uint256 public consecutiveOffensiveCount;
    uint256 public prevConsecutiveOffensiveCount;
    function _lpModeActive() internal view returns (bool) {
        return stratMode == Mode.NORMAL || stratMode == Mode.OFFENSIVE;
    }
    function tickRange() external view returns (int24 lower, int24 upper) {
        return (liqPos.tickLower, liqPos.tickUpper);
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
    modifier onlyAuthorized() {
        address s = _msgSender();
        if (s != vaultAddr && s != demeterAddr && s != keeperStratAddr && s != managerAddress && s != owner()) revert Unauthorized();
        _;
    }
    /// @dev All wiring (asset / pool / managers / approvals) happens here — there is no separate
    ///      `setUpContract` step. Saves ~bytecode by moving SSTOREs / struct-literal logic into
    ///      init code (which doesn't count toward EIP-170). Trade-off: every dependency address must
    ///      be known at deploy time; re-wiring requires redeploy.
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
        address _keeperStrategyAddr
    ) StrategyManagerV4() {
        if (weth_ == address(0) || positionManager_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        WETH = IERC20(weth_);
        positionManager = IPositionManagerV4(positionManager_);
        poolManager = IPoolManagerV4(poolManager_);
        deviationBands = StrategyManagerV4.DeviationBands({lowerBps: 200, upperBps: 2400, maxTokenCapBps: 9800});
        offensiveBands = StrategyManagerV4.DeviationBands({lowerBps: 200, upperBps: 2400, maxTokenCapBps: 9800});

        managerAddress = _managerAddr;
        vaultAddr = _vaultAddr;
        demeterAddr = _demeterAddr;
        keeperStratAddr = _keeperStrategyAddr;
        swapRouterV4 = IV4StrategySwapRouterStrict(_swapRouterAddr);
        ASSET = IERC20(_assetAddr);
        _setPoolKey(LiquidityLibraryV4.PoolKey({
            currency0: _assetAddr < weth_ ? _assetAddr : weth_,
            currency1: _assetAddr < weth_ ? weth_ : _assetAddr,
            fee: _poolFeePips,
            tickSpacing: _tickSpacing,
            hooks: _hooks
        }));
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
    function beforeDeposit() external override onlyAuthorized {
        if (harvestOnDeposit) {
            try this.harvestBoolean(true) returns (uint256) {
            } catch {
            }
        }
    }
    function deposit(uint256 amount) external override onlyAuthorized  nonReentrant {
        if (amount == 0) revert ZeroValue();
        if (liqPos.positionId == 0) {
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
            (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
            if (assetBal > 0 || wethBal > 0) {
                _balanceTokens(assetBal, wethBal);
            }
            return;
        }
    }
    function withdraw(uint256 userShares, uint256 totalSupply_, address receiver) external override onlyAuthorized nonReentrant {
        if (userShares == 0) revert ZeroValue();
        if (totalSupply_ == 0) revert ZeroValue();
        if (receiver == address(0)) revert ZeroAddress();
        // Block-scoped locals so the compiler can release stack slots before the final transfers
        // (otherwise `_swap`'s inlined `_liquidityDust()` lookup pushes us past stack-depth 16).
        uint256 totalUserAsset;
        uint256 totalUserWeth;
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
            totalUserWeth  = wethFromPool  + Math.mulDiv(idleWethBefore,  userShares, totalSupply_);
        }
        uint256 assetFee = Math.mulDiv(totalUserAsset, withdrawalFeeBps, DIVISOR);
        uint256 wethFee  = Math.mulDiv(totalUserWeth,  withdrawalFeeBps, DIVISOR);
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
        if (msg.sender != address(this)) {
            address s = _msgSender();
            if (s != vaultAddr && s != demeterAddr && s != keeperStratAddr && s != managerAddress && s != owner()) {
                revert Unauthorized();
            }
        }
        _harvest(skipIncreaseLiquidity);
        return poolValue();
    }
    function _noteHarvestActivity() internal {
        PrevHarvestTime = lastHarvest;
        lastHarvest = block.timestamp;
    }
    function _liquidityDust() private view returns (uint256) {
        return address(ASSET) == 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 ? 1_000_000 : 1_000_000_000_000;
    }
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
        if (stratMode == Mode.DEFENSIVE || stratMode == Mode.NEUTRAL) {
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
    function readInRange() external view override returns (bool) {
        return _inRange();
    }
    function _checkInRange() internal returns (bool) {
        if (stratMode == Mode.DEFENSIVE || stratMode == Mode.NEUTRAL) return true;
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
        if (stratMode == Mode.DEFENSIVE || stratMode == Mode.NEUTRAL) return true;
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
        uint256 d = _liquidityDust();
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
        if (liqPos.positionId != 0 && (stratMode == Mode.DEFENSIVE || stratMode == Mode.NEUTRAL)) {
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
        // v4-core's `Position.update` reverts with `CannotUpdateEmptyPosition` if the zero-liquidity fee-snapshot
        // trick (`modifyLiquidities` with `liquidityDelta = 0`) is called on a position whose on-chain liquidity
        // is already 0 (e.g. drained but `positionId` not yet cleared). Match v3 `NPM.collect`'s benign no-op.
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
            dust: _liquidityDust(),
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
        uint256 d = _liquidityDust();
        if (assetBal <= d && wethBal <= d) return;
        _balanceTokens(assetBal, wethBal);
        if (liqPos.positionId != 0) {
            _increaseLiquidityInternal();
            _handleLeftoverTokensWithLimit(iter + 1);
        }
    }
    function _checkTokenShare() internal returns (bool) {
        if (liqPos.positionId == 0) return false;
        if (stratMode == Mode.DEFENSIVE || stratMode == Mode.NEUTRAL) return true;
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
        // Forfeit dust: v4 strict path enforces minOut > 0, and the quoter rounds tiny swaps
        // (e.g. a few wei of an 18-dec token) to 0 output via tick/fee math. Without this guard,
        // a stray wei left in the OLD asset would block every `changeAsset` with `quoter=0`.
        if (amount <= _liquidityDust()) return;
        require(
            address(tokenIn) == poolKey.currency0 || address(tokenIn) == poolKey.currency1,
            "!"
        );
        require(amount <= type(uint128).max, ">");
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
    function setGiveAllowances() external onlyAuthorized {
        _giveAllowances();
    }
    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyAuthorized {
        harvestOnDeposit = _harvestOnDeposit;
    }
    function getPositionId() external view override returns (uint256) {
        return liqPos.positionId;
    }
    /// @dev Max-approve `token` to the swap router (ERC20) and to PERMIT2 (ERC20 + AllowanceTransfer for `pm`).
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
    function changeAsset(address _newAssetAddr, LiquidityLibraryV4.PoolKey calldata key)
        external
        override
        onlyAuthorized
    {
        if (_newAssetAddr == address(0)) revert ZeroAddress();
        address w = address(WETH);
        require(key.currency0 < key.currency1, ">=");
        require(
            (key.currency0 == _newAssetAddr && key.currency1 == w) ||
            (key.currency1 == _newAssetAddr && key.currency0 == w),
            "!="
        );
        consecutiveOffensiveCount = 0;
        _decreaseAllLiquidity();
        uint256 oldPositionId = liqPos.positionId;
        if (oldPositionId != 0 && liqPos.getPositionLiquidity(positionManager) == 0) {
            delete deposits[oldPositionId];
            liqPos.positionId = 0;
        }
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        if (assetBal > 0) _swap(ASSET, assetBal);
        ASSET = IERC20(_newAssetAddr);
        _setPoolKey(key);
        _giveAllowances();
        (assetBal, wethBal) = _getTokenBalances();
        if (_newAssetAddr == 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) {
            stratMode = Mode.STABLE;
        } else {
            stratMode = Mode.NORMAL;
        }
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
    function enterNeutralFromVault() external onlyAuthorized {
        stratMode = Mode.NEUTRAL;
        defensiveEnteredAt = block.timestamp;
        consecutiveOffensiveCount = 0;
        floorTick = 0;
        baselineTick = 0;
    }
    function resumeNormalFromVault() external onlyAuthorized {
        if (stratMode != Mode.NEUTRAL) revert MustBeNeutral();
        stratMode = Mode.NORMAL;
        baseTokenShareBps = 5_000;
        defensiveEnteredAt = 0;
        lastRebalanceTime = block.timestamp;
    }
  function rescueToken(address _token, address _recipient) external onlyOwner {

    require(_token != address(0), "Invalid token address");
    require(_recipient != address(0), "Invalid recipient address");
    
    uint256 amount = IERC20(_token).balanceOf(address(this));
    require(amount > 0, "No tokens to rescue");
    
    IERC20(_token).safeTransfer(_recipient, amount);
  }
}
