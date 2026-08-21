// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "../../interfaces/IPoolManagerV4.sol";
import "../../libraries/LiquidityLibraryV4.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import "./LiquidSwapRouterV4.sol";
import "./interfaces/ILiquidStrategyV4.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LiquidStratMinV4
/// @notice v4 minimal liquid strategy: idle ASSET + WETH, swaps in-contract via inherited `LiquidSwapRouterV4` / `LiquidV4SwapCore`, no LP.
///         Pool state is used only for spot NAV. Modes are owner-set via `setMode`.
contract LiquidStratMinV4 is ILiquidStrategyV4, LiquidSwapRouterV4 {
    error Unauthorized();
    error ZeroValue();
    error ZeroAddress();

    using SafeERC20 for IERC20;

    IPoolManagerV4 private poolManagerV4;
    LiquidityLibraryV4.PoolKey public poolKey;
    IERC20 public ASSET;
    IERC20 private WETH;
    address private immutable baseWETH = 0x4200000000000000000000000000000000000006;
    address public assetAddr;

    uint256 public defensiveEnteredAt;
    uint256 public consecutiveOffensiveCount;
    uint256 public withdrawalFeeBps = 0;
    uint256 public constant DIVISOR = 10000;
    uint256 private constant LIQUIDITY_DUST = 1_000_000_000_000;

    event StrategyEvent(uint8 indexed eventType, uint256 indexed data1, uint256 data2, uint256 data3);
    event ModeSet(uint8 indexed newMode);

    bool public contractSetUp;

    enum Mode {
        NORMAL,
        DEFENSIVE,
        OFFENSIVE
    }
    Mode private _mode;

    function mode() external view returns (uint8) {
        return uint8(_mode);
    }

    modifier onlyAuthorized() {
        address s = _msgSender();
        if (s != vaultAddr && s != tritonAddr && s != owner()) {
            revert Unauthorized();
        }
        _;
    }

    constructor() {
        WETH = IERC20(baseWETH);
        emit StrategyEvent(0, uint256(uint160(_msgSender())), 0, 0);
    }

    /// @notice One-time setup: ASSET, vault/Triton auth, and ASSET/WETH pool from seeded `v4PoolConfig`.
    /// @dev    Overrides `LiquidSwapRouterV4.setUpContract` — first arg is the ASSET token, not an external strategy.
    ///         Pool manager is the immutable v4 `poolManager` on this contract (no separate address).
    function setUpContract(address _assetAddr, address _vaultAddr, address _tritonAddr) external override onlyOwner {
        if (_assetAddr == address(0) || _vaultAddr == address(0)) {
            revert ZeroAddress();
        }
        assetAddr = _assetAddr;
        poolManagerV4 = IPoolManagerV4(address(poolManager));
        ASSET = IERC20(_assetAddr);

        _wireRouter(address(this), _vaultAddr, _tritonAddr);

        (LiquidityLibraryV4.PoolKey memory key, bytes memory hookData) = _poolKeyFromConfig(_assetAddr);
        _applyPoolKey(_assetAddr, key, hookData);
        contractSetUp = true;
    }

    /// @notice Owner helper when supplying `LiquidityLibraryV4.PoolKey` (same layout as v4 `PoolKey` addresses).
    function setV4PoolConfigKey(
        address assetAddress,
        LiquidityLibraryV4.PoolKey calldata key,
        bytes calldata hookData
    ) external onlyOwner {
        _setV4PoolConfig(assetAddress, _toV4PoolKeyMemory(key), hookData);
        if (assetAddress == assetAddr) {
            _validateAndStorePoolKey(assetAddress, key);
        }
    }

    /// @notice Copy the active asset's v4 pool config to WETH (one-time fix for deployed strategies).
    /// @dev    Triton/Demeter require `getV4PoolConfig(WETH)` before `changeAsset(WETH)`; new configs mirror automatically.
    function ensureWethPoolConfig() external onlyOwner {
        address w = address(WETH);
        address a = assetAddr;
        if (a == address(0)) revert ZeroAddress();
        if (a == w) return;
        (PoolKey memory key, bytes memory hookData) = _getV4PoolConfig(a);
        _setV4PoolConfig(w, key, hookData);
    }

    function setMode(uint8 m) external onlyOwner {
        require(m <= uint8(Mode.OFFENSIVE), "mode");
        _applyMode(Mode(m));
    }

    function _applyMode(Mode nm) internal {
        if (nm == _mode) return;

        if (nm == Mode.DEFENSIVE) {
            consecutiveOffensiveCount = 0;
            defensiveEnteredAt = block.timestamp;
        } else if (nm == Mode.OFFENSIVE) {
            if (_mode != Mode.OFFENSIVE) {
                consecutiveOffensiveCount++;
            }
            defensiveEnteredAt = 0;
        } else {
            defensiveEnteredAt = 0;
        }
        _mode = nm;
        emit ModeSet(uint8(nm));
    }

    function beforeDeposit() external override onlyAuthorized {}

    /// @dev Vault forwards WETH then calls this. In DEFENSIVE, WETH stays idle on the contract (no ASSET buy).
    function deposit(uint256 amount) external override onlyAuthorized nonReentrant {
        if (amount == 0) revert ZeroValue();
        if (_mode != Mode.DEFENSIVE) {
            _convertAllWethToAsset();
        }
        emit StrategyEvent(1, vaultValue(), 0, uint256(uint8(_mode)));
    }

    function withdraw(uint256 userShares, uint256 totalSupply_, address receiver)
        external
        override
        onlyAuthorized
        nonReentrant
    {
        if (userShares == 0) revert ZeroValue();
        if (totalSupply_ == 0) revert ZeroValue();
        if (receiver == address(0)) revert ZeroAddress();

        bool wethOnly = address(ASSET) == address(WETH);
        uint256 idleAssetBefore = wethOnly ? 0 : ASSET.balanceOf(address(this));
        uint256 idleWethBefore = WETH.balanceOf(address(this));

        uint256 userIdleAsset = Math.mulDiv(idleAssetBefore, userShares, totalSupply_);
        uint256 userIdleWeth = Math.mulDiv(idleWethBefore, userShares, totalSupply_);

        uint256 totalUserAsset = userIdleAsset;
        uint256 totalUserWeth = userIdleWeth;

        uint256 assetFee = Math.mulDiv(totalUserAsset, withdrawalFeeBps, DIVISOR);
        uint256 wethFee = Math.mulDiv(totalUserWeth, withdrawalFeeBps, DIVISOR);
        totalUserAsset -= assetFee;
        totalUserWeth -= wethFee;

        if (!wethOnly && totalUserAsset > 0) {
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
        emit StrategyEvent(2, vaultValue(), 0, 0);
    }

    function _convertAllWethToAsset() internal {
        uint256 w = WETH.balanceOf(address(this));
        if (w > 0) {
            _swap(WETH, w);
        }
    }

    function _spotPrice1e18() internal view returns (uint256) {
        (uint160 sqrtP,) = LiquidityLibraryV4.getSlot0Safe(poolManagerV4, poolKey);
        if (sqrtP == 0) return 0;
        address p0 = poolKey.currency0;
        uint256 price = Math.mulDiv(uint256(sqrtP), uint256(sqrtP), (uint256(1) << 192) / 1e18);
        if (p0 == address(WETH)) {
            return price;
        }
        if (price == 0) return 0;
        return Math.mulDiv(1e18, 1e18, price);
    }

    function _totalValueInWeth() internal view returns (uint256) {
        if (address(ASSET) == address(WETH)) {
            return WETH.balanceOf(address(this));
        }
        uint256 assetBal = ASSET.balanceOf(address(this));
        uint256 wethBal = WETH.balanceOf(address(this));
        uint256 p = _spotPrice1e18();
        uint256 assetAsWeth = p != 0 ? Math.mulDiv(assetBal, 1e18, p) : 0;
        return wethBal + assetAsWeth;
    }

    function _swap(IERC20 tokenIn, uint256 amount) internal {
        if (amount == 0) return;
        uint256 bal = tokenIn.balanceOf(address(this));
        if (amount > bal) amount = bal;
        if (amount <= LIQUIDITY_DUST) return;
        require(
            address(tokenIn) == poolKey.currency0 || address(tokenIn) == poolKey.currency1,
            "!"
        );
        require(amount <= type(uint128).max, ">");
        _swapExactInputSingleStrictInternal(
            address(ASSET),
            address(tokenIn) == poolKey.currency0,
            uint128(amount)
        );
    }

    function vaultValue() public view override returns (uint256) {
        return _totalValueInWeth();
    }

    function changeAsset(address _newAssetAddr) external override onlyAuthorized {
        if (_newAssetAddr == address(0)) revert ZeroAddress();
        address w = address(WETH);

        // Exit to WETH only: sell current ASSET, DEFENSIVE (WETH deposits still accepted, held idle).
        if (_newAssetAddr == w) {
            address a = assetAddr;
            if (a != address(0) && a != w) {
                (PoolKey memory exitKey, bytes memory exitHookData) = _getV4PoolConfig(a);
                _mirrorWethPoolConfig(exitKey, exitHookData);
            }
            if (address(ASSET) != w) {
                uint256 oldAssetBal = ASSET.balanceOf(address(this));
                if (oldAssetBal > 0) {
                    _swap(ASSET, oldAssetBal);
                }
            }
            ASSET = WETH;
            assetAddr = w;
            _applyMode(Mode.DEFENSIVE);
            emit StrategyEvent(10, 0, 0, 0);
            return;
        }

        (LiquidityLibraryV4.PoolKey memory key, bytes memory hookData) = _poolKeyFromConfig(_newAssetAddr);

        uint256 assetBal = ASSET.balanceOf(address(this));
        if (assetBal > 0 && address(ASSET) != address(WETH)) {
            _swap(ASSET, assetBal);
        }

        ASSET = IERC20(_newAssetAddr);
        assetAddr = _newAssetAddr;
        _applyPoolKey(_newAssetAddr, key, hookData);

        uint256 wethBal = WETH.balanceOf(address(this));
        if (wethBal > 0) {
            _swap(WETH, wethBal);
        }
        emit StrategyEvent(10, 0, 0, 0);
    }

    /// @dev Read seeded `v4PoolConfig` on this contract (no external router).
    function _poolKeyFromConfig(address asset)
        internal
        view
        returns (LiquidityLibraryV4.PoolKey memory key, bytes memory hookData)
    {
        (PoolKey memory v4Key, bytes memory data) = _getV4PoolConfig(asset);
        key = _fromV4PoolKey(v4Key);
        hookData = data;

        address w = address(WETH);
        require(key.currency0 < key.currency1, "PoolKey: c0>=c1");
        require(
            (key.currency0 == asset && key.currency1 == w) || (key.currency1 == asset && key.currency0 == w),
            "PoolKey != ASSET/WETH"
        );
    }

    function _applyPoolKey(address asset, LiquidityLibraryV4.PoolKey memory key, bytes memory hookData) internal {
        _setV4PoolConfig(asset, _toV4PoolKey(key), hookData);
        _validateAndStorePoolKey(asset, key);
    }

    function _toV4PoolKeyMemory(LiquidityLibraryV4.PoolKey calldata key) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(key.currency0),
            currency1: Currency.wrap(key.currency1),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: IHooks(key.hooks)
        });
    }

    function _toV4PoolKey(LiquidityLibraryV4.PoolKey memory key) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(key.currency0),
            currency1: Currency.wrap(key.currency1),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: IHooks(key.hooks)
        });
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

    function _validateAndStorePoolKey(address asset, LiquidityLibraryV4.PoolKey memory key) internal {
        address w = address(WETH);
        require(key.currency0 < key.currency1, "PoolKey: c0>=c1");
        require(
            (key.currency0 == asset && key.currency1 == w) ||
            (key.currency1 == asset && key.currency0 == w),
            "PoolKey != ASSET/WETH"
        );
        poolKey = key;
    }
}
