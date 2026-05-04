"""Generate contracts/v4/FloatStrategyV4.sol from contracts/FloatStrategy.sol.

Out of date: the v4 stack now uses IFloatStrategyV4, StrategyManagerV4, TrailingFloorLib, and
single-argument changeAsset. Update this script before re-running or edit FloatStrategyV4.sol directly.
"""
from pathlib import Path

p = Path("contracts/FloatStrategy.sol").read_text(encoding="utf-8")

p = p.replace("pragma solidity ^0.8.20;", "pragma solidity ^0.8.20;")

old_imports = '''import "../interfaces/INonfungiblePositionManager.sol";
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
import "../interfaces/IFloatStrategy.sol";'''

new_imports = '''import "../../interfaces/IPositionManagerV4.sol";
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
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";'''

p = p.replace(old_imports, new_imports)

p = p.replace(
    "contract FloatStrategy is IFloatStrategy, StrategyManager, ReentrancyGuard, IERC721Receiver",
    "contract FloatStrategyV4 is IFloatStrategy, StrategyManager, ReentrancyGuard, IERC721Receiver, IOutOfRangeStrategy",
)
p = p.replace(
    "using LiquidityLibrary for LiquidityLibrary.PositionState;",
    "using LiquidityLibraryV4 for LiquidityLibraryV4.PositionState;",
)
p = p.replace(
    "INonfungiblePositionManager public immutable nonfungiblePositionManager;",
    "IPositionManagerV4 public immutable positionManager;",
)
p = p.replace(
    "LiquidityLibrary.PositionState private liqPos;",
    "LiquidityLibraryV4.PositionState private liqPos;",
)
p = p.replace(
    """IUniswapV3PoolMinimal private pool;
    IUniswapV3Factory private factory;
    ISwapRouter private swapRouter;""",
    """IPoolManagerV4 private poolManager;
    LiquidityLibraryV4.PoolKey public poolKey;
    IFloatV4StrategySwapRouter private swapRouterV4;""",
)

import re

p = re.sub(
    r"    address private immutable v3FactoryAddr = [^;]+;\n    address private immutable baseWETH = [^;]+;\n    address private immutable nonfungiblePosManAddr = [^;]+;\n",
    "",
    p,
)
p = p.replace(
    "address private assetPoolV3;\n    address private swapRouterAddr;",
    "address private swapRouterAddr;",
)

old_ctor = """    constructor() StrategyManager() {
        WETH = IERC20(baseWETH);
        nonfungiblePositionManager = INonfungiblePositionManager(nonfungiblePosManAddr);
        factory = IUniswapV3Factory(v3FactoryAddr);
        deviationBands = StrategyManager.DeviationBands({lowerBps: 400, upperBps: 2600, maxTokenCapBps: 9600});
        emit StrategyEvent(0, uint256(uint160(_msgSender())), 0, 0);
    }"""

new_ctor = """    constructor(address weth_, address positionManager_, address poolManager_) StrategyManager() {
        if (weth_ == address(0) || positionManager_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        WETH = IERC20(weth_);
        positionManager = IPositionManagerV4(positionManager_);
        poolManager = IPoolManagerV4(poolManager_);
        deviationBands = StrategyManager.DeviationBands({lowerBps: 400, upperBps: 2600, maxTokenCapBps: 9600});
        emit StrategyEvent(0, uint256(uint160(_msgSender())), 0, 0);
    }"""

p = p.replace(old_ctor, new_ctor)

old_setup = """    function setUpContract(address _assetAddr, address _assetPoolV3Addr, address _managerAddr, address _swapRouterAddr, address _vaultAddr, address _demeterAddr, address _keeperStrategyAddr) external onlyOwner {
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
        emit ContractSetUp(_msgSender());
    }"""

new_setup = """    function setUpContract(
        address _assetAddr,
        address _managerAddr,
        address _swapRouterAddr,
        address _vaultAddr,
        address _demeterAddr,
        address _keeperStrategyAddr
    ) external onlyOwner {
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
    }"""

p = p.replace(old_setup, new_setup)

# Collect / mint / increase / decrease blocks (still say nonfungiblePositionManager)
old_collect = """    function _collectAllFees(bool trackFees) internal returns (uint256 amount0, uint256 amount1, uint256 valueInWeth) {
        if (liqPos.positionId == 0) return (0, 0, 0);
        if (nonfungiblePositionManager.ownerOf(liqPos.positionId) != address(this)) {
            revert Unauthorized();
        }
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({tokenId: liqPos.positionId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max});
        (amount0, amount1) = nonfungiblePositionManager.collect(params);
        valueInWeth = 0;
        if (amount0 > 0 || amount1 > 0) {
            address p0 = pool.token0();"""

