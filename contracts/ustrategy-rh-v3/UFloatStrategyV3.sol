// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./UStrategyManager.sol";
import "./UStrategyOperatorAuth.sol";
import {IUFloatV3StrategySwapRouter} from "./interfaces/IUFloatV3StrategySwapRouter.sol";
import "./interfaces/IOutOfRangeStrategyV3.sol";
import "./interfaces/IUFloatStrategyWatched.sol";
import "./interfaces/IUFloatStrategyV3.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/IUniswapV3Factory.sol";
import "./interfaces/IUniswapV3PoolMinimal.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./libraries/TrailingFloorLib.sol";
import "./libraries/LiquidityLibraryV2.sol";
import "./V3Deployments4663.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

contract UFloatStrategyV3 is
    IUFloatStrategyV3,
    UStrategyManager,
    UStrategyOperatorAuth,
    ReentrancyGuard,
    IERC721Receiver,
    IOutOfRangeStrategyV3,
    IUFloatStrategyWatched
{
    error ZeroValue();
    error ZeroAddress();
    error PositionExists();
    error TokenNotOnRouter();
    error TokenAlreadyAllowed();
    error TokenNotAllowed();
    error CannotRemoveActiveAsset();
    error CannotAllowWeth();
    error PoolInvalid();
    error InvalidSwapToken();
    error SwapAmountTooLarge();
    error PoolPriceUnavailable();
    error StopLossReached();

    /// @notice Emitted when the strategy rotates ASSET (or exits to WETH/STABLE).
    event AssetChanged(
        address indexed oldAsset,
        address indexed newAsset,
        uint256 poolValue,
        uint64 timestamp
    );

    using SafeERC20 for IERC20;
    using LiquidityLibraryV2 for LiquidityLibraryV2.PositionState;

    address public immutable factory;
    address public feeManager;
    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Factory public immutable v3Factory;
    IERC20 private immutable WETH;
    LiquidityLibraryV2.PositionState private liqPos;
    IUniswapV3PoolMinimal private _pool;
    uint24 public poolFee;
    IUFloatV3StrategySwapRouter private swapRouter;
    mapping(address => bool) public isAllowedToken;
    address[] public allowedTokens;
    mapping(address => uint256) private _allowedTokenIndex;
    IERC20 public ASSET;
    uint256 public lastOffensiveTime;
    uint256 public lastHarvest;
    uint256 public UniswapFeesCollected;
    enum Mode { NORMAL, DEFENSIVE, OFFENSIVE, STABLE }
    Mode internal stratMode;
    uint256 public consecutiveOffensiveCount;
    uint256 public prevConsecutiveOffensiveCount;
    bool public watched;

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

    function setWatched(bool status) external onlyKeeper {
        watched = status;
    }

    function _readSlot0() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        if (address(_pool) == address(0)) {
            return (0, 0);
        }
        (sqrtPriceX96, tick,,,,,) = _pool.slot0();
    }

    function _strategyOwner() internal view override returns (address) {
        return owner();
    }

    constructor(address _factory) {
        factory = _factory;
        WETH = IERC20(V3Deployments4663.WETH);
        positionManager = INonfungiblePositionManager(V3Deployments4663.NPM);
        v3Factory = IUniswapV3Factory(V3Deployments4663.FACTORY);
    }

    function bootstrapStrategy(
        address owner_,
        address swapRouter_,
        address operatorRegistry_,
        address keeper,
        address feeManager_,
        StratMethod stratMethod_,
        address[] calldata tokens
    ) external {
        if (msg.sender != factory) revert Unauthorized();
        if (owner_ == address(0) || swapRouter_ == address(0) || feeManager_ == address(0)) revert ZeroAddress();
        if (tokens.length == 0) revert TokenNotAllowed();
        _setOperatorInfra(operatorRegistry_, keeper);
        swapRouter = IUFloatV3StrategySwapRouter(swapRouter_);
        feeManager = feeManager_;
        _initStrategyDefaults();
        stratMethod = stratMethod_;
        reserveAddress = owner_;
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            _addAllowedToken(tokens[i]);
        }
        _configureAsset(tokens[0]);
        stratMode = Mode.NORMAL;
        _transferOwnership(owner_);
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
        if (!swapRouter.hasPoolConfig(token)) revert TokenNotOnRouter();
        isAllowedToken[token] = true;
        allowedTokens.push(token);
        _allowedTokenIndex[token] = allowedTokens.length;
    }

    function _configureAsset(address assetAddr) internal {
        if (assetAddr == address(WETH)) revert CannotAllowWeth();
        if (!isAllowedToken[assetAddr]) revert TokenNotAllowed();
        if (!swapRouter.hasPoolConfig(assetAddr)) revert TokenNotOnRouter();
        ASSET = IERC20(assetAddr);
        poolFee = swapRouter.getPoolConfig(assetAddr);
        address poolAddr = v3Factory.getPool(assetAddr, address(WETH), poolFee);
        if (poolAddr == address(0)) revert PoolInvalid();
        _pool = IUniswapV3PoolMinimal(poolAddr);
        int24 spacing = _pool.tickSpacing();
        if (spacing > 0) tickSpacing = spacing;
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
        if (totalValueWeth() <= stopLoss) revert StopLossReached();
        _changeAsset(token);
    }

    function depositETH() external payable override onlyOwner nonReentrant {
        if (msg.value == 0) revert ZeroValue();
        IWETH(address(WETH)).deposit{value: msg.value}();
        _processDeposit();
    }

    function withdrawWeth(uint256 wethAmount) external override onlyOwner nonReentrant {
        if (wethAmount == 0) revert ZeroValue();
        uint256 totalValue = totalValueWeth();
        if (totalValue == 0) revert ZeroValue();
        uint256 notional = wethAmount == type(uint256).max ? totalValue : wethAmount;
        _withdrawWethNotional(notional, totalValue, _msgSender());
    }

    function totalValueWeth() public view override returns (uint256) {
        return balanceOfIdle() + poolValue();
    }

    function _unwindPoolNotional(uint256 wethNotional, uint256 totalValue)
        internal
        returns (uint256 wethFromPool, uint256 assetFromPool, uint256 idleWethBefore, uint256 idleAssetBefore)
    {
        idleAssetBefore = ASSET.balanceOf(address(this));
        idleWethBefore = WETH.balanceOf(address(this));
        if (liqPos.positionId != 0) {
            if (wethNotional >= totalValue) {
                _decreaseAllLiquidity();
                if (liqPos.positionId != 0 && liqPos.getPositionLiquidity(positionManager) == 0) {
                    liqPos.positionId = 0;
                }
            } else {
                uint256 poolVal = poolValue();
                if (poolVal > 0) {
                    uint256 amountFromPool = Math.mulDiv(poolVal, wethNotional, totalValue);
                    if (amountFromPool > 0) {
                        _decreaseLiquidity(amountFromPool);
                    }
                }
            }
        }
        uint256 assetAfter = ASSET.balanceOf(address(this));
        uint256 wethAfter = WETH.balanceOf(address(this));
        assetFromPool = assetAfter > idleAssetBefore ? assetAfter - idleAssetBefore : 0;
        wethFromPool = wethAfter > idleWethBefore ? wethAfter - idleWethBefore : 0;
    }

    function _withdrawWethNotional(uint256 wethNotional, uint256 totalValue, address receiver) internal {
        bool fullExit = wethNotional >= totalValue;
        (uint256 wethFromPool, uint256 assetFromPool, uint256 idleWethBefore, uint256 idleAssetBefore) =
            _unwindPoolNotional(wethNotional, totalValue);
        uint256 totalUserWeth;
        uint256 totalUserAsset;
        if (fullExit) {
            totalUserWeth = WETH.balanceOf(address(this));
            totalUserAsset = ASSET.balanceOf(address(this));
        } else {
            totalUserWeth = wethFromPool + Math.mulDiv(idleWethBefore, wethNotional, totalValue);
            totalUserAsset = assetFromPool + Math.mulDiv(idleAssetBefore, wethNotional, totalValue);
        }
        uint256 assetFee;
        if (stratMode != Mode.STABLE) {
            assetFee = Math.mulDiv(totalUserAsset, withdrawalFeeBps, DIVISOR);
            totalUserAsset -= assetFee;
        }
        uint256 wethFee = Math.mulDiv(totalUserWeth, withdrawalFeeBps, DIVISOR);
        totalUserWeth -= wethFee;

        if (stratMode != Mode.STABLE && totalUserAsset > 0) {
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
        if (liqPos.positionId == 0) {
            if (_idlePaused()) {
                (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
                if (assetBal > 0 || wethBal > 0) {
                    _balanceTokens(assetBal, wethBal);
                }
                return;
            }
            _deposit();
            return;
        }
        if (_lpModeActive()) {
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
        lastHarvest = block.timestamp;
    }

    function _harvest(bool skipIncreaseLiquidity) internal {
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
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        _balanceTokens(assetBal, wethBal);
        try this._execIncreaseLiquidity() returns (uint128 added) {
            if (added > 0) {
                _noteHarvestActivity();
            }
        } catch {}
    }

    function _execIncreaseLiquidity() external returns (uint128) {
        if (msg.sender != address(this)) revert Unauthorized();
        return _increaseLiquidityInternal();
    }

    function _inRange() internal view returns (bool) {
        if (liqPos.positionId == 0) return false;
        (, int24 poolTick) = _readSlot0();
        (int24 posTickLower, int24 posTickUpper) = (liqPos.tickLower, liqPos.tickUpper);
        return poolTick >= posTickLower && poolTick < posTickUpper;
    }

    function _handleOutOfRange() internal returns (bool) {
        if (liqPos.positionId == 0) return false;
        uint128 remainingLiq = _drainPositionLiquidity(6);
        if (remainingLiq != 0) return true;
        liqPos.positionId = 0;
        return _handleOorAfterDrain();
    }

    function _handleOorAfterDrain() internal returns (bool) {
        StratMethod method = stratMethod;
        if (method == StratMethod.ReBalanceOnly) {
            return _remintAtTarget();
        }
        if (method == StratMethod.OffensiveOnly) {
            _enterOffensive();
            return liqPos.positionId != 0;
        }
        if (method == StratMethod.DefensiveOnly) {
            _enterDefensive();
            return true;
        }
        return _handleOffensiveDefensiveOor();
    }

    function _remintAtTarget() internal returns (bool) {
        stratMode = Mode.NORMAL;
        consecutiveOffensiveCount = 0;
        prevConsecutiveOffensiveCount = 0;
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        if (assetBal <= LIQUIDITY_DUST && wethBal <= LIQUIDITY_DUST) return false;
        _balanceTokens(assetBal, wethBal);
        _mintAsymmetricPosition();
        if (liqPos.positionId != 0) {
            _noteHarvestActivity();
        }
        return liqPos.positionId != 0;
    }

    function _oorExitSide() internal view returns (bool exitedAbove, bool exitedBelow) {
        (int24 lower, int24 upper) = (liqPos.tickLower, liqPos.tickUpper);
        if (lower == 0 && upper == 0) return (false, false);
        (, int24 poolTick) = _readSlot0();
        exitedAbove = poolTick >= upper;
        exitedBelow = poolTick < lower;
    }

    function _assetStrengthAfterOor() internal view returns (bool assetStrong, bool assetWeak) {
        (bool exitedAbove, bool exitedBelow) = _oorExitSide();
        address weth = address(WETH);
        if (_pool.token0() == weth) {
            assetStrong = exitedBelow;
            assetWeak = exitedAbove;
        } else if (_pool.token1() == weth) {
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
        StratMethod method = stratMethod;
        if ((method == StratMethod.OffensiveOnly || method == StratMethod.OffensiveDefensive)
                && _handleOffensiveStale()) {
            return true;
        }
        if (liqPos.positionId == 0) {
            return _handleIdleNoPosition();
        }
        if (stopLoss > 0 && totalValueWeth() <= stopLoss) {
            _exitToStable();
            return true;
        }
        if (_inRange()) return true;
        return _handleOutOfRange();
    }

    function _handleIdleNoPosition() internal returns (bool) {
        Mode m = stratMode;
        if (m == Mode.STABLE) return false;
        if (m == Mode.DEFENSIVE && stratMethod != StratMethod.OffensiveOnly) return false;
        if (m != Mode.NORMAL && m != Mode.OFFENSIVE && m != Mode.DEFENSIVE) return false;
        if (liqPos.tickLower == 0 && liqPos.tickUpper == 0) return false;
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        if (assetBal <= LIQUIDITY_DUST && wethBal <= LIQUIDITY_DUST) return false;

        StratMethod method = stratMethod;
        if (method == StratMethod.ReBalanceOnly) {
            return _remintAtTarget();
        }
        if (method == StratMethod.OffensiveOnly) {
            if (m == Mode.DEFENSIVE) {
                return _remintAtTarget();
            }
            _enterOffensive();
            return liqPos.positionId != 0;
        }
        if (method == StratMethod.DefensiveOnly) {
            _enterDefensive();
            return true;
        }
        return _handleOffensiveDefensiveOor();
    }

    function _enterDefensive() internal {
        if (liqPos.positionId != 0) revert PositionExists();
        consecutiveOffensiveCount = 0;
        stratMode = Mode.DEFENSIVE;
    }

    function _offensiveFailedFallback() internal {
        if (stratMethod == StratMethod.OffensiveOnly) {
            _remintAtTarget();
        } else {
            _enterDefensive();
        }
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
            _offensiveFailedFallback();
            return;
        }
        stratMode = Mode.OFFENSIVE;
        _balanceTokens(assetBal, wethBal);
        _mintAsymmetricPosition();
        if (liqPos.positionId == 0) {
            _offensiveFailedFallback();
        }
    }

    function _asymmetricTicks(int24 currentTick) internal view returns (int24 lower, int24 upper) {
        uint256 belowTicks = _effectiveRangeBelowTicks();
        uint256 aboveTicks = rangeAboveTicks;
        if (aboveTicks == 0 || aboveTicks >= 10_000) aboveTicks = 600;
        return TrailingFloorLib.asymmetricSpacedTicks(currentTick, tickSpacing, belowTicks, aboveTicks);
    }

    function _mintAsymmetricPosition() internal {
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        if (assetBal == 0 && wethBal == 0) return;
        (, int24 currentTick) = _readSlot0();
        (int24 lower, int24 upper) = _asymmetricTicks(currentTick);
        LiquidityLibraryV2.MintContext memory ctx = LiquidityLibraryV2.MintContext({
            npm: positionManager,
            factory: v3Factory,
            pool: _pool,
            weth: address(WETH),
            tokens: address(ASSET),
            assetPoolV3: address(_pool),
            fee: poolFee,
            tickSpacing: tickSpacing,
            m: 1,
            slippageBps: slippageBps,
            dust: LIQUIDITY_DUST
        });
        (uint256 newId, uint128 liq) = liqPos.mintNewPositionWithRange(ctx, assetBal, wethBal, lower, upper);
        if (newId == 0 || liq == 0) {
            liqPos.positionId = 0;
        }
    }

    function _poolBalances(uint256 assetBal, uint256 wethBal) internal view returns (uint256 bal0, uint256 bal1) {
        address p0 = _pool.token0();
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
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: liqPos.positionId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        valueInWeth = 0;
        if (amount0 == 0 && amount1 == 0) return (0, 0, 0);
        address p0 = _pool.token0();
        address p1 = _pool.token1();
        if (trackFees) {
            uint256 gross0 = amount0;
            uint256 gross1 = amount1;
            if (protocolFeeBps > 0) {
                uint256 fee0 = Math.mulDiv(gross0, protocolFeeBps, DIVISOR);
                uint256 fee1 = Math.mulDiv(gross1, protocolFeeBps, DIVISOR);
                if (fee0 > 0) IERC20(p0).safeTransfer(feeManager, fee0);
                if (fee1 > 0) IERC20(p1).safeTransfer(feeManager, fee1);
                amount0 -= fee0;
                amount1 -= fee1;
            }
            if (feeReserveBps > 0) {
                address to = reserveAddress;
                if (to != address(0)) {
                    uint256 ext0 = Math.mulDiv(gross0, feeReserveBps, DIVISOR);
                    uint256 ext1 = Math.mulDiv(gross1, feeReserveBps, DIVISOR);
                    if (ext0 > 0) IERC20(p0).safeTransfer(to, ext0);
                    if (ext1 > 0) IERC20(p1).safeTransfer(to, ext1);
                    amount0 -= ext0;
                    amount1 -= ext1;
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
            UniswapFeesCollected += valueInWeth;
        }
    }

    function _spotPrice1e18() internal view returns (uint256) {
        (uint160 sqrtP, ) = _readSlot0();
        address p0 = _pool.token0();
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

    function _effectiveRangeBelowTicks() internal view returns (uint256) {
        uint256 base = rangeBelowTicks;
        if (base == 0 || base >= 10_000) base = 400;
        int24 spacing = tickSpacing;
        if (consecutiveOffensiveCount < minFloorTickCount) {
            return TrailingFloorLib.alignTicksDownToSpacing(base, spacing);
        }

        uint256 count = consecutiveOffensiveCount;
        uint256 steps = count - minFloorTickCount + 1;
        uint256 effective = base;
        uint256 sp = uint256(uint24(spacing > 0 ? spacing : int24(200)));
        uint256 floorTicks = minRangeBelowTicks != 0 ? minRangeBelowTicks : sp;
        if (floorTicks < sp) floorTicks = sp;
        for (uint256 i = 0; i < steps; i++) {
            effective = effective * RATCHET_NUMERATOR / RATCHET_DENOMINATOR;
            if (effective < floorTicks) {
                return TrailingFloorLib.alignTicksDownToSpacing(floorTicks, spacing);
            }
        }
        return TrailingFloorLib.alignTicksDownToSpacing(effective, spacing);
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
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        (uint256 amount0, uint256 amount1) = _poolBalances(assetBal, wethBal);
        LiquidityLibraryV2.IncreaseContext memory ctx = LiquidityLibraryV2.IncreaseContext({
            npm: positionManager,
            pool: _pool,
            fee: poolFee,
            slippageBps: slippageBps,
            dust: LIQUIDITY_DUST
        });
        return liqPos.increaseLiquidityInternal(ctx, IERC20(_pool.token0()), IERC20(_pool.token1()), amount0, amount1);
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
        LiquidityLibraryV2.DecreaseContext memory ctx =
            LiquidityLibraryV2.DecreaseContext({npm: positionManager, pool: _pool});
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
        address tokenInAddr = address(tokenIn);
        if (tokenInAddr != address(ASSET) && tokenInAddr != address(WETH)) {
            revert InvalidSwapToken();
        }
        if (amount > type(uint128).max) revert SwapAmountTooLarge();
        address tokenOut = tokenInAddr == address(WETH) ? address(ASSET) : address(WETH);
        swapRouter.swapExactInputSingleStrict(tokenInAddr, tokenOut, poolFee, uint128(amount));
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
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = LiquidityLibraryV2.getSqrtRatios(liqPos.tickLower, liqPos.tickUpper);
        (uint256 amount0, uint256 amount1) =
            LiquidityLibraryV2.getAmountsForLiquidity(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, liquidity);
        address p0 = _pool.token0();
        return p0 == address(WETH) ? (amount1, amount0) : (amount0, amount1);
    }

    function _calculateLiquidityToRemove(uint256 amount) internal view returns (uint256) {
        if (liqPos.positionId == 0) return 0;
        (int24 _tickLower, int24 _tickUpper, uint128 liquidity) =
            (liqPos.tickLower, liqPos.tickUpper, LiquidityLibraryV2.getPositionLiquidity(liqPos, positionManager));
        (uint160 sqrtP, ) = _readSlot0();
        uint128 positionLiquidity = liqPos.getPositionLiquidity(positionManager);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = LiquidityLibraryV2.getSqrtRatios(_tickLower, _tickUpper);
        (uint256 amount0, uint256 amount1) =
            LiquidityLibraryV2.getAmountsForLiquidity(sqrtP, sqrtLowerX96, sqrtUpperX96, positionLiquidity);
        address p0 = _pool.token0();
        (uint256 assetAmt, uint256 wethAmt) = p0 == address(WETH) ? (amount1, amount0) : (amount0, amount1);
        uint256 p = _spotPrice1e18();
        uint256 assetAsWeth = p != 0 ? Math.mulDiv(assetAmt, 1e18, p) : 0;
        uint256 totalValue = wethAmt + assetAsWeth;
        if (totalValue == 0 || liquidity == 0) return 0;
        uint256 proportion = Math.mulDiv(amount, 1e18, totalValue);
        uint256 targetTokenAmt = Math.mulDiv(assetAmt, proportion, 1e18);
        uint256 targetWethAmt = Math.mulDiv(wethAmt, proportion, 1e18);
        (uint256 bal0, uint256 bal1) = p0 == address(WETH) ? (targetWethAmt, targetTokenAmt) : (targetTokenAmt, targetWethAmt);
        uint128 liqNeeded = LiquidityLibraryV2.getLiquidityForAmounts(sqrtP, sqrtLowerX96, sqrtUpperX96, bal0, bal1);
        if (liqNeeded > liquidity) return liquidity;
        return liqNeeded;
    }

    function getPositionId() external view override returns (uint256) {
        return liqPos.positionId;
    }

    function _giveAllowances() internal {
        address npm = address(positionManager);
        address router = address(swapRouter);
        if (address(ASSET) != address(0)) {
            ASSET.forceApprove(npm, type(uint256).max);
            ASSET.forceApprove(router, type(uint256).max);
        }
        WETH.forceApprove(npm, type(uint256).max);
        WETH.forceApprove(router, type(uint256).max);
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

    function exitToStable() public onlyOperatorOrOwner {
        _exitToStable();
    }

    function _exitToStable() internal {
        _changeAsset(address(WETH));
    }

    function _changeAsset(address _newAssetAddr) internal {
        if (_newAssetAddr == address(0)) revert ZeroAddress();
        address oldAsset = address(ASSET);
        address w = address(WETH);
        if (_newAssetAddr == w) {
            consecutiveOffensiveCount = 0;
            _flattenAllAndClearPosition();
            if (oldAsset != w) {
                uint256 oldAssetBal = ASSET.balanceOf(address(this));
                if (oldAssetBal > 0) _swap(ASSET, oldAssetBal);
            }
            stratMode = Mode.STABLE;
            emit AssetChanged(oldAsset, _newAssetAddr, totalValueWeth(), uint64(block.timestamp));
            return;
        }
        if (!isAllowedToken[_newAssetAddr]) revert TokenNotAllowed();
        consecutiveOffensiveCount = 0;
        _flattenAllAndClearPosition();
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        if (assetBal > 0 && oldAsset != w) {
            _swap(ASSET, assetBal);
        }
        _configureAsset(_newAssetAddr);
        (assetBal, wethBal) = _getTokenBalances();
        stratMode = Mode.NORMAL;
        if (wethBal != 0 || assetBal != 0) {
            _balanceTokens(assetBal, wethBal);
            _mintAsymmetricPosition();
        }
        emit AssetChanged(oldAsset, _newAssetAddr, totalValueWeth(), uint64(block.timestamp));
    }

    receive() external payable {
        revert("use depositETH");
    }
}
