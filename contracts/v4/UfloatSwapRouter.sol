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
import "./V4Deployments8453.sol";

/// @title UfloatSwapRouter
/// @notice v4 swap router for standalone `UfloatStrategy` contracts. Pool configs are owner-set;
///         only allowlisted strategy addresses may call swap entrypoints (strict swap for rebalances).
/// @dev    Base (8453) only — infra addresses from `V4Deployments8453`.
contract UFloatSwapRouter is IUFloatV4StrategySwapRouter, IUnlockCallback, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────────
    // Immutable infra (Base mainnet)
    // ─────────────────────────────────────────────────────────────────────────────

    IPoolManager public immutable poolManager = IPoolManager(V4Deployments8453.POOL_MANAGER);
    IV4Quoter public immutable v4Quoter = IV4Quoter(V4Deployments8453.QUOTER);

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
    // Hard-coded pool registry (Base Clanker / Doppler-style v4 hooked pools)
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Common to every seeded entry: dynamic-fee flag (0x800000) and tickSpacing 200.
    uint24  private constant SEED_FEE          = 8388608;
    int24   private constant SEED_TICK_SPACING = 200;
    /// @dev Stored as `uint160` (with leading `00` prepended to the literal) so we don't trip Solidity's
    ///      EIP-55 checksum validation, which fires on any 40-hex-digit address-shaped literal.
    uint160 private constant SEED_WETH         = 0x004200000000000000000000000000000000000006;

    /// @dev Single-entry registrar used by `_seedV4PoolConfigs`. Args are typed as `uint160` and call sites
    ///      prepend a `00` to each 40-digit hex literal (making it 42 digits → not address-shaped) so we
    ///      avoid Solidity's strict EIP-55 checksum requirement on `0x...` literals. Currency order is
    ///      derived automatically (currency0 < currency1). `hookData` is intentionally empty for all seeded
    ///      pools — new entries (or override of an existing entry's hookData) go through `setV4PoolConfig`
    ///      (owner / configManager).
    function _seed(uint160 asset, uint160 hooksAddr) private {
        address a = address(asset);
        address w = address(SEED_WETH);
        if (a == w) revert ZeroAddress();
        (Currency c0, Currency c1) = a < w
            ? (Currency.wrap(a), Currency.wrap(w))
            : (Currency.wrap(w), Currency.wrap(a));
        v4PoolConfig[a] = V4PoolConfig({
            key: PoolKey({
                currency0:   c0,
                currency1:   c1,
                fee:         SEED_FEE,
                tickSpacing: SEED_TICK_SPACING,
                hooks:       IHooks(address(hooksAddr))
            }),
            hookData: ""
        });
        emit V4PoolConfigSet(a, v4PoolConfig[a].key, "");
        _registerAsset(a);
    }

    /// @dev Ensures `currency0 < currency1` and the pair is `asset`/WETH (matches `_seed` and strategy `_poolKeyFromRouter`).
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

    /// @dev Pre-registers every Float-eligible v4 pool. All seeded pools use the `0x800000` dynamic-fee flag
    ///      and tickSpacing 200; only currencies + hook address vary. Each address literal is prefixed with
    ///      `00` (so it's 42 hex digits, not 40) to bypass Solidity's EIP-55 checksum validation.
    function _seedV4PoolConfigs() private {
        // 1  SAIRI
        _seed(0x00de61878b0b21ce395266c44d4d548d1c72a3eb07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 2  MiroShark
        _seed(0x00d7bc6a05a56655fb2052f742b012d1dfd66e1ba3, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 3  EDGE
        _seed(0x0062abe92f50c518165a5c010fe59f35023197fba3, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 4  Litcoin (asset < WETH)
        _seed(0x00316ffb9c875f900adcf04889e415cc86b564eba3, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 5  LienFi (asset < WETH)
        _seed(0x003722264ab15a1dfce5a5af89e6547f7949a8aba3, 0x00bdf938149ac6a781f94faa0ed45e6a0e984c6544);
        // 6  ClawBank (asset < WETH)
        _seed(0x0016332535e2c27da578bc2e82beb09ce9d3c8eb07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 7  gitlawb
        _seed(0x005f980dcfc4c0fa3911554cf5ab288ed0eb13dba3, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 8  Helixa Cred
        _seed(0x00ab3f23c2abcb4e12cc8b593c218a7ba64ed17ba3, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 9  CLAWNCH
        _seed(0x00a1f72459dfa10bad200ac160ecd78c6b77a747be, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 10 Moltbook
        _seed(0x00b695559b26bb2c9703ef1935c37aeae9526bab07, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 11 nookplot
        _seed(0x00b233bdffd437e60fa451f62c6c09d3804d285ba3, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 12 Hermes OS
        _seed(0x0095ccfd2b81a9667b0cc979992632f98fc853eba3, 0x00bdf938149ac6a781f94faa0ed45e6a0e984c6544);
        // 13 KellyClaude
        _seed(0x0050d2280441372486beecdd328c1854743ebacb07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 14 Juno Agent
        _seed(0x004e6c9f48f73e54ee5f3ab7e2992b2d733d0d0b07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 16 Darksol (asset < WETH)
        _seed(0x0000cb1fbca324d51325a7264d54072bc073c28ba3, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 18 Doppel
        _seed(0x00f27b8ef47842e6445e37804896f1bc5e29381b07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 19 FELIX
        _seed(0x00f30bf00edd0c22db54c9274b90d2a4c21fc09b07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 20 BitVault Signal
        _seed(0x00d88fd4a11255e51f64f78b4a7d74456325c2d8dc, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 21 clawd.atg.eth
        _seed(0x009f86db9fc6f7c9408e8fda3ff8ce4e78ac7a6b07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 22 Molten
        _seed(0x0059c0d5c34c301ac0600147924d6c9be22a2f0b07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 23 BOTCOIN
        _seed(0x00a601877977340862ca67f816eb079958e5bd0ba3, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 24 Regent
        _seed(0x006f89bca4ea5931edfcb09786267b251dee752b07, 0x00d60d6b218116cfd801e28f78d011a203d2b068cc);
        // 25 SelfClaw
        _seed(0x009ae5f51d81ff510bf961218f833f79d57bfbab07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 26 machines-cash
        _seed(0x007f6f8bb1aa8206921e80ab6abf1ac5737e39ab07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 27 Cody (asset < WETH)
        _seed(0x003977fc913db86b01a257232c568317798b903b07, 0x0034a45c6b61876d739400bd71228cbcbd4f53e8cc);
       // 28 GitBank (asset < WETH)
        _seed(0x00c21dd0ee043930711c2a3e55f39c7d3144d09b07, 0x00b429d62f8f3bffb98cdb9569533ea23bf0ba28cc);
        // 29 Supergemma4 (asset < WETH)
        _seed(0x00572c4fa77623652411574c51b5ddb7e1b750aba3, 0x00bdf938149ac6a781f94faa0ed45e6a0e984c6544);
          // 30 grantr (asset < WETH)
        _seed(0x00753f2af0f46361c9ae6fc347797f99b0c9e82ba3, 0x00bdf938149ac6a781f94faa0ed45e6a0e984c6544);
        // 31 wake (asset < WETH)
        _seed(0x0050c2cc97c4f487aa0cd742ab4b6afe8b8511bba3, 0x00bdf938149ac6a781f94faa0ed45e6a0e984c6544);
          // 29 aeon (WETH < asset)
        _seed(0x00bf8e8f0e8866a7052f948c16508644347c57aba3, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
        // 30 Berry Finance (WETH < asset)
        _seed(0x00778d347b2ffbadf31a2a1be9cf42b4c7ba8b1ba3, 0x00bdf938149ac6a781f94faa0ed45e6a0e984c6544);
        // 31 Blocktronics (WETH < asset)
        _seed(0x007afe438411ee3959c7de6f7fb76bf9c769320ba3, 0x00bdf938149ac6a781f94faa0ed45e6a0e984c6544);
        // 32 Orlix AI (WETH < asset)
        _seed(0x00799c28bac95b3e0b26534d1e9a586511895ecba3, 0x00bdf938149ac6a781f94faa0ed45e6a0e984c6544);
        // 33 1claw AI (WETH < asset)
        _seed(0x0061d91cff0fc9fbbdb89f505cf8a7422bf95fdba3, 0x00bdf938149ac6a781f94faa0ed45e6a0e984c6544);
        // 34 evo- (WETH < asset)
        _seed(0x00721b072dbb616f29eea73ac004e03fd4e884bba3, 0x00bb7784a4d481184283ed89619a3e3ed143e1adc0);
          // 35 DOT (WETH < asset)
        _seed(0x0023a2847d772803f9efc64b4277b782b06296fe51, 0x000000000000000000000000000000000000000000);
    }

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
