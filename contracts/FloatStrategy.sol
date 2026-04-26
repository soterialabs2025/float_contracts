// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.20;

import "../interfaces/INonfungiblePositionManager.sol";
import "../interfaces/IUniswapV3PoolMinimal.sol";
import "../interfaces/IUniswapV3Factory.sol";
import "./StrategyManager.sol";
import "../interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../libraries/LiquidityLibrary.sol";
import "../interfaces/IFloatStrategy.sol";

contract FloatStrategy is IFloatStrategy, StrategyManager, ReentrancyGuard, IERC721Receiver {         
    error Unauthorized();
    error ZeroValue();
    error ZeroAddress();
    error PositionExists();
    error MustBeNeutral();
    using SafeERC20 for IERC20;
    using LiquidityLibrary for LiquidityLibrary.PositionState;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    LiquidityLibrary.PositionState private liqPos;
    IUniswapV3PoolMinimal private pool;
    IUniswapV3Factory private factory;
    ISwapRouter private swapRouter;
    address public managerAddress;
    IERC20 private ASSET;
    IERC20 private WETH;
    address private immutable v3FactoryAddr = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address private immutable baseWETH = 0x4200000000000000000000000000000000000006;
    address private immutable nonfungiblePosManAddr = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address private vaultAddr;
    address private assetPoolV3;
    address private swapRouterAddr; 
    address public assetAddr;
    address private demeterAddr;
    address private keeperStratAddr;
    int24 public baselineTick;
    int24 public floorTick;
    bool public harvestOnDeposit = true;
    uint256 public lastHarvest; 
    uint256 public PrevHarvestTime;
    uint256 public lastOffensiveTime; 
    uint256 public prevOffensiveTime;
    uint256 public baseTokenShareBps = 5_000;
    uint256 private tokenShareAnchorBps;
    uint256 public UniswapFeesCollected; 
    uint256 public lastUniswapFeeTotal;
    struct Deposit {address owner; uint128 liquidity; address token0; address token1;}
    mapping(uint256 => Deposit) public deposits;
    enum Mode { NORMAL, DEFENSIVE, OFFENSIVE, NUETRAL }
    Mode public mode;
    uint256 public lastRebalanceTime;
    uint256 public defensiveEnteredAt;
    uint256 public consecutiveOffensiveCount;
    uint256 public prevConsecutiveOffensiveCount;
    event StrategyEvent(uint8 indexed eventType, uint256 indexed data1, uint256 data2, uint256 data3);
    event ContractSetUp(address indexed caller);
    bool public contractSetUp;
    function _lpModeActive() internal view returns (bool) {
        return mode == Mode.NORMAL || mode == Mode.OFFENSIVE;
    }
    modifier onlyAuthorized() {
        address s = _msgSender();
        if (s != vaultAddr && s != demeterAddr && s != keeperStratAddr && s != managerAddress && s != owner()) revert Unauthorized();
        _;
    }
    constructor() StrategyManager() {
        WETH = IERC20(baseWETH);
        nonfungiblePositionManager = INonfungiblePositionManager(nonfungiblePosManAddr);
        factory = IUniswapV3Factory(v3FactoryAddr);
        deviationBands = StrategyManager.DeviationBands({lowerBps: 200, upperBps: 2500, maxTokenCapBps: 9800});
        offensiveBands = StrategyManager.DeviationBands({lowerBps: 200, upperBps: 3000, maxTokenCapBps: 9800});
    }
    function setUpContract(address _assetAddr, address _assetPoolV3Addr, address _managerAddr, address _swapRouterAddr, address _vaultAddr, address _demeterAddr, address _keeperStrategyAddr) external onlyOwner {
        managerAddress = _managerAddr;
        assetAddr = _assetAddr;
        swapRouterAddr = _swapRouterAddr;
        assetPoolV3 = _assetPoolV3Addr;
        vaultAddr = _vaultAddr;
        demeterAddr = _demeterAddr;
        keeperStratAddr = _keeperStrategyAddr;
        pool = IUniswapV3PoolMinimal(assetPoolV3);
        swapRouter = ISwapRouter(swapRouterAddr);
        ASSET = IERC20(assetAddr);
        _giveAllowances();
        contractSetUp = true;
        lastRebalanceTime = block.timestamp;
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
        if (mode == Mode.DEFENSIVE || mode == Mode.NUETRAL) {
            (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
            if (assetBal > 0 || wethBal > 0) {
                _balanceTokens(assetBal, wethBal);
            }
            emit StrategyEvent(0, poolValue(), 0, 0);
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
        emit StrategyEvent(1, poolValue(), 0, 0);
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
        if (mode == Mode.DEFENSIVE || mode == Mode.NUETRAL) {
            if (liqPos.positionId != 0) {
                uint256 beforeValDefensive = balanceOfIdle();
                (, , uint256 valueInWethDefensive) = _collectAllFees(true);
                if (valueInWethDefensive > 0) {
                    emit StrategyEvent(2, liqPos.positionId, valueInWethDefensive, 0);
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
        (, , uint256 valueInWeth) = _collectAllFees(true);
        if (valueInWeth == 0) {
            return;
        }
        emit StrategyEvent(4, liqPos.positionId, valueInWeth, 0);
        if (!skipIncreaseLiquidity && _lpModeActive()) {
            if (mode == Mode.OFFENSIVE
                && block.timestamp - lastOffensiveTime > offensiveStaleDuration  
                && consecutiveOffensiveCount == prevConsecutiveOffensiveCount + 1) {
                _decreaseAllLiquidity();
                liqPos.positionId = 0;
                mode = Mode.NORMAL;
                baseTokenShareBps = 5_000;
                consecutiveOffensiveCount = 0;
                prevConsecutiveOffensiveCount = 0;
                (uint256 staleAssetBal, uint256 staleWethBal) = _getTokenBalances();
                _balanceTokens(staleAssetBal, staleWethBal);
                _mintNewPosition(startM);
                _noteHarvestActivity();
                return;
            }
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
        (, int24 poolTick, , , , , ) = pool.slot0();
        (, , , int24 posTickLower, int24 posTickUpper, ) = liqPos.getPositionData(nonfungiblePositionManager);
        return poolTick >= posTickLower && poolTick < posTickUpper;
    }
    function readInRange() external view override returns (bool) {
        return _inRange();
    }
    function _checkInRange() internal returns (bool) {
        if (mode == Mode.DEFENSIVE || mode == Mode.NUETRAL) return true;
        if (_inRange()) return false;
        if (liqPos.positionId == 0) {
            _enterDefensive();
            return true;
        }
        uint128 remainingLiq = _drainPositionLiquidity(6);
        if (remainingLiq != 0) return true;
        (, , , , int24 posTickUpper, ) = liqPos.getPositionData(nonfungiblePositionManager);
        liqPos.positionId = 0;
        _enterOffensiveOrDefensiveByTick(posTickUpper);
        return true;
    }
    function keeperCheck() external nonReentrant returns (bool) {
        if (mode == Mode.DEFENSIVE || mode == Mode.NUETRAL) return true;
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
        (, int24 poolTick, , , , , ) = pool.slot0();
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
        mode = Mode.DEFENSIVE;
        tokenShareAnchorBps = 0;
    }
    function _enterOffensiveOrDefensiveByTick(int24 posTickUpper) internal {
        (, int24 poolTick, , , , , ) = pool.slot0();
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
        mode = Mode.OFFENSIVE;
        _balanceTokens(assetBal, wethBal);
        _mintNewPosition(offensiveM); 
        if (liqPos.positionId != 0) {
            baseTokenShareBps = offensiveTargetAssetBps;
            floorTick = 0;
            defensiveEnteredAt = 0;
            lastRebalanceTime = block.timestamp;
            emit StrategyEvent(5, liqPos.positionId, offensiveTargetAssetBps, 0);
        } else {
            _enterDefensive();
        }
    }
    function _mintNewPosition(int24 mValue) internal {
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        if (assetBal == 0 && wethBal == 0) return;
        LiquidityLibrary.MintContext memory ctx = LiquidityLibrary.MintContext({npm: nonfungiblePositionManager, factory: factory, pool: pool, weth: address(WETH), tokens: address(ASSET), assetPoolV3: assetPoolV3, fee: v3Fee, tickSpacing: tickSpacing, m: mValue, slippageBps: slippageBps, dust: 1_000_000_000_000});
        (uint256 newId, uint128 liq) = liqPos.mintNewPosition(ctx, assetBal, wethBal);
        if (newId != 0 && liq > 0) {
            (address token0, address token1, , , , uint128 liquidity) = liqPos.getPositionData(nonfungiblePositionManager);
            deposits[newId] = Deposit(address(this), liquidity, token0, token1);
            emit StrategyEvent(6, newId, uint256(uint32(int32(liqPos.tickLower))), uint256(uint32(int32(liqPos.tickUpper))));
            (, int24 poolTickAfterMint, , , , , ) = pool.slot0();
            baselineTick = poolTickAfterMint;
            floorTick = 0;
            (bool ok, uint256 currentBps) = _poolTokenShareBps();
            if (ok) tokenShareAnchorBps = currentBps;
        }
        _handleLeftoverTokensWithLimit(0);
    }

    function _deposit() internal {
        if (liqPos.positionId != 0 && (mode == Mode.DEFENSIVE || mode == Mode.NUETRAL)) {
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
        emit StrategyEvent(0, poolValue(), 0, 0);
    }
    function _collectAllFees(bool trackFees) internal returns (uint256 amount0, uint256 amount1, uint256 valueInWeth) {
        if (liqPos.positionId == 0) return (0, 0, 0);
        if (nonfungiblePositionManager.ownerOf(liqPos.positionId) != address(this)) {
            revert Unauthorized();
        }
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({tokenId: liqPos.positionId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max});
        (amount0, amount1) = nonfungiblePositionManager.collect(params);
        valueInWeth = 0;
        if (amount0 > 0 || amount1 > 0) {
            address p0 = pool.token0();
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
        (uint160 sqrtP, , , , , , ) = pool.slot0();
        address p0 = pool.token0();
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
        if (mode == Mode.OFFENSIVE && offensiveTargetAssetBps != 0) {
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
        address p0 = pool.token0();
        address p1 = pool.token1();
        LiquidityLibrary.IncreaseContext memory ctx = LiquidityLibrary.IncreaseContext({npm: nonfungiblePositionManager, pool: pool, fee: v3Fee, slippageBps: slippageBps, dust: 1_000_000_000_000});
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
            remainingLiq = liqPos.getPositionLiquidity(nonfungiblePositionManager);
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

        LiquidityLibrary.DecreaseContext memory ctx = LiquidityLibrary.DecreaseContext({npm: nonfungiblePositionManager, pool: pool});
        uint128 removed;
        uint256 positionId = liqPos.positionId; 
        if (removeAll) {
            removed = liqPos.decreaseAllLiquidity(ctx);
            deposits[positionId].liquidity = 0;
            uint128 remainingLiq = liqPos.getPositionLiquidity(nonfungiblePositionManager);
            if (remainingLiq > 0) {
                removed = liqPos.decreaseAllLiquidity(ctx);
                deposits[positionId].liquidity = 0;
            }
        } else {
            if (liquidityToRemove == 0) return;
            removed = liqPos.decreaseLiquidityByAmount(ctx, liquidityToRemove);
            deposits[positionId].liquidity = liqPos.getPositionLiquidity(nonfungiblePositionManager);
        }
        _collectAllFees(false);
        emit StrategyEvent(7, positionId, removed, 0);
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
        if (mode == Mode.DEFENSIVE || mode == Mode.NUETRAL) return true;
        (bool ok, uint256 currentBps) = _poolTokenShareBps();
        if (!ok) return false;
        uint256 baseline   = tokenShareAnchorBps == 0 ? currentBps : tokenShareAnchorBps;
        DeviationBands storage bands = mode == Mode.OFFENSIVE ? offensiveBands : deviationBands;
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
    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amount) internal {
        if (amount == 0) return;
        uint256 bal = tokenIn.balanceOf(address(this));
        if (amount > bal) amount = bal;
        if (amount == 0) return;
        swapRouter.swapExactInputFromStrategyStrictQuote(address(tokenIn), address(tokenOut), amount, address(this));
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
        uint128 liquidity = liqPos.getPositionLiquidity(nonfungiblePositionManager);
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = LiquidityLibrary.getSqrtRatios(liqPos.tickLower, liqPos.tickUpper);
        (uint256 amount0, uint256 amount1) = LiquidityLibrary.getAmountsForLiquidity(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, liquidity);
        address p0 = pool.token0();
        return p0 == address(WETH) ? (amount1, amount0) : (amount0, amount1);
    }
      function totalLiquidity() external view override returns (uint128) { return liqPos.getPositionLiquidity(nonfungiblePositionManager); }
    function _calculateLiquidityToRemove(uint256 amount) internal view returns (uint256) {
        if (liqPos.positionId == 0) return 0;
        (,,,int24 _tickLower,int24 _tickUpper,uint128 liquidity) = liqPos.getPositionData(nonfungiblePositionManager);
        (uint160 sqrtP, , , , , , ) = pool.slot0();
        uint128 positionLiquidity = liqPos.getPositionLiquidity(nonfungiblePositionManager);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = LiquidityLibrary.getSqrtRatios(_tickLower, _tickUpper);
        (uint256 amount0, uint256 amount1) = LiquidityLibrary.getAmountsForLiquidity(sqrtP, sqrtLowerX96, sqrtUpperX96, positionLiquidity);
        address p0 = pool.token0();
        (uint256 assetAmt, uint256 wethAmt) = p0 == address(WETH) ? (amount1, amount0) : (amount0, amount1);
        uint256 p = _spotPrice1e18();
        uint256 assetAsWeth = p != 0 ? Math.mulDiv(assetAmt, 1e18, p) : 0;
        uint256 totalValue = wethAmt + assetAsWeth;
        if (totalValue == 0 || liquidity == 0) return 0;
        uint256 proportion = Math.mulDiv(amount, 1e18, totalValue);
        uint256 targetTokenAmt = Math.mulDiv(assetAmt, proportion, 1e18);
        uint256 targetWethAmt = Math.mulDiv(wethAmt,  proportion, 1e18);
        (uint256 bal0, uint256 bal1) = p0 == address(WETH) ? (targetWethAmt, targetTokenAmt) : (targetTokenAmt, targetWethAmt);
        uint128 liqNeeded = LiquidityLibrary.getLiquidityForAmounts(sqrtP, sqrtLowerX96, sqrtUpperX96, bal0, bal1);
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
    function _giveAllowances() internal {
        if (address(ASSET) != address(0)) {
            ASSET.forceApprove(address(nonfungiblePositionManager), type(uint256).max);
            ASSET.forceApprove(address(swapRouter), type(uint256).max);
        }
        WETH.forceApprove(address(nonfungiblePositionManager), type(uint256).max);
        WETH.forceApprove(address(swapRouter), type(uint256).max);
    }
    function _removeAllowances() internal {
        if (address(ASSET) != address(0)) ASSET.forceApprove(address(nonfungiblePositionManager), 0);
        WETH.forceApprove(address(nonfungiblePositionManager), 0);
    }
    function changeAsset(address _newAssetAddr, address _newPoolV3Addr) external override onlyAuthorized {
        if (_newAssetAddr == address(0)) revert ZeroAddress();
        consecutiveOffensiveCount = 0;
        _decreaseAllLiquidity();
        uint256 oldPositionId = liqPos.positionId;
        if (oldPositionId != 0 && liqPos.getPositionLiquidity(nonfungiblePositionManager) == 0) {
            delete deposits[oldPositionId];
            liqPos.positionId = 0;
        }
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        if (assetBal > 0) _swap(ASSET, WETH, assetBal);
        assetAddr = _newAssetAddr;
        ASSET = IERC20(_newAssetAddr);
        assetPoolV3 = _newPoolV3Addr;
        pool = IUniswapV3PoolMinimal(_newPoolV3Addr);
        _giveAllowances();
        (assetBal, wethBal) = _getTokenBalances();
        mode = Mode.NORMAL;
        defensiveEnteredAt = 0;
        baselineTick = 0;
        floorTick = 0;
        baseTokenShareBps = 5_000;
        tokenShareAnchorBps = 0;
        if (wethBal == 0 && assetBal == 0) {
            emit StrategyEvent(8, liqPos.positionId, 0, 0);
            return;
        }
        _balanceTokens(assetBal, wethBal);
        _mintNewPosition(startM);
        if (liqPos.positionId != 0) {
            lastRebalanceTime = block.timestamp;
        }
        emit StrategyEvent(8, liqPos.positionId, 0, 0);
    }
    function enterNeutralFromVault() external onlyAuthorized {
        mode = Mode.NUETRAL;
        defensiveEnteredAt = block.timestamp;
        consecutiveOffensiveCount = 0;
        floorTick = 0;
        baselineTick = 0;
        emit StrategyEvent(9, uint256(uint8(Mode.NUETRAL)), 0, 0);
    }
    function resumeNormalFromVault() external onlyAuthorized {
        if (mode != Mode.NUETRAL) revert MustBeNeutral();
        mode = Mode.NORMAL;
        baseTokenShareBps = 5_000;
        defensiveEnteredAt = 0;
        lastRebalanceTime = block.timestamp;
    }
}