new_collect = """    function _collectAllFees(bool trackFees) internal returns (uint256 amount0, uint256 amount1, uint256 valueInWeth) {
        if (liqPos.positionId == 0) return (0, 0, 0);
        if (IERC721(address(nonfungiblePositionManager)).ownerOf(liqPos.positionId) != address(this)) {
            revert Unauthorized();
        }
        LiquidityLibraryV4.DecreaseContext memory dctx = LiquidityLibraryV4.DecreaseContext({
            posm: nonfungiblePositionManager,
            poolManager: poolManager,
            poolKey: poolKey
        });
        (amount0, amount1) = LiquidityLibraryV4.collectAllFees(liqPos, dctx, address(this));
        valueInWeth = 0;
        if (amount0 > 0 || amount1 > 0) {
            address p0 = poolKey.currency0;"""

p = p.replace(old_collect, new_collect)

old_mint = """        LiquidityLibrary.MintContext memory ctx = LiquidityLibrary.MintContext({npm: nonfungiblePositionManager, factory: factory, pool: pool, weth: address(WETH), tokens: address(ASSET), assetPoolV3: assetPoolV3, fee: v3Fee, tickSpacing: tickSpacing, m: mValue, slippageBps: slippageBps, dust: 1_000_000_000_000});
        (uint256 newId, uint128 liq) = liqPos.mintNewPosition(ctx, assetBal, wethBal);
        if (newId != 0 && liq > 0) {
            (address token0, address token1, , , , uint128 liquidity) = liqPos.getPositionData(nonfungiblePositionManager);
            deposits[newId] = Deposit(address(this), liquidity, token0, token1);
            emit StrategyEvent(4, newId, uint256(uint32(int32(liqPos.tickLower))), uint256(uint32(int32(liqPos.tickUpper))));
            (, int24 poolTickAfterMint, , , , , ) = pool.slot0();"""

new_mint = """        LiquidityLibraryV4.MintContext memory ctx = LiquidityLibraryV4.MintContext({
            posm: nonfungiblePositionManager,
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
            (, int24 poolTickAfterMint) = _readSlot0();"""

p = p.replace(old_mint, new_mint)

old_inc = """        LiquidityLibrary.IncreaseContext memory ctx = LiquidityLibrary.IncreaseContext({npm: nonfungiblePositionManager, pool: pool, fee: v3Fee, slippageBps: slippageBps, dust: 1_000_000_000_000});"""

new_inc = """        LiquidityLibraryV4.IncreaseContext memory ctx = LiquidityLibraryV4.IncreaseContext({
            posm: nonfungiblePositionManager,
            poolManager: poolManager,
            poolKey: poolKey,
            slippageBps: slippageBps,
            dust: 1_000_000_000_000
        });"""

p = p.replace(old_inc, new_inc)

old_dec = """        LiquidityLibrary.DecreaseContext memory ctx = LiquidityLibrary.DecreaseContext({npm: nonfungiblePositionManager, pool: pool});"""

new_dec = """        LiquidityLibraryV4.DecreaseContext memory ctx = LiquidityLibraryV4.DecreaseContext({
            posm: nonfungiblePositionManager,
            poolManager: poolManager,
            poolKey: poolKey
        });"""

p = p.replace(old_dec, new_dec)

p = p.replace("nonfungiblePositionManager", "positionManager")

p = p.replace("(, int24 poolTick, , , , , ) = pool.slot0();", "(, int24 poolTick) = _readSlot0();")
p = p.replace("(uint160 sqrtP, , , , , , ) = pool.slot0();", "(uint160 sqrtP, ) = _readSlot0();")
p = p.replace("(, int24 poolTickAfterMint, , , , , ) = pool.slot0();", "(, int24 poolTickAfterMint) = _readSlot0();")

p = p.replace("address p0 = pool.token0();", "address p0 = poolKey.currency0;")
p = p.replace("address p1 = pool.token1();", "address p1 = poolKey.currency1;")

p = p.replace(
    "swapRouter.swapExactInputFromStrategyStrictQuote(address(tokenIn), address(tokenOut), amount, address(this));",
    "swapRouterV4.swapExactInputSingleFromStrategy(_toCorePoolKey(), address(tokenIn) == poolKey.currency0, amount, 0);",
)

