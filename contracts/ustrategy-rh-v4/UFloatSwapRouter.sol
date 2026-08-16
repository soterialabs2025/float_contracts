// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

import {IPoolManager} from "../../lib/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "../../lib/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "../../lib/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "../../lib/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "../../lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "../../lib/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../../lib/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "../../lib/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "../../lib/v4-core/src/libraries/TickMath.sol";
import {IV4Quoter} from "../../lib/v4-periphery/src/interfaces/IV4Quoter.sol";

import "./interfaces/IUFloatV4StrategySwapRouter.sol";
import "./V4Deployments4663.sol";

/// @title UfloatSwapRouter
/// @notice v4 swap router for standalone `UfloatStrategy` contracts. Pool configs are owner-set;
///         only allowlisted strategy addresses may call swap entrypoints (strict swap for rebalances).
/// @dev    Robinhood (4663) — infra addresses from `V4Deployments4663`. ASSET/aeWETH PoolKeys only (no native ETH).
contract UFloatSwapRouter is IUFloatV4StrategySwapRouter, IUnlockCallback, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────────
    // Immutable infra (Robinhood mainnet)
    // ─────────────────────────────────────────────────────────────────────────────

    IPoolManager public immutable poolManager = IPoolManager(V4Deployments4663.POOL_MANAGER);
    IV4Quoter public immutable v4Quoter = IV4Quoter(V4Deployments4663.QUOTER);

    // ─────────────────────────────────────────────────────────────────────────────
    // Configurable params
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Hard cap on per-call slippage haircuts (bps); also bounds `setStrictStrategySlippageBps`.
    uint16 public maxSlippageBps = 1_000;
    /// @notice Slippage haircut (bps) applied on quoter-derived `minOut` for `swapExactInputSingleQuoter` / `swapExactInputSingleStrict`.
    uint16 public strictStrategySlippageBps = 200;
    /// @notice Max permissible price impact (bps) for `swapExactInputSingleStrict`. Default 300 = 3%.
    uint16 public maxPriceImpactBps = 300;

    // ─────────────────────────────────────────────────────────────────────────────
    // Per-asset v4 pool registry
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Per-asset v4 pool config registered by owner or `configManager`. `key.currency0`/`currency1` MUST include `assetAddress`.
    struct V4PoolConfig {
        PoolKey key;
        bytes hookData;
    }
    mapping(address => V4PoolConfig) public v4PoolConfig;
    /// @notice Enumeratable asset list for frontends (`getRegisteredAssets`).
    address[] private _registeredAssets;
    /// @notice 1-based index in `_registeredAssets`; 0 means not listed.
    mapping(address => uint256) private _registeredAssetIndex;

    /// @notice O(1) membership for authorized `UfloatStrategy` swap callers.
    mapping(address => bool) public isAuthorizedStrategy;
    /// @notice Enumeratable list for frontends (`getAuthorizedStrategies`).
    address[] private _authorizedStrategies;
    /// @notice 1-based index in `_authorizedStrategies`; 0 means not listed.
    mapping(address => uint256) private _authorizedStrategyIndex;
    /// @notice `UfloatStrategyFactory` may register newly deployed strategies on the swap allowlist.
    address public strategyFactory;

    // ─────────────────────────────────────────────────────────────────────────────
    // Events / errors
    // ─────────────────────────────────────────────────────────────────────────────

    event SwapExecuted(
        address indexed caller, address indexed recipient, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut
    );
    event V4PoolConfigSet(address indexed asset, PoolKey key, bytes hookData);
    event V4PoolConfigRemoved(address indexed asset);
    event StrictStrategySlippageBpsUpdated(uint16 strictStrategySlippageBps);
    event MaxPriceImpactBpsUpdated(uint16 maxPriceImpactBps);
    event MaxSlippageBpsUpdated(uint16 maxSlippageBps);
    event AuthorizedStrategyAdded(address indexed strategy);
    event AuthorizedStrategyRemoved(address indexed strategy);
    event StrategyFactoryUpdated(address indexed factory);

    error ZeroAmount();
    error ZeroAddress();
    error Unauthorized();
    error AlreadyAuthorized();
    error NotAuthorized();
    error BpsOutOfRange();
    error SlippageExceedsMax();
    error AssetNotInKey();
    error PoolKeyInvalid();
    error AssetNotRegistered();
    error NoPoolConfig();
    error PoolNotInitialized();
    error InsufficientOutput();
    error QuoterZero();
    error QuoterFailed();
    error PriceImpactTooHigh();
    error OnlyPoolManager();
    error InvalidDeltaIn();
    error InvalidDeltaOut();

    constructor() Ownable(_msgSender()) {
        _seedV4PoolConfigs();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Pool registry helpers (no constructor seeds on RH — use setV4PoolConfig)
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev aeWETH as uint160 with leading `00` to bypass Solidity EIP-55 checksum on address-shaped literals.
    uint160 private constant SEED_WETH = 0x000Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    /// @dev Ensures `currency0 < currency1` and the pair is `asset`/aeWETH (matches strategy `_poolKeyFromRouter`).
    ///      Rejects native ETH `address(0)` currencies — RH UFloat is ASSET/aeWETH only.
    function _normalizePoolKey(address assetAddress, PoolKey memory key) internal pure returns (PoolKey memory) {
        address weth = address(SEED_WETH);
        if (assetAddress == address(0) || assetAddress == weth) revert ZeroAddress();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 == address(0) || c1 == address(0) || c0 == c1) revert PoolKeyInvalid();
        if (assetAddress != c0 && assetAddress != c1) revert AssetNotInKey();
        address other = assetAddress == c0 ? c1 : c0;
        if (other != weth) revert PoolKeyInvalid();
        (Currency sorted0, Currency sorted1) = assetAddress < weth
            ? (Currency.wrap(assetAddress), Currency.wrap(weth))
            : (Currency.wrap(weth), Currency.wrap(assetAddress));
        return PoolKey({
            currency0: sorted0,
            currency1: sorted1,
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: key.hooks
        });
    }

    function _registerAsset(address asset) private {
        if (asset == address(0) || _registeredAssetIndex[asset] != 0) return;
        _registeredAssets.push(asset);
        _registeredAssetIndex[asset] = _registeredAssets.length;
    }

    function _unregisterAsset(address asset) private {
        uint256 idx = _registeredAssetIndex[asset];
        if (idx == 0) revert AssetNotRegistered();
        uint256 last = _registeredAssets.length;
        if (idx != last) {
            address moved = _registeredAssets[last - 1];
            _registeredAssets[idx - 1] = moved;
            _registeredAssetIndex[moved] = idx;
        }
        _registeredAssets.pop();
        delete _registeredAssetIndex[asset];
    }

    /// @dev No Base Clanker/Doppler seeds on Robinhood. Owner registers pools via `setV4PoolConfig`.
    function _seedV4PoolConfigs() private {}

    // ─────────────────────────────────────────────────────────────────────────────
    // Authorized UfloatStrategy gating
    // ─────────────────────────────────────────────────────────────────────────────

    modifier onlyAuthorizedStrategy() {
        if (!isAuthorizedStrategy[_msgSender()]) revert Unauthorized();
        _;
    }

    modifier onlyOwnerOrStrategyFactory() {
        address s = _msgSender();
        if (s != owner() && s != strategyFactory) revert Unauthorized();
        _;
    }

    function setStrategyFactory(address factory) external onlyOwner {
        strategyFactory = factory;
        emit StrategyFactoryUpdated(factory);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Owner setters
    // ─────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IUFloatV4StrategySwapRouter
    function addAuthorizedStrategy(address strategy) external onlyOwnerOrStrategyFactory {
        if (strategy == address(0)) revert ZeroAddress();
        if (isAuthorizedStrategy[strategy]) revert AlreadyAuthorized();
        isAuthorizedStrategy[strategy] = true;
        _authorizedStrategies.push(strategy);
        _authorizedStrategyIndex[strategy] = _authorizedStrategies.length;
        emit AuthorizedStrategyAdded(strategy);
    }

    /// @inheritdoc IUFloatV4StrategySwapRouter
    function removeAuthorizedStrategy(address strategy) external onlyOwner {
        uint256 idx = _authorizedStrategyIndex[strategy];
        if (idx == 0) revert NotAuthorized();
        uint256 last = _authorizedStrategies.length;
        if (idx != last) {
            address moved = _authorizedStrategies[last - 1];
            _authorizedStrategies[idx - 1] = moved;
            _authorizedStrategyIndex[moved] = idx;
        }
        _authorizedStrategies.pop();
        delete _authorizedStrategyIndex[strategy];
        delete isAuthorizedStrategy[strategy];
        emit AuthorizedStrategyRemoved(strategy);
    }

    /// @inheritdoc IUFloatV4StrategySwapRouter
    function getAuthorizedStrategies() external view returns (address[] memory) {
        return _authorizedStrategies;
    }

    function setMaxSlippageBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > 5_000) revert BpsOutOfRange();
        maxSlippageBps = bps;
        emit MaxSlippageBpsUpdated(bps);
    }

    function setStrictStrategySlippageBps(uint16 bps) external onlyOwner {
        if (bps > maxSlippageBps) revert SlippageExceedsMax();
        strictStrategySlippageBps = bps;
        emit StrictStrategySlippageBpsUpdated(bps);
    }

    function setMaxPriceImpactBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > 5_000) revert BpsOutOfRange();
        maxPriceImpactBps = bps;
        emit MaxPriceImpactBpsUpdated(bps);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Pool registry
    // ─────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IUFloatV4StrategySwapRouter
    function setV4PoolConfig(address assetAddress, PoolKey calldata key, bytes calldata hookData) external override onlyOwner {
        if (assetAddress == address(0)) revert ZeroAddress();
        PoolKey memory normalized = _normalizePoolKey(assetAddress, key);
        v4PoolConfig[assetAddress] = V4PoolConfig({key: normalized, hookData: hookData});
        _registerAsset(assetAddress);
        emit V4PoolConfigSet(assetAddress, normalized, hookData);
    }

    /// @inheritdoc IUFloatV4StrategySwapRouter
    function removeV4PoolConfig(address assetAddress) external override onlyOwner {
        if (assetAddress == address(0)) revert ZeroAddress();
        if (!hasV4PoolConfig(assetAddress)) revert NoPoolConfig();
        delete v4PoolConfig[assetAddress];
        _unregisterAsset(assetAddress);
        emit V4PoolConfigRemoved(assetAddress);
    }

    /// @inheritdoc IUFloatV4StrategySwapRouter
    function getRegisteredAssets() external view returns (address[] memory) {
        return _registeredAssets;
    }

    /// @inheritdoc IUFloatV4StrategySwapRouter
    function registeredAssetCount() external view returns (uint256) {
        return _registeredAssets.length;
    }

    /// @inheritdoc IUFloatV4StrategySwapRouter
    function getV4PoolConfig(address assetAddress) public view override returns (PoolKey memory key, bytes memory hookData) {
        V4PoolConfig storage cfg = v4PoolConfig[assetAddress];
        if (Currency.unwrap(cfg.key.currency0) == address(0) && Currency.unwrap(cfg.key.currency1) == address(0)) {
            revert NoPoolConfig();
        }
        key = _normalizePoolKey(assetAddress, cfg.key);
        hookData = cfg.hookData;
    }

    /// @inheritdoc IUFloatV4StrategySwapRouter
    function hasV4PoolConfig(address assetAddress) public view override returns (bool) {
        V4PoolConfig storage cfg = v4PoolConfig[assetAddress];
        return Currency.unwrap(cfg.key.currency0) != address(0) || Currency.unwrap(cfg.key.currency1) != address(0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Asset-registry swap entrypoints (strategy)
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Single-hop v4 exact-in via direct `PoolManager.unlock`. Slippage enforced by `minAmountOut`.
    /// @dev Uses widest possible price limit (`MIN_SQRT_PRICE+1` for `zeroForOne`, else `MAX_SQRT_PRICE-1`),
    ///      same as `V4Router._swap`. `(PoolKey, hookData)` looked up from `v4PoolConfig[assetAddress]`.
    function swapExactInputSingle(
        address assetAddress,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut
    ) external onlyAuthorizedStrategy nonReentrant returns (uint256 amountOut) {
        (PoolKey memory key, bytes memory hookData) = getV4PoolConfig(assetAddress);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return _swapV4Direct(key, zeroForOne, amountIn, minAmountOut, limit, hookData, _msgSender());
    }

    /// @notice Same as `swapExactInputSingle` but caller chooses an explicit `sqrtPriceLimitX96`.
    /// @param sqrtPriceLimitX96 For `zeroForOne` must satisfy `MIN_SQRT_PRICE < limit < currentSqrtPriceX96`,
    ///        otherwise must satisfy `currentSqrtPriceX96 < limit < MAX_SQRT_PRICE`.
    function swapV4Direct(
        address assetAddress,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        uint160 sqrtPriceLimitX96
    ) external onlyAuthorizedStrategy nonReentrant returns (uint256 amountOut) {
        (PoolKey memory key, bytes memory hookData) = getV4PoolConfig(assetAddress);
        return _swapV4Direct(key, zeroForOne, amountIn, minAmountOut, sqrtPriceLimitX96, hookData, _msgSender());
    }

    /// @notice v4 swap with quoter-derived slippage (`strictStrategySlippageBps`). NOT MEV-resistant on its own.
    function swapExactInputSingleQuoter(
        address assetAddress,
        bool zeroForOne,
        uint128 amountIn
    ) external onlyAuthorizedStrategy nonReentrant returns (uint256 amountOut) {
        (PoolKey memory key, bytes memory hookData) = getV4PoolConfig(assetAddress);
        uint128 minOut = _minOutFromV4Quoter(key, zeroForOne, amountIn, hookData, strictStrategySlippageBps);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return _swapV4Direct(key, zeroForOne, amountIn, minOut, limit, hookData, _msgSender());
    }

    /// @inheritdoc IUFloatV4StrategySwapRouter
    /// @dev Quoter-derived `minOut` (`strictStrategySlippageBps`) PLUS post-swap `sqrtPriceX96` impact bound (`maxPriceImpactBps`).
    function swapExactInputSingleStrict(
        address assetAddress,
        bool zeroForOne,
        uint128 amountIn
    ) external override onlyAuthorizedStrategy nonReentrant returns (uint256 amountOut) {
        (PoolKey memory key, bytes memory hookData) = getV4PoolConfig(assetAddress);

        PoolId poolId = PoolIdLibrary.toId(key);
        (uint160 sqrtBefore, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtBefore == 0) revert PoolNotInitialized();

        uint128 minOut = _minOutFromV4Quoter(key, zeroForOne, amountIn, hookData, strictStrategySlippageBps);

        amountOut = _swapV4Direct(
            key,
            zeroForOne,
            amountIn,
            minOut,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            hookData,
            _msgSender()
        );

        (uint160 sqrtAfter, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        _requirePriceImpactBound(sqrtBefore, sqrtAfter, zeroForOne);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Pulls `amountIn` of input token from `_msgSender()`, calls `unlock`, settles in the callback,
    ///      then asserts `amountOut >= minAmountOut` from `recipient`'s balance delta.
    function _swapV4Direct(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        uint160 sqrtPriceLimitX96,
        bytes memory hookData,
        address recipient
    ) private returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();

        address tokenIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        address tokenOut = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);

        IERC20(tokenIn).safeTransferFrom(_msgSender(), address(this), amountIn);

        bytes memory data = abi.encode(
            recipient,
            key,
            zeroForOne,
            int256(uint256(amountIn)),
            sqrtPriceLimitX96,
            hookData
        );

        uint256 balBefore = IERC20(tokenOut).balanceOf(recipient);
        poolManager.unlock(data);
        amountOut = IERC20(tokenOut).balanceOf(recipient) - balBefore;

        if (amountOut < minAmountOut) revert InsufficientOutput();
        emit SwapExecuted(_msgSender(), recipient, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @dev `quoteExactInputSingle` is `external` (not view) — wrap in try/catch so a hook that gates the quoter
    ///      surfaces a clear `"quoter failed"` instead of an opaque revert. Reverts on `quoted == 0`.
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

    /// @dev `|sqrtBefore - sqrtAfter| / sqrtBefore` in bps, must be ≤ `maxPriceImpactBps`. Direction-aware: on
    ///      `zeroForOne` price decreases (`sqrtBefore > sqrtAfter`); otherwise it increases. A move in the
    ///      "wrong" direction has zero diff and silently passes (would only happen with hook-side adjustments).
    function _requirePriceImpactBound(uint160 sqrtBefore, uint160 sqrtAfter, bool zeroForOne) internal view {
        uint256 diff = zeroForOne
            ? (sqrtBefore > sqrtAfter ? uint256(sqrtBefore - sqrtAfter) : 0)
            : (sqrtAfter > sqrtBefore ? uint256(sqrtAfter - sqrtBefore) : 0);
        uint256 bps = (diff * 10_000) / uint256(sqrtBefore);
        if (bps > uint256(maxPriceImpactBps)) revert PriceImpactTooHigh();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // PoolManager unlock callback
    // ─────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IUnlockCallback
    /// @dev Decodes `(recipient, key, zeroForOne, amountIn, sqrtPriceLimitX96, hookData)`, calls `poolManager.swap`,
    ///      settles input via `sync`+`transfer`+`settle`, and `take`s output to `recipient`. Only callable by `poolManager`.
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
        if (deltaIn > 0) revert InvalidDeltaIn();
        if (deltaOut < 0) revert InvalidDeltaOut();

        uint256 owed = uint256(uint128(-deltaIn));
        uint256 received = uint256(uint128(deltaOut));

        poolManager.sync(inC);
        IERC20(Currency.unwrap(inC)).safeTransfer(address(poolManager), owed);
        poolManager.settle();

        poolManager.take(outC, recipient, received);

        return "";
    }
}
