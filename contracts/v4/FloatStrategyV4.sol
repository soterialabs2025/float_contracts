// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../interfaces/IPositionManagerV4.sol";
import "../../interfaces/IPoolManagerV4.sol";
import "../StrategyManager.sol";
import "./interfaces/IFloatV4StrategySwapRouter.sol";
import "../../interfaces/IOutOfRangeStrategy.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../../libraries/LiquidityLibrary.sol";
import "../../libraries/LiquidityLibraryV4.sol";
import "../../interfaces/IFloatStrategy.sol";
import {PoolKey as CorePoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract FloatStrategyV4 is IFloatStrategy, StrategyManager, ReentrancyGuard, IERC721Receiver, IOutOfRangeStrategy {         
    error Unauthorized();
    error ZeroValue();
    error ZeroAddress();
    error InvalidManager();
    error PositionExists();
    error MustBeNeutral();
    using SafeERC20 for IERC20;
    using LiquidityLibraryV4 for LiquidityLibraryV4.PositionState;
    IPositionManagerV4 public immutable positionManager;
    LiquidityLibraryV4.PositionState private liqPos;
    IPoolManagerV4 private poolManager;
    LiquidityLibraryV4.PoolKey public poolKey;
    IFloatV4StrategySwapRouter private swapRouterV4;
    address public managerAddress;
    IERC20 private ASSET;
    IERC20 private WETH;
    address private vaultAddr;
    address private swapRouterAddr; 
    address public assetAddr;
    address private demeterAddr;
    address private keeperStratAddr;
    int24 public baselineTick;
    int24 public floorTick;
    bool public harvestOnDeposit = true;
    uint256 public lastHarvest; 
    uint256 public PrevHarvestTime;
    uint256 public baseTokenShareBps; 
    uint256 public UniswapFeesCollected; 
    uint256 public lastUniswapFeeTotal;
    struct Deposit {address owner; uint128 liquidity; address token0; address token1;}
    mapping(uint256 => Deposit) public deposits;
    enum Mode { NORMAL, DEFENSIVE, OFFENSIVE, NUETRAL }
    Mode internal stratMode;
    uint256 public lastRebalanceTime;
    uint256 public defensiveEnteredAt;
    uint256 public consecutiveOffensiveCount;
    event StrategyEvent(uint8 indexed eventType, uint256 indexed data1, uint256 data2, uint256 data3);
    event ContractSetUp(address indexed caller);
    bool public contractSetUp;
    function _lpModeActive() internal view returns (bool) {
        return stratMode == Mode.NORMAL || stratMode == Mode.OFFENSIVE;
    }
    function tickRange() external view returns (int24 lower, int24 upper) {
        return (liqPos.tickLower, liqPos.tickUpper);
    }

    /// @inheritdoc IOutOfRangeStrategy
    function mode() external view override returns (uint8) {
        return uint8(uint256(stratMode));
    }

    function _readSlot0() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick) = LiquidityLibraryV4.getSlot0(poolManager, poolKey);
    }

    function _toCorePoolKey() internal view returns (CorePoolKey memory k) {
        k = CorePoolKey({
            currency0: Currency.wrap(poolKey.currency0),
            currency1: Currency.wrap(poolKey.currency1),
            fee: poolKey.fee,
            tickSpacing: poolKey.tickSpacing,
            hooks: IHooks(poolKey.hooks)
        });
    }

    modifier onlyAuthorized() {
        address s = _msgSender();
        if (s != vaultAddr && s != demeterAddr && s != keeperStratAddr && s != managerAddress && s != owner()) revert Unauthorized();
        _;
    }
    constructor(address weth_, address positionManager_, address poolManager_) StrategyManager() {
        if (weth_ == address(0) || positionManager_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        WETH = IERC20(weth_);
        positionManager = IPositionManagerV4(positionManager_);
        poolManager = IPoolManagerV4(poolManager_);
        deviationBands = StrategyManager.DeviationBands({lowerBps: 400, upperBps: 2600, maxTokenCapBps: 9600});
        emit StrategyEvent(0, uint256(uint160(_msgSender())), 0, 0);
    }
    function setUpContract(address _assetAddr, address _assetPoolV3Addr, address _managerAddr, address _swapRouterAddr, address _vaultAddr, address _demeterAddr, address _keeperStrategyAddr) external onlyOwner {
        managerAddress = _managerAddr;
        assetAddr = _assetAddr;
        swapRouterAddr = _swapRouterAddr;
        vaultAddr = _vaultAddr;
        demeterAddr = _demeterAddr;
        keeperStratAddr = _keeperStrategyAddr;
        swapRouterV4 = IFloatV4StrategySwapRouter(_swapRouterAddr);
        ASSET = IERC20(assetAddr);
        address a = address(ASSET);
        address w = address(WETH);
        poolKey = LiquidityLibraryV4.PoolKey({
            currency0: a < w ? a : w,
            currency1: a < w ? w : a,
            fee: v3Fee,
            tickSpacing: tickSpacing,
            hooks: address(0)
        });
        _giveAllowances();
        contractSetUp = true;
        lastRebalanceTime = block.timestamp;
        emit ContractSetUp(_msgSender());
        (_assetPoolV3Addr);
    }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
    function beforeDeposit() external override onlyAuthorized  {
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
        if (stratMode == Mode.DEFENSIVE || stratMode == Mode.NUETRAL) {
            (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
            if (assetBal > 0 || wethBal > 0) {
                _balanceTokens(assetBal, wethBal);
            }
            emit StrategyEvent(1, poolValue(), 0, 0);
            return;
        }
    }
    function withdraw(uint256 userShares, uint256 totalSupply_, address receiver) external override onlyAuthorized nonReentrant {
        if (userShares == 0) revert ZeroValue();
        if (totalSupply_ == 0) revert ZeroValue();
        if (receiver == address(0)) revert ZeroAddress();
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
        uint256 wethFromPool = wethAfter > idleWethBefore ? wethAfter - idleWethBefore : 0;
        uint256 userIdleAsset = Math.mulDiv(idleAssetBefore, userShares, totalSupply_);
        uint256 userIdleWeth  = Math.mulDiv(idleWethBefore,  userShares, totalSupply_);
        uint256 totalUserAsset = assetFromPool + userIdleAsset;
        uint256 totalUserWeth  = wethFromPool  + userIdleWeth;
        uint256 assetFee = Math.mulDiv(totalUserAsset, withdrawalFeeBps, DIVISOR);
        uint256 wethFee  = Math.mulDiv(totalUserWeth,  withdrawalFeeBps, DIVISOR);
        totalUserAsset -= assetFee;
        totalUserWeth -= wethFee;
        uint256 wethBeforeSwap = WETH.balanceOf(address(this));
        _swap(ASSET, WETH, totalUserAsset);
        uint256 wethFromAsset = WETH.balanceOf(address(this)) - wethBeforeSwap;
        totalUserWeth += wethFromAsset;
        if (assetFee > 0) {
            ASSET.safeTransfer(owner(), assetFee);
        }
        if (wethFee > 0) {
            WETH.safeTransfer(owner(), wethFee);
        }
        WETH.safeTransfer(receiver, totalUserWeth);
        emit StrategyEvent(2, poolValue(), 0, 0);
    }
    function harvestBoolean(bool skipIncreaseLiquidity) external onlyAuthorized nonReentrant returns (uint256 newAssets) {
        _harvest(skipIncreaseLiquidity);
        return poolValue();
    }
    function _noteHarvestActivity() internal {
        PrevHarvestTime = lastHarvest;
        lastHarvest = block.timestamp;
    }
    function _harvest(bool skipIncreaseLiquidity) internal  {
        if (minHarvestDelay > 0 && lastHarvest != 0 && block.timestamp - lastHarvest < minHarvestDelay) {
            return;
        }
        if (stratMode == Mode.DEFENSIVE || stratMode == Mode.NUETRAL) {
            if (liqPos.positionId != 0) {
                uint256 beforeValDefensive = balanceOfIdle();
                (, , uint256 valueInWethDefensive) = _collectAllFees(true);
                if (valueInWethDefensive > 0) {
                    emit StrategyEvent(7, liqPos.positionId, valueInWethDefensive, 0);
                }
                uint256 afterValDefensive = balanceOfIdle();
                uint256 wantHarvestedDefensive = afterValDefensive > beforeValDefensive ? (afterValDefensive - beforeValDefensive) : 0;
                emit StrategyEvent(3, uint256(uint160(_msgSender())), wantHarvestedDefensive, poolValue());
            }
            return;
        }
        if (liqPos.positionId == 0) {
            return;
        }
        uint256 beforeVal = balanceOfIdle();
        (, , uint256 valueInWeth) = _collectAllFees(true);
        if (valueInWeth == 0) {
            return;
        }
        emit StrategyEvent(7, liqPos.positionId, valueInWeth, 0);
        if (!skipIncreaseLiquidity && _lpModeActive()) {
            (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
            _balanceTokens(assetBal, wethBal);
            uint128 added = _increaseLiquidityInternal();
            if (added > 0) {
                _noteHarvestActivity();
            }
        }
        uint256 afterVal      = balanceOfIdle();
        uint256 wantHarvested = afterVal > beforeVal ? (afterVal - beforeVal) : 0;
        emit StrategyEvent(3, uint256(uint160(_msgSender())), wantHarvested, poolValue());
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
        if (stratMode == Mode.DEFENSIVE || stratMode == Mode.NUETRAL) return true;
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
        if (stratMode == Mode.DEFENSIVE || stratMode == Mode.NUETRAL) return true;
        bool floorHit = _checkTrailingPriceFloor();
        bool outOfRange = _checkInRange();
        bool tokenShareIssue = _checkTokenShare();
        return floorHit || outOfRange || tokenShareIssue;
    }
    function _checkTrailingPriceFloor() internal returns (bool) {
        if (!_lpModeActive() || liqPos.positionId == 0) {
            if (liqPos.positionId == 0) {
                baselineTick = 0;
                floorTick = 0;
            }
            return false;
        }
        if (minFloorDeviationBps == 0) {
            floorTick = 0;
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
        uint256 rallyBps = LiquidityLibrary.priceDeviationBpsAbove(baselineTick, poolTick);
        if (rallyBps < minFloorDeviationBps) {
            return false;
        }
        uint256 depthBps = LiquidityLibrary.trailingFloorDepthBps(rallyBps, floorSlopeNumerator, floorSlopeDenominator);
        if (depthBps == 0) {
            return false;
        }
        int24 rawFloor = LiquidityLibrary.floorTickBelowCurrentByBps(poolTick, depthBps);
        int24 candidate = LiquidityLibrary.alignDown(rawFloor, tickSpacing);
        // High-water mark: floor only ratchets up as price rallies, never drops.
        if (floorTick == 0 || candidate > floorTick) {
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
    }
    function _enterOffensiveOrDefensiveByTick(int24 posTickUpper) internal {
        (, int24 poolTick) = _readSlot0();
        if (poolTick >= posTickUpper) _enterOffensive();
        else _enterDefensive();
    }
    function _enterOffensive() internal {
        if (liqPos.positionId != 0) revert PositionExists();
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
        _mintNewPosition(startM);
        if (liqPos.positionId != 0) {
            baseTokenShareBps = offensiveTargetAssetBps;
            floorTick = 0;
            defensiveEnteredAt = 0;
            lastRebalanceTime = block.timestamp;
            emit StrategyEvent(11, liqPos.positionId, offensiveTargetAssetBps, 0);
        } else {
            _enterDefensive();
        }
    }
    function _mintNewPosition(int24 mValue) internal {
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        if (assetBal == 0 && wethBal == 0) return;
        LiquidityLibraryV4.MintContext memory ctx = LiquidityLibraryV4.MintContext({
            posm: positionManager,
            poolManager: poolManager,
            poolKey: poolKey,
            m: mValue,
            slippageBps: slippageBps,
            dust: 1_000_000_000_000
        });
        (uint256 newId, uint128 liq) = liqPos.mintNewPosition(ctx, assetBal, wethBal);
        if (newId != 0 && liq > 0) {
            deposits[newId] = Deposit(address(this), liq, poolKey.currency0, poolKey.currency1);
            emit StrategyEvent(4, newId, uint256(uint32(int32(liqPos.tickLower))), uint256(uint32(int32(liqPos.tickUpper))));
            (, int24 poolTickAfterMint) = _readSlot0();
            baselineTick = poolTickAfterMint;
            floorTick = 0;
            (uint256 assetAmt, uint256 wethAmt) = balanceOfPool();
            uint256 p = _spotPrice1e18();
            if (p != 0) {
                uint256 wethAsTokens = Math.mulDiv(wethAmt, p, 1e18);
                uint256 totalValue = assetAmt + wethAsTokens;
                if (totalValue != 0) {
                    baseTokenShareBps = Math.mulDiv(assetAmt, 10_000, totalValue);
                }
            }
        }
        _handleLeftoverTokensWithLimit(0);
    }

    function _deposit() internal {
        if (liqPos.positionId != 0 && (stratMode == Mode.DEFENSIVE || stratMode == Mode.NUETRAL)) {
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
        emit StrategyEvent(1, poolValue(), 0, 0);
    }
    function _collectAllFees(bool trackFees) internal returns (uint256 amount0, uint256 amount1, uint256 valueInWeth) {
        if (liqPos.positionId == 0) return (0, 0, 0);
        if (IERC721(address(positionManager)).ownerOf(liqPos.positionId) != address(this)) {
            revert Unauthorized();
        }
        LiquidityLibraryV4.DecreaseContext memory dctx = LiquidityLibraryV4.DecreaseContext({
            posm: positionManager,
            poolManager: poolManager,
            poolKey: poolKey
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
            emit StrategyEvent(8, liqPos.positionId, valueInWeth, 0);
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
            if (toSell > 0) _swap(ASSET, WETH, toSell);
        } else if (assetBal < target) {
            uint256 deficit    = target - assetBal;
            uint256 wethToSell = Math.mulDiv(deficit, 1e18, p);
            if (wethToSell > wethBal) wethToSell = wethBal;
            if (wethToSell > 0) _swap(WETH, ASSET, wethToSell);
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
            dust: 1_000_000_000_000
        });
        liqAdded = liqPos.increaseLiquidityInternal(ctx, IERC20(p0), IERC20(p1));
        if (liqAdded > 0) {
            deposits[liqPos.positionId].liquidity += liqAdded;
            (uint256 assetAmt, uint256 wethAmt) = balanceOfPool();
            uint256 p = _spotPrice1e18();
            if (p != 0) {
                uint256 wethAsTokens = Math.mulDiv(wethAmt, p, 1e18);
                uint256 totalValue = assetAmt + wethAsTokens;
                if (totalValue != 0) {
                    baseTokenShareBps = Math.mulDiv(assetAmt, 10_000, totalValue);
                }
            }
            emit StrategyEvent(5, liqPos.positionId, liqAdded, 0);
        }
        return liqAdded;
    }
    function _decreaseAllLiquidity() internal {
        if (liqPos.positionId != 0) {
            (, , uint256 valueInWeth) = _collectAllFees(true);
            if (valueInWeth > 0) {
                emit StrategyEvent(7, liqPos.positionId, valueInWeth, 0);
            }
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
            poolKey: poolKey
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
        emit StrategyEvent(6, positionId, removed, 0);
    }
    function _handleLeftoverTokensWithLimit(uint256 iter) internal {
        if (iter >= 1) return;
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        if (assetBal <= 1_000_000_000_000 && wethBal <= 1_000_000_000_000) return;
        _balanceTokens(assetBal, wethBal);
        if (liqPos.positionId != 0) {
            _increaseLiquidityInternal();
            _handleLeftoverTokensWithLimit(iter + 1);
        }
    }
    function _checkTokenShare() internal returns (bool) {
        if (liqPos.positionId == 0) return false;
        if (stratMode == Mode.DEFENSIVE || stratMode == Mode.NUETRAL) return true;
        (uint256 assetAmt, uint256 wethAmt) = balanceOfPool();
        uint256 p = _spotPrice1e18();
        if (p == 0) return false;
        uint256 wethAsTokens = Math.mulDiv(wethAmt, p, 1e18);
        uint256 totalValue   = assetAmt + wethAsTokens;
        if (totalValue == 0) return false;
        uint256 currentBps = Math.mulDiv(assetAmt, 10_000, totalValue);
        uint256 baseline   = baseTokenShareBps == 0 ? currentBps : baseTokenShareBps;
        if (currentBps >= deviationBands.maxTokenCapBps || currentBps <= deviationBands.lowerBps) {
            _decreaseAllLiquidity();
            liqPos.positionId = 0;
            if (currentBps >= deviationBands.maxTokenCapBps) _enterDefensive();
            else _enterOffensive();
            return true;
        }
        uint256 delta = currentBps > baseline ? (currentBps - baseline) : (baseline - currentBps);
        uint256 maxDev = currentBps > baseline ? deviationBands.upperBps : deviationBands.lowerBps;
        if (delta >= maxDev) {
            _decreaseAllLiquidity();
            liqPos.positionId = 0;
            if (currentBps > baseline) _enterDefensive();
            else _enterOffensive();
            return true;
        }
        return false;
    }
    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amount) internal {
        if (amount == 0) return;
        uint256 bal = tokenIn.balanceOf(address(this));
        if (amount > bal) amount = bal;
        if (amount == 0) return;
        swapRouterV4.swapExactInputSingleFromStrategy(_toCorePoolKey(), address(tokenIn) == poolKey.currency0, amount, 0);
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
    /// @dev Uses `forceApprove` so tokens that require allowance 0 before a new non-zero value (e.g. USDT-style) do not revert.
    function _giveAllowances() internal {
        if (address(ASSET) != address(0)) {
            ASSET.forceApprove(address(positionManager), type(uint256).max);
            ASSET.forceApprove(address(swapRouterV4), type(uint256).max);
        }
        WETH.forceApprove(address(positionManager), type(uint256).max);
        WETH.forceApprove(address(swapRouterV4), type(uint256).max);
    }
    function _removeAllowances() internal {
        if (address(ASSET) != address(0)) {
            ASSET.forceApprove(address(positionManager), 0);
            ASSET.forceApprove(address(swapRouterV4), 0);
        }
        WETH.forceApprove(address(positionManager), 0);
        WETH.forceApprove(address(swapRouterV4), 0);
    }
    function changeAsset(address _newAssetAddr, address _newPoolV3Addr) external override onlyAuthorized {
        if (_newAssetAddr == address(0)) revert ZeroAddress();
        consecutiveOffensiveCount = 0;
        _decreaseAllLiquidity();
        uint256 oldPositionId = liqPos.positionId;
        if (oldPositionId != 0 && liqPos.getPositionLiquidity(positionManager) == 0) {
            delete deposits[oldPositionId];
            liqPos.positionId = 0;
        }
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        if (assetBal > 0) _swap(ASSET, WETH, assetBal);
        assetAddr = _newAssetAddr;
        ASSET = IERC20(_newAssetAddr);
        address a2 = _newAssetAddr;
        address w2 = address(WETH);
        poolKey = LiquidityLibraryV4.PoolKey({
            currency0: a2 < w2 ? a2 : w2,
            currency1: a2 < w2 ? w2 : a2,
            fee: v3Fee,
            tickSpacing: tickSpacing,
            hooks: address(0)
        });
        (_newPoolV3Addr);
        _giveAllowances();
        (assetBal, wethBal) = _getTokenBalances();
        stratMode = Mode.NORMAL;
        defensiveEnteredAt = 0;
        baselineTick = 0;
        floorTick = 0;
        baseTokenShareBps = 0;
        if (wethBal == 0 && assetBal == 0) {
            emit StrategyEvent(10, liqPos.positionId, 0, 0);
            return;
        }
        _balanceTokens(assetBal, wethBal);
        _mintNewPosition(startM);
        if (liqPos.positionId != 0) {
            lastRebalanceTime = block.timestamp;
        }
        emit StrategyEvent(10, liqPos.positionId, 0, 0);
    }

    /// @notice Vault-only: strategy fully drained to vault; LP mode paused (mirrors defensive idle handling).
    function enterNeutralFromVault() external onlyAuthorized {
        stratMode = Mode.NUETRAL;
        defensiveEnteredAt = block.timestamp;
        consecutiveOffensiveCount = 0;
        floorTick = 0;
        baselineTick = 0;
        emit StrategyEvent(12, uint256(uint8(Mode.NUETRAL)), 0, 0);
    }

    /// @notice Vault-only: after `neutralDeposit`, resume NORMAL LP lifecycle.
    function resumeNormalFromVault() external onlyAuthorized {
        if (stratMode != Mode.NUETRAL) revert MustBeNeutral();
        stratMode = Mode.NORMAL;
        defensiveEnteredAt = 0;
        lastRebalanceTime = block.timestamp;
        emit StrategyEvent(13, uint256(uint8(Mode.NORMAL)), 0, 0);
    }
}