p = p.replace(
    "(, , , int24 posTickLower, int24 posTickUpper, ) = liqPos.getPositionData(positionManager);",
    "(int24 posTickLower, int24 posTickUpper) = (liqPos.tickLower, liqPos.tickUpper);",
)
p = p.replace(
    "(, , , , int24 posTickUpper, ) = liqPos.getPositionData(positionManager);",
    "(int24 posTickUpper) = (liqPos.tickUpper);",
)
p = p.replace(
    "(,,,int24 _tickLower,int24 _tickUpper,uint128 liquidity) = liqPos.getPositionData(positionManager);",
    "(int24 _tickLower, int24 _tickUpper, uint128 liquidity) = (liqPos.tickLower, liqPos.tickUpper, LiquidityLibraryV4.getPositionLiquidity(liqPos, positionManager));",
)

p = p.replace(
    "(uint160 sqrtPriceX96, , , , , , ) = pool.slot0();",
    "(uint160 sqrtPriceX96, ) = _readSlot0();",
)

p = p.replace("LiquidityLibrary.getSqrtRatios", "LiquidityLibraryV4.getSqrtRatios")
p = p.replace("LiquidityLibrary.getAmountsForLiquidity", "LiquidityLibraryV4.getAmountsForLiquidity")
p = p.replace("LiquidityLibrary.getLiquidityForAmounts", "LiquidityLibraryV4.getLiquidityForAmounts")
p = p.replace("LiquidityLibrary.priceDeviationBpsAbove", "LiquidityLibrary.priceDeviationBpsAbove")
p = p.replace("LiquidityLibrary.trailingFloorDepthBps", "LiquidityLibrary.trailingFloorDepthBps")
p = p.replace("LiquidityLibrary.floorTickBelowCurrentByBps", "LiquidityLibrary.floorTickBelowCurrentByBps")
p = p.replace("LiquidityLibrary.alignDown", "LiquidityLibrary.alignDown")

p = p.replace(
    "ASSET.forceApprove(address(positionManager), type(uint256).max);\n            ASSET.forceApprove(address(swapRouter), type(uint256).max);",
    "ASSET.forceApprove(address(positionManager), type(uint256).max);\n            ASSET.forceApprove(address(swapRouterV4), type(uint256).max);",
)
p = p.replace(
    "WETH.forceApprove(address(positionManager), type(uint256).max);\n        WETH.forceApprove(address(swapRouter), type(uint256).max);",
    "WETH.forceApprove(address(positionManager), type(uint256).max);\n        WETH.forceApprove(address(swapRouterV4), type(uint256).max);",
)
p = p.replace(
    "if (address(ASSET) != address(0)) ASSET.forceApprove(address(positionManager), 0);",
    "if (address(ASSET) != address(0)) {\n            ASSET.forceApprove(address(positionManager), 0);\n            ASSET.forceApprove(address(swapRouterV4), 0);\n        }",
)

old_ca = """        assetPoolV3 = _newPoolV3Addr;
        pool = IUniswapV3PoolMinimal(_newPoolV3Addr);"""
new_ca = """        address a2 = _newAssetAddr;
        address w2 = address(WETH);
        poolKey = LiquidityLibraryV4.PoolKey({
            currency0: a2 < w2 ? a2 : w2,
            currency1: a2 < w2 ? w2 : a2,
            fee: v3Fee,
            tickSpacing: tickSpacing,
            hooks: address(0)
        });
        (_newPoolV3Addr);"""
p = p.replace(old_ca, new_ca)

insert = """
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

"""

marker = "    function _lpModeActive() internal view returns (bool) {\n        return mode == Mode.NORMAL || mode == Mode.OFFENSIVE;\n    }\n    modifier onlyAuthorized() {"
if marker not in p:
    raise SystemExit("marker not found")
p = p.replace(
    marker,
    "    function _lpModeActive() internal view returns (bool) {\n        return stratMode == Mode.NORMAL || stratMode == Mode.OFFENSIVE;\n    }"
    + insert
    + "    modifier onlyAuthorized() {",
)

p = p.replace("Mode public mode;", "Mode internal stratMode;")
p = re.sub(r"\bmode ==", "stratMode ==", p)
p = re.sub(r"\bmode !=", "stratMode !=", p)
p = re.sub(r"\bmode =", "stratMode =", p)

p = p.replace(
    """        WETH.forceApprove(address(positionManager), 0);
    }
    function changeAsset(address _newAssetAddr, address _newPoolV3Addr) external override onlyAuthorized {""",
    """        WETH.forceApprove(address(positionManager), 0);
        WETH.forceApprove(address(swapRouterV4), 0);
    }
    function changeAsset(address _newAssetAddr, address _newPoolV3Addr) external override onlyAuthorized {""",
)

Path("contracts/v4/FloatStrategyV4.sol").write_text(p, encoding="utf-8")
print("OK contracts/v4/FloatStrategyV4.sol")
