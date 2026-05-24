// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath as UniV4TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import "../v4/V4Deployments8453.sol";

/// @title LiquidV4SwapCore
/// @notice Shared Uniswap v4 swap + pool-config logic for `LiquidSwapRouterV4` and `LiquidStratMinV4`.
/// @dev    `PoolManager.unlock` + quoter strict path only. Subcontracts supply auth (`onlyAuthorized`)
///         on external entrypoints; strategies call `_swapExactInputSingleStrictInternal`.
abstract contract LiquidV4SwapCore is IUnlockCallback {
    using SafeERC20 for IERC20;

    struct V4PoolConfig {
        PoolKey key;
        bytes hookData;
    }

    IPoolManager public immutable poolManager = IPoolManager(V4Deployments8453.POOL_MANAGER);
    IV4Quoter public immutable v4Quoter = IV4Quoter(V4Deployments8453.QUOTER);

    uint16 public strictStrategySlippageBps = 200;
    uint16 public maxPriceImpactBps = 300;

    mapping(address => V4PoolConfig) public v4PoolConfig;

    event SwapExecuted(
        address indexed caller, address indexed recipient, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut
    );
    event V4PoolConfigSet(address indexed asset, PoolKey key, bytes hookData);

    error ZeroAmount();
    error QuoterZero();
    error QuoterFailed();
    error InsufficientOutput();
    error OnlyPoolManager();
    error DeltaIn();
    error DeltaOut();
    error PriceImpact();
    error NoPoolConfig();

    /// @dev Common to every seeded entry: dynamic-fee flag (0x800000) and tickSpacing 200.
    uint24 private constant SEED_FEE = 8388608;
    int24 private constant SEED_TICK_SPACING = 200;
    /// @dev `uint160` with leading `00` to avoid EIP-55 checksum on address-shaped literals.
    uint160 private constant SEED_WETH = 0x004200000000000000000000000000000000000006;

    constructor() {
        _seedV4PoolConfigs();
    }

    function _wethAddress() internal pure returns (address) {
        return address(SEED_WETH);
    }

    /// @dev Triton/Demeter preflight `getV4PoolConfig(WETH)` for `changeAsset(WETH)`; mirrors the ASSET/WETH pool.
    function _mirrorWethPoolConfig(PoolKey memory key, bytes memory hookData) internal {
        address w = _wethAddress();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 != w && c1 != w) return;
        v4PoolConfig[w] = V4PoolConfig({key: key, hookData: hookData});
        emit V4PoolConfigSet(w, key, hookData);
    }

    function _setV4PoolConfig(address assetAddress, PoolKey memory key, bytes memory hookData) internal {
        require(assetAddress != address(0), "asset=0");
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        require(assetAddress == c0 || assetAddress == c1, "asset !in key");
        v4PoolConfig[assetAddress] = V4PoolConfig({key: key, hookData: hookData});
        emit V4PoolConfigSet(assetAddress, key, hookData);
        if (assetAddress != _wethAddress()) {
            _mirrorWethPoolConfig(key, hookData);
        }
    }

    function _getV4PoolConfig(address assetAddress)
        internal
        view
        returns (PoolKey memory key, bytes memory hookData)
    {
        V4PoolConfig storage cfg = v4PoolConfig[assetAddress];
        if (Currency.unwrap(cfg.key.currency0) == address(0) && Currency.unwrap(cfg.key.currency1) == address(0)) {
            revert NoPoolConfig();
        }
        key = cfg.key;
        hookData = cfg.hookData;
    }

    function _seed(uint160 asset, uint160 c0, uint160 c1, uint160 hooksAddr) private {
        address a = address(asset);
        v4PoolConfig[a] = V4PoolConfig({
            key: PoolKey({
                currency0: Currency.wrap(address(c0)),
                currency1: Currency.wrap(address(c1)),
                fee: SEED_FEE,
                tickSpacing: SEED_TICK_SPACING,
                hooks: IHooks(address(hooksAddr))
            }),
            hookData: ""
        });
        emit V4PoolConfigSet(a, v4PoolConfig[a].key, "");
        _mirrorWethPoolConfig(v4PoolConfig[a].key, "");
    }

    /// @dev Pre-registers Base Clanker / Doppler-style v4 hooked pools (parity with `FloatSwapRouterV4`).
    function _seedV4PoolConfigs() private {
        // 1  SAIRI
        _seed(0x00de61878b0b21ce395266c44d4d548d1c72a3eb07, SEED_WETH, 0x00de61878b0b21ce395266c44d4d548d1c72a3eb07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 2  MiroShark
        _seed(0x00d7bc6a05a56655fb2052f742b012d1dfd66e1ba3, SEED_WETH, 0x00d7bc6a05a56655fb2052f742b012d1dfd66e1ba3, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 3  EDGE
        _seed(0x0062abe92f50c518165a5c010fe59f35023197fba3, SEED_WETH, 0x0062abe92f50c518165a5c010fe59f35023197fba3, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 4  Litcoin (asset < WETH)
        _seed(0x00316ffb9c875f900adcf04889e415cc86b564eba3, 0x00316ffb9c875f900adcf04889e415cc86b564eba3, SEED_WETH, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 5  LienFi (asset < WETH)
        _seed(0x003722264ab15a1dfce5a5af89e6547f7949a8aba3, 0x003722264ab15a1dfce5a5af89e6547f7949a8aba3, SEED_WETH, 0x00bdf938149ac6a781f94faa0ed45e6a0e984c6544);
        // 6  ClawBank (asset < WETH)
        _seed(0x0016332535e2c27da578bc2e82beb09ce9d3c8eb07, 0x0016332535e2c27da578bc2e82beb09ce9d3c8eb07, SEED_WETH, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 7  gitlawb
        _seed(0x005f980dcfc4c0fa3911554cf5ab288ed0eb13dba3, SEED_WETH, 0x005f980dcfc4c0fa3911554cf5ab288ed0eb13dba3, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 8  Helixa Cred
        _seed(0x00ab3f23c2abcb4e12cc8b593c218a7ba64ed17ba3, SEED_WETH, 0x00ab3f23c2abcb4e12cc8b593c218a7ba64ed17ba3, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 9  CLAWNCH
        _seed(0x00a1f72459dfa10bad200ac160ecd78c6b77a747be, SEED_WETH, 0x00a1f72459dfa10bad200ac160ecd78c6b77a747be, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 10 Moltbook
        _seed(0x00b695559b26bb2c9703ef1935c37aeae9526bab07, SEED_WETH, 0x00b695559b26bb2c9703ef1935c37aeae9526bab07, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 11 nookplot
        _seed(0x00b233bdffd437e60fa451f62c6c09d3804d285ba3, SEED_WETH, 0x00b233bdffd437e60fa451f62c6c09d3804d285ba3, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 12 Hermes OS
        _seed(0x0095ccfd2b81a9667b0cc979992632f98fc853eba3, SEED_WETH, 0x0095ccfd2b81a9667b0cc979992632f98fc853eba3, 0x00bdf938149ac6a781f94faa0ed45e6a0e984c6544);
        // 13 KellyClaude
        _seed(0x0050d2280441372486beecdd328c1854743ebacb07, SEED_WETH, 0x0050d2280441372486beecdd328c1854743ebacb07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 14 Juno Agent
        _seed(0x004e6c9f48f73e54ee5f3ab7e2992b2d733d0d0b07, SEED_WETH, 0x004e6c9f48f73e54ee5f3ab7e2992b2d733d0d0b07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 16 Darksol (asset < WETH)
        _seed(0x0000cb1fbca324d51325a7264d54072bc073c28ba3, 0x0000cb1fbca324d51325a7264d54072bc073c28ba3, SEED_WETH, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 18 Doppel
        _seed(0x00f27b8ef47842e6445e37804896f1bc5e29381b07, SEED_WETH, 0x00f27b8ef47842e6445e37804896f1bc5e29381b07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 19 FELIX
        _seed(0x00f30bf00edd0c22db54c9274b90d2a4c21fc09b07, SEED_WETH, 0x00f30bf00edd0c22db54c9274b90d2a4c21fc09b07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 20 BitVault Signal
        _seed(0x00d88fd4a11255e51f64f78b4a7d74456325c2d8dc, SEED_WETH, 0x00d88fd4a11255e51f64f78b4a7d74456325c2d8dc, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 21 clawd.atg.eth
        _seed(0x009f86db9fc6f7c9408e8fda3ff8ce4e78ac7a6b07, SEED_WETH, 0x009f86db9fc6f7c9408e8fda3ff8ce4e78ac7a6b07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 22 Molten
        _seed(0x0059c0d5c34c301ac0600147924d6c9be22a2f0b07, SEED_WETH, 0x0059c0d5c34c301ac0600147924d6c9be22a2f0b07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 23 BOTCOIN
        _seed(0x00a601877977340862ca67f816eb079958e5bd0ba3, SEED_WETH, 0x00a601877977340862ca67f816eb079958e5bd0ba3, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 24 Regent
        _seed(0x006f89bca4ea5931edfcb09786267b251dee752b07, SEED_WETH, 0x006f89bca4ea5931edfcb09786267b251dee752b07, 0x00d60d6b218116cfd801e28f78d011a203d2b068cc);
        // 25 SelfClaw
        _seed(0x009ae5f51d81ff510bf961218f833f79d57bfbab07, SEED_WETH, 0x009ae5f51d81ff510bf961218f833f79d57bfbab07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 26 machines-cash
        _seed(0x007f6f8bb1aa8206921e80ab6abf1ac5737e39ab07, SEED_WETH, 0x007f6f8bb1aa8206921e80ab6abf1ac5737e39ab07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 27 Cody (asset < WETH)
        _seed(0x003977fc913db86b01a257232c568317798b903b07, 0x003977fc913db86b01a257232c568317798b903b07, SEED_WETH, 0x0034a45c6b61876d739400bd71228cbcbd4f53e8cc);
    }

    function _swapExactInputSingleStrict(
        address assetAddress,
        bool zeroForOne,
        uint128 amountIn,
        address payer,
        address recipient
    ) internal returns (uint256 amountOut) {
        (PoolKey memory key, bytes memory hookData) = _getV4PoolConfig(assetAddress);

        PoolId poolId = PoolIdLibrary.toId(key);
        (uint160 sqrtBefore,,,) = StateLibrary.getSlot0(poolManager, poolId);
        require(sqrtBefore != 0, "pool !init");

        uint128 minOut = _minOutFromV4Quoter(key, zeroForOne, amountIn, hookData, strictStrategySlippageBps);

        amountOut = _swapV4Direct(
            key,
            zeroForOne,
            amountIn,
            minOut,
            zeroForOne ? UniV4TickMath.MIN_SQRT_PRICE + 1 : UniV4TickMath.MAX_SQRT_PRICE - 1,
            hookData,
            payer,
            recipient
        );

        (uint160 sqrtAfter,,,) = StateLibrary.getSlot0(poolManager, poolId);
        _requirePriceImpactBound(sqrtBefore, sqrtAfter, zeroForOne);
    }

    /// @dev Tokens already on `address(this)`; no ERC20 approvals to a separate router.
    function _swapExactInputSingleStrictInternal(
        address assetAddress,
        bool zeroForOne,
        uint128 amountIn
    ) internal returns (uint256 amountOut) {
        return _swapExactInputSingleStrict(assetAddress, zeroForOne, amountIn, address(this), address(this));
    }

    function _swapV4Direct(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        uint160 sqrtPriceLimitX96,
        bytes memory hookData,
        address payer,
        address recipient
    ) internal returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();

        address tokenIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        address tokenOut = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);

        if (payer != address(this)) {
            IERC20(tokenIn).safeTransferFrom(payer, address(this), amountIn);
        }

        bytes memory data = abi.encode(recipient, key, zeroForOne, int256(uint256(amountIn)), sqrtPriceLimitX96, hookData);

        uint256 balBefore = IERC20(tokenOut).balanceOf(recipient);
        poolManager.unlock(data);
        amountOut = IERC20(tokenOut).balanceOf(recipient) - balBefore;

        if (amountOut < minAmountOut) revert InsufficientOutput();
        emit SwapExecuted(msg.sender, recipient, tokenIn, tokenOut, amountIn, amountOut);
    }

    function _minOutFromV4Quoter(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        bytes memory hookData,
        uint16 slippageBps
    ) internal returns (uint128 minOut) {
        try v4Quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                exactAmount: amountIn,
                hookData: hookData
            })
        ) returns (uint256 quoted, uint256) {
            if (quoted == 0) revert QuoterZero();
            minOut = uint128(Math.mulDiv(quoted, 10_000 - uint256(slippageBps), 10_000));
        } catch {
            revert QuoterFailed();
        }
    }

    function _requirePriceImpactBound(uint160 sqrtBefore, uint160 sqrtAfter, bool zeroForOne) internal view {
        uint256 diff = zeroForOne
            ? (sqrtBefore > sqrtAfter ? uint256(sqrtBefore - sqrtAfter) : 0)
            : (sqrtAfter > sqrtBefore ? uint256(sqrtAfter - sqrtBefore) : 0);
        uint256 bps = (diff * 10_000) / uint256(sqrtBefore);
        if (bps > uint256(maxPriceImpactBps)) revert PriceImpact();
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        (
            address recipient,
            PoolKey memory key,
            bool zeroForOne,
            int256 amountIn,
            uint160 sqrtPriceLimitX96,
            bytes memory hookData
        ) = abi.decode(data, (address, PoolKey, bool, int256, uint160, bytes));

        Currency inC = zeroForOne ? key.currency0 : key.currency1;
        Currency outC = zeroForOne ? key.currency1 : key.currency0;

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -amountIn, sqrtPriceLimitX96: sqrtPriceLimitX96}),
            hookData
        );

        int128 deltaIn = zeroForOne ? delta.amount0() : delta.amount1();
        int128 deltaOut = zeroForOne ? delta.amount1() : delta.amount0();
        if (deltaIn > 0) revert DeltaIn();
        if (deltaOut < 0) revert DeltaOut();

        uint256 owed = uint256(uint128(-deltaIn));
        uint256 received = uint256(uint128(deltaOut));

        poolManager.sync(inC);
        IERC20(Currency.unwrap(inC)).safeTransfer(address(poolManager), owed);
        poolManager.settle();

        poolManager.take(outC, recipient, received);

        return "";
    }
}
