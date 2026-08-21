// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.20;

import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/IUniswapV3PoolMinimal.sol";
import "./interfaces/IUniswapV3Factory.sol";
import "./StrategyManagerV2.sol";
import "./interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./libraries/LiquidityLibraryV2.sol";
import "./libraries/TrailingFloorLib.sol"; 
import "./interfaces/IFloatStrategyV2.sol";

/// @title FloatStrategyV2
/// @notice V3 Float strategy with Auto/V5-style dual-bucket ERC20 reserve + changeAsset-safe clear. No NEUTRAL mode.
contract FloatStrategyV2 is IFloatStrategyV2, StrategyManagerV2, ReentrancyGuard, IERC721Receiver {
    error Unauthorized();
    error ZeroValue();
    error ZeroAddress();
    error PositionExists();

    event AssetChanged(
        address indexed oldAsset,
        address indexed newAsset,
        uint256 poolValue,
        uint64 timestamp
    );
    using SafeERC20 for IERC20;
    using LiquidityLibraryV2 for LiquidityLibraryV2.PositionState;
    address public feeManager;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    LiquidityLibraryV2.PositionState private liqPos;
    IUniswapV3PoolMinimal private pool;
    IUniswapV3Factory private factory;
    ISwapRouter private swapRouter;
    address public managerAddress;
    IERC20 private ASSET;
    IERC20 private WETH;
    address private constant V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address private constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address private constant baseUSDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address private vaultAddr;
    address private assetPoolV3;
    address private swapRouterAddr; 
    address public assetAddr;
    address private demeterAddr;
    address private keeperStratAddr;
    bool public harvestOnDeposit = true;
    uint256 public lastHarvest; 
    uint256 public PrevHarvestTime;
    uint256 public lastOffensiveTime; 
    uint256 public prevOffensiveTime;
    uint256 public baseTokenShareBps = 5_000;
    uint256 public UniswapFeesCollected;
    uint256 public lastUniswapFeeTotal;
    uint256 public reservedAsset;
    uint256 public reservedWeth;
    struct Deposit {address owner; uint128 liquidity; address token0; address token1;}
    mapping(uint256 => Deposit) public deposits;
    enum Mode { NORMAL, DEFENSIVE, OFFENSIVE, STABLE}
    Mode public mode;
    uint256 public lastRebalanceTime;
    uint256 public defensiveEnteredAt;
    uint256 public consecutiveOffensiveCount;
    uint256 public prevConsecutiveOffensiveCount;
    event StrategyEvent(uint8 indexed eventType, uint256 indexed data1, uint256 data2, uint256 data3);
    function _lpModeActive() internal view returns (bool) {
        return mode == Mode.NORMAL || mode == Mode.OFFENSIVE || mode == Mode.STABLE;
    }
    modifier onlyAuthorized() {
        address s = _msgSender();
        if (s != vaultAddr && s != demeterAddr && s != keeperStratAddr && s != managerAddress && s != owner()) revert Unauthorized();
        _;
    }
    constructor() StrategyManagerV2() {
        WETH = IERC20(BASE_WETH);
        nonfungiblePositionManager = INonfungiblePositionManager(NPM);
        factory = IUniswapV3Factory(V3_FACTORY);
    }
    function setUpContract(address _assetAddr, address _assetPoolV3Addr, address _managerAddr, address _swapRouterAddr, address _vaultAddr, address _demeterAddr, address _keeperStrategyAddr, address _feeManagerAddr) external onlyOwner {
        managerAddress = _managerAddr;
        assetAddr = _assetAddr;
        swapRouterAddr = _swapRouterAddr;
        vaultAddr = _vaultAddr;
        demeterAddr = _demeterAddr;
        keeperStratAddr = _keeperStrategyAddr;
        feeManager = _feeManagerAddr;
        assetPoolV3 = _assetPoolV3Addr;
        pool = IUniswapV3PoolMinimal(assetPoolV3);
        _syncPoolFeeParamsFromPool();
        swapRouter = ISwapRouter(swapRouterAddr);
        ASSET = IERC20(assetAddr);
        _giveAllowances();
        lastRebalanceTime = block.timestamp;
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
            if (mode == Mode.DEFENSIVE) {
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
        if (mode == Mode.DEFENSIVE) {
            (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
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
        _consumeReservedShare(userShares, totalSupply_);
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
    }
    function harvestBoolean(bool skipIncreaseLiquidity) external nonReentrant returns (uint256 newAssets) {
        address s = msg.sender;
        if (s != address(this) && s != vaultAddr && s != demeterAddr && s != keeperStratAddr && s != managerAddress && s != owner()) {
            revert Unauthorized();
        }
        _harvest(skipIncreaseLiquidity);
        return poolValue();
    }
    function _noteHarvestActivity() internal {
        PrevHarvestTime = lastHarvest;
        lastHarvest = block.timestamp;
    }
    function _syncPoolFeeParamsFromPool() internal {
        v3Fee = pool.fee();
        tickSpacing = pool.tickSpacing();
        if (rangeBelowTicks != 0) {
            rangeBelowTicks = TrailingFloorLib.alignTicksDownToSpacing(rangeBelowTicks, tickSpacing);
        }
        if (rangeAboveTicks != 0) {
            rangeAboveTicks = TrailingFloorLib.alignTicksDownToSpacing(rangeAboveTicks, tickSpacing);
        }
    }
    function _liquidityDust() private view returns (uint256) {
        return address(ASSET) == baseUSDC ? 1_000_000 : 1_000_000_000_000;
    }
    function _harvest(bool skipIncreaseLiquidity) internal  {
        if (mode == Mode.DEFENSIVE) {
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
        if (valueInWeth > 0) {
            emit StrategyEvent(4, liqPos.positionId, valueInWeth, 0);
        }
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
    function _handleOffensiveStale() internal returns (bool) {
        if (mode == Mode.OFFENSIVE
                && block.timestamp - lastOffensiveTime > offensiveStaleDuration
                && consecutiveOffensiveCount == prevConsecutiveOffensiveCount + 1) {
            _decreaseAllLiquidity();
            liqPos.positionId = 0;
            mode = Mode.NORMAL;
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
    function _inRange() internal view returns (bool) {
        if (liqPos.positionId == 0) return false;
        (, int24 poolTick, , , , , ) = pool.slot0();
        (, , , int24 posTickLower, int24 posTickUpper, ) = liqPos.getPositionData(nonfungiblePositionManager);
        return poolTick >= posTickLower && poolTick < posTickUpper;
    }
    function readInRange() external view override returns (bool) {
        return _inRange();
    }
    function keeperCheck() external nonReentrant returns (bool) {
        // STABLE: maintain USDC/WETH LP only — remint at target on idle/OOR, no offensive/defensive.
        if (mode == Mode.STABLE) {
            if (liqPos.positionId == 0) return _remintAtTarget();
            if (_inRange()) return true;
            uint128 remainingLiq = _drainPositionLiquidity(6);
            if (remainingLiq != 0) return true;
            liqPos.positionId = 0;
            return _remintAtTarget();
        }
        if (_handleOffensiveStale()) return true;
        if (liqPos.positionId == 0) {
            return _handleIdleNoPosition();
        }
        if (_inRange()) return true;
        return _handleOutOfRange();
    }

    function _handleIdleNoPosition() internal returns (bool) {
        if (mode != Mode.NORMAL && mode != Mode.OFFENSIVE) return false;
        if (liqPos.tickLower == 0 && liqPos.tickUpper == 0) return false;
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        if (assetBal <= _liquidityDust() && wethBal <= _liquidityDust()) {
            if (reservedAsset <= _liquidityDust() && reservedWeth <= _liquidityDust()) return false;
        }
        _enterDefensive();
        return true;
    }

    function _oorExitSide() internal view returns (bool exitedAbove, bool exitedBelow) {
        (int24 lower, int24 upper) = (liqPos.tickLower, liqPos.tickUpper);
        if (lower == 0 && upper == 0) return (false, false);
        (, int24 poolTick, , , , , ) = pool.slot0();
        exitedAbove = poolTick >= upper;
        exitedBelow = poolTick < lower;
    }
    function _assetStrengthAfterOor() internal view returns (bool assetStrong, bool assetWeak) {
        (bool exitedAbove, bool exitedBelow) = _oorExitSide();
        address weth = address(WETH);
        if (pool.token0() == weth) {
            assetStrong = exitedBelow;
            assetWeak = exitedAbove;
        } else if (pool.token1() == weth) {
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
        // Preserve STABLE when reminting USDC LP; otherwise return to NORMAL.
        if (mode != Mode.STABLE) mode = Mode.NORMAL;
        consecutiveOffensiveCount = 0;
        prevConsecutiveOffensiveCount = 0;
        baseTokenShareBps = targetAssetBps != 0 ? targetAssetBps : 5000;
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        if (assetBal <= _liquidityDust() && wethBal <= _liquidityDust()) {
            if (reservedAsset <= _liquidityDust() && reservedWeth <= _liquidityDust()) return false;
            _setReserved(0, 0);
            (assetBal, wethBal) = _getDeployableBalances();
        }
        _fundDeficitFromReserve(assetBal, wethBal);
        (assetBal, wethBal) = _getDeployableBalances();
        if (assetBal <= _liquidityDust() && wethBal <= _liquidityDust()) return false;
        _balanceTokens(assetBal, wethBal);
        _mintAsymmetricPosition();
        if (liqPos.positionId != 0) {
            _noteHarvestActivity();
            lastRebalanceTime = block.timestamp;
            emit StrategyEvent(5, liqPos.positionId, baseTokenShareBps, 0);
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
        mode = Mode.DEFENSIVE;
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
            _remintAtTarget();
            return;
        }
        mode = Mode.OFFENSIVE;
        _balanceTokens(assetBal, wethBal);
        _mintAsymmetricPosition();
        if (liqPos.positionId != 0) {
            baseTokenShareBps = _assetTargetBps();
            defensiveEnteredAt = 0;
            lastRebalanceTime = block.timestamp;
            emit StrategyEvent(5, liqPos.positionId, baseTokenShareBps, 0);
        } else {
            _remintAtTarget();
        }
    }

    function _assetTargetBps() internal view returns (uint256) {
        if (mode == Mode.OFFENSIVE && consecutiveOffensiveCount >= minFloorTickCount) {
            if (offensiveAssetBps != 0) return offensiveAssetBps;
        }
        if (targetAssetBps != 0) return targetAssetBps;
        return 5000;
    }
    function _effectiveRangeBelowTicks() internal view returns (uint256) {
        uint256 base = rangeBelowTicks;
        if (base == 0 || base >= 10_000) base = 400;
        if (consecutiveOffensiveCount < minFloorTickCount) {
            return TrailingFloorLib.alignTicksDownToSpacing(base, tickSpacing);
        }
        uint256 count = consecutiveOffensiveCount;
        if (count > maxOffensiveRatchetCount) count = maxOffensiveRatchetCount;
        uint256 steps = count - minFloorTickCount + 1;
        uint256 effective = base;
        uint256 floorTicks = minRangeBelowTicks != 0 ? minRangeBelowTicks : 200;
        uint256 num = ratchetNumerator != 0 ? ratchetNumerator : 1;
        uint256 den = ratchetDenominator != 0 ? ratchetDenominator : 3;
        for (uint256 i = 0; i < steps; i++) {
            effective = effective * num / den;
            if (effective < floorTicks) {
                return TrailingFloorLib.alignTicksDownToSpacing(floorTicks, tickSpacing);
            }
        }
        return TrailingFloorLib.alignTicksDownToSpacing(effective, tickSpacing);
    }
    function _asymmetricTicks(int24 currentTick) internal view returns (int24 lower, int24 upper) {
        uint256 belowTicks = _effectiveRangeBelowTicks();
        uint256 aboveTicks = rangeAboveTicks;
        if (aboveTicks == 0 || aboveTicks >= 10_000) aboveTicks = 600;
        aboveTicks = TrailingFloorLib.alignTicksDownToSpacing(aboveTicks, tickSpacing);
        return TrailingFloorLib.asymmetricSpacedTicks(currentTick, tickSpacing, belowTicks, aboveTicks);
    }

    function _mintContext() internal view returns (LiquidityLibraryV2.MintContext memory) {
        return LiquidityLibraryV2.MintContext({
            npm: nonfungiblePositionManager,
            factory: factory,
            pool: pool,
            weth: address(WETH),
            tokens: address(ASSET),
            assetPoolV3: assetPoolV3,
            fee: v3Fee,
            tickSpacing: tickSpacing,
            m: 1,
            slippageBps: slippageBps,
            dust: _liquidityDust()
        });
    }

    function _mintAsymmetricPosition() internal {
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        if (assetBal == 0 && wethBal == 0) return;
        (, int24 currentTick, , , , , ) = pool.slot0();
        (int24 lower, int24 upper) = _asymmetricTicks(currentTick);
        (uint256 newId, uint128 liq) = liqPos.mintNewPositionWithRange(
            _mintContext(),
            assetBal,
            wethBal,
            lower,
            upper
        );
        if (newId != 0 && liq > 0) {
            (address token0, address token1, , , , uint128 liquidity) = liqPos.getPositionData(nonfungiblePositionManager);
            deposits[newId] = Deposit(address(this), liquidity, token0, token1);
            emit StrategyEvent(6, newId, uint256(uint32(int32(liqPos.tickLower))), uint256(uint32(int32(liqPos.tickUpper))));
        }
        _handleLeftoverTokensWithLimit(0);
    }

    function _deposit() internal {
        if (liqPos.positionId != 0 && mode == Mode.DEFENSIVE) {
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
        if (nonfungiblePositionManager.ownerOf(liqPos.positionId) != address(this)) {
            revert Unauthorized();
        }
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: liqPos.positionId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        (amount0, amount1) = nonfungiblePositionManager.collect(params);
        valueInWeth = 0;
        if (amount0 == 0 && amount1 == 0) return (0, 0, 0);

        address p0 = pool.token0();
        address p1 = pool.token1();
        if (trackFees && protocolFeeBps > 0) {
            uint256 fee0 = Math.mulDiv(amount0, protocolFeeBps, DIVISOR);
            uint256 fee1 = Math.mulDiv(amount1, protocolFeeBps, DIVISOR);
            if (fee0 > 0) IERC20(p0).safeTransfer(feeManager, fee0);
            if (fee1 > 0) IERC20(p1).safeTransfer(feeManager, fee1);
            amount0 -= fee0;
            amount1 -= fee1;
        }
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
    function _peelReserveFromDeployable() internal {
        if (reserveBps == 0) return;
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        uint256 ra = Math.mulDiv(assetBal, reserveBps, DIVISOR);
        uint256 rw = Math.mulDiv(wethBal, reserveBps, DIVISOR);
        if (ra == 0 && rw == 0) return;
        _setReserved(reservedAsset + ra, reservedWeth + rw);
    }
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
        if (pull > 0) {
            uint256 dust = _liquidityDust();
            if (pull > dust) {
                swapRouter.swapExactInputFromStrategyStrictQuote(
                    address(ASSET), address(WETH), pull, address(this)
                );
            }
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
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        (uint256 amount0Max, uint256 amount1Max) = p0 == address(WETH)
            ? (wethBal, assetBal)
            : (assetBal, wethBal);
        LiquidityLibraryV2.IncreaseContext memory ctx = LiquidityLibraryV2.IncreaseContext({npm: nonfungiblePositionManager, pool: pool, fee: v3Fee, slippageBps: slippageBps, dust: _liquidityDust()});
        liqAdded = liqPos.increaseLiquidityInternal(ctx, IERC20(p0), IERC20(p1), amount0Max, amount1Max);
        if (liqAdded > 0) {
            deposits[liqPos.positionId].liquidity += liqAdded;
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

        LiquidityLibraryV2.DecreaseContext memory ctx = LiquidityLibraryV2.DecreaseContext({npm: nonfungiblePositionManager, pool: pool});
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
    }
    function _handleLeftoverTokensWithLimit(uint256 iter) internal {
        if (iter >= 1) return;
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        uint256 d = _liquidityDust();
        if (assetBal <= d && wethBal <= d) return;
        _balanceTokens(assetBal, wethBal);
        if (liqPos.positionId != 0) {
            _increaseLiquidityInternal();
            _handleLeftoverTokensWithLimit(iter + 1);
        }
    }
    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amount) internal {
        if (amount == 0) return;
        uint256 bal = _spendable(tokenIn);
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
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = LiquidityLibraryV2.getSqrtRatios(liqPos.tickLower, liqPos.tickUpper);
        (uint256 amount0, uint256 amount1) = LiquidityLibraryV2.getAmountsForLiquidity(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, liquidity);
        address p0 = pool.token0();
        return p0 == address(WETH) ? (amount1, amount0) : (amount0, amount1);
    }
      function totalLiquidity() external view override returns (uint128) { return liqPos.getPositionLiquidity(nonfungiblePositionManager); }
    function _calculateLiquidityToRemove(uint256 amount) internal view returns (uint256) {
        if (liqPos.positionId == 0) return 0;
        (,,,int24 _tickLower,int24 _tickUpper,uint128 liquidity) = liqPos.getPositionData(nonfungiblePositionManager);
        (uint160 sqrtP, , , , , , ) = pool.slot0();
        uint128 positionLiquidity = liqPos.getPositionLiquidity(nonfungiblePositionManager);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = LiquidityLibraryV2.getSqrtRatios(_tickLower, _tickUpper);
        (uint256 amount0, uint256 amount1) = LiquidityLibraryV2.getAmountsForLiquidity(sqrtP, sqrtLowerX96, sqrtUpperX96, positionLiquidity);
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
        uint128 liqNeeded = LiquidityLibraryV2.getLiquidityForAmounts(sqrtP, sqrtLowerX96, sqrtUpperX96, bal0, bal1);
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
    function mintNewPosition() external override onlyAuthorized {
        changeAsset(assetAddr, assetPoolV3);
    }

    function changeAsset(address _newAssetAddr, address _newPoolV3Addr) public override onlyAuthorized {
        if (_newAssetAddr == address(0)) revert ZeroAddress();
        address oldAsset = assetAddr;
        consecutiveOffensiveCount = 0;
        _decreaseAllLiquidity();
        uint256 oldPositionId = liqPos.positionId;
        if (oldPositionId != 0 && liqPos.getPositionLiquidity(nonfungiblePositionManager) == 0) {
            delete deposits[oldPositionId];
            liqPos.positionId = 0;
        }
        if (oldAsset != address(0) && oldAsset != address(WETH)) {
            _clearReservedAssetToWeth();
            if (oldAsset != _newAssetAddr) {
                uint256 oldDeployable = _spendable(ASSET);
                if (oldDeployable > 0) _swap(ASSET, WETH, oldDeployable);
            }
        }
        assetAddr = _newAssetAddr;
        ASSET = IERC20(_newAssetAddr);
        assetPoolV3 = _newPoolV3Addr;
        pool = IUniswapV3PoolMinimal(assetPoolV3);
        _syncPoolFeeParamsFromPool();
        _giveAllowances();
        (uint256 assetBal, uint256 wethBal) = _getDeployableBalances();
        bool toStable = assetAddr == baseUSDC;
        mode = toStable ? Mode.STABLE : Mode.NORMAL;
        defensiveEnteredAt = toStable ? block.timestamp : 0;
        baseTokenShareBps = targetAssetBps != 0 ? targetAssetBps : 5000;
        // STABLE now mints USDC/WETH LP (same path as NORMAL) instead of holding idle USDC.
        if (wethBal != 0 || assetBal != 0 || reservedAsset > 0 || reservedWeth > 0) {
            _fundDeficitFromReserve(assetBal, wethBal);
            (assetBal, wethBal) = _getDeployableBalances();
            if (assetBal != 0 || wethBal != 0) {
                _balanceTokens(assetBal, wethBal);
                _mintAsymmetricPosition();
                if (liqPos.positionId != 0) {
                    lastRebalanceTime = block.timestamp;
                }
            }
        }
        emit AssetChanged(oldAsset, _newAssetAddr, poolValue(), uint64(block.timestamp));
    }
    function rescueToken(address _token) external onlyOwner {
        if (_token == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(_token).balanceOf(address(this));
        if (amount == 0) revert ZeroValue();
        IERC20(_token).safeTransfer(owner(), amount);
    }
}