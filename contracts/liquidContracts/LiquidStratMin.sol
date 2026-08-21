// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IUniswapV3PoolMinimal.sol";
import "./LiquidSwapRouter.sol";
import "./interfaces/ILiquidStrategy.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title LiquidStratMin
/// @notice Minimal liquid strategy: holds ASSET + idle WETH, swaps via router. Pool is used only for
///         spot price when computing `vaultValue()` (NAV in WETH). No Float mirror, no tick/range state,
///         no price-based mode automation.
/// @dev    Modes (NORMAL / DEFENSIVE / OFFENSIVE) are set manually via `setMode` (owner). Exposes mode

contract LiquidStratMin is ILiquidStrategy,  Ownable, ReentrancyGuard {
    error Unauthorized();
    error ZeroValue();
    error ZeroAddress();

    using SafeERC20 for IERC20;

    IUniswapV3PoolMinimal private pool;
    LiquidSwapRouter private swapRouter;
    address public managerAddress;
    IERC20 private LiquidASSET;
    IERC20 private WETH;
    address private immutable baseWETH = 0x4200000000000000000000000000000000000006;
    address private swapRouterAddr;
    address public assetAddr;
    address private vaultAddr;
    address private assetPoolV3;
    address private demeterAddr;
    address private keeperStratAddr;

    uint256 public defensiveEnteredAt;
    uint256 public consecutiveOffensiveCount;
    uint256 public withdrawalFeeBps = 0;
    uint256 public constant DIVISOR = 10000;

    event StrategyEvent(uint8 indexed eventType, uint256 indexed data1, uint256 data2, uint256 data3);
    event ContractSetUp(address indexed caller);
    event ModeSet(uint8 indexed newMode);

    bool public contractSetUp;

    enum Mode {
        NORMAL,
        DEFENSIVE,
        OFFENSIVE
    }
    Mode private _mode;


    function mode() external view  returns (uint8) {
        return uint8(_mode);
    }

    modifier onlyAuthorized() {
        address s = _msgSender();
        if (s != vaultAddr && s != demeterAddr && s != keeperStratAddr && s != managerAddress && s != owner()) {
            revert Unauthorized();
        }
        _;
    }

    constructor() Ownable(_msgSender()) {
        WETH = IERC20(baseWETH);
        emit StrategyEvent(0, uint256(uint160(_msgSender())), 0, 0);
    }

    function setUpContract(
        address _assetAddr,
        address _assetPoolV3Addr,
        address _managerAddr,
        address _swapRouterAddr,
        address _vaultAddr,
        address _demeterAddr,
        address _keeperStrategyAddr
    ) external onlyOwner {
        managerAddress = _managerAddr;
        assetAddr = _assetAddr;
        swapRouterAddr = _swapRouterAddr;
        assetPoolV3 = _assetPoolV3Addr;
        vaultAddr = _vaultAddr;
        demeterAddr = _demeterAddr;
        keeperStratAddr = _keeperStrategyAddr;
        pool = IUniswapV3PoolMinimal(assetPoolV3);
        swapRouter = LiquidSwapRouter(_swapRouterAddr);
        LiquidASSET = IERC20(assetAddr);
        _giveAllowances();
        contractSetUp = true;
        emit ContractSetUp(_msgSender());
    }

    /// @notice Owner-only mode drive (no on-chain Float / band automation).
    /// @param m 0 = NORMAL, 1 = DEFENSIVE, 2 = OFFENSIVE
    function setMode(uint8 m) external onlyOwner {
        require(m <= uint8(Mode.OFFENSIVE), "mode");
        Mode nm = Mode(m);
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
        emit ModeSet(m);
    }

    function beforeDeposit() external override onlyAuthorized {}

    /// @notice Converts all WETH to ASSET (vault hint `amount` must be > 0).
    function deposit(uint256 amount) external override onlyAuthorized nonReentrant {
        if (amount == 0) revert ZeroValue();
        _convertAllWethToAsset();
        emit StrategyEvent(1, vaultValue(), 0, uint256(uint8(_mode)));
    }

    function withdraw(uint256 userShares, uint256 totalSupply_, address receiver) external override onlyAuthorized nonReentrant {
        if (userShares == 0) revert ZeroValue();
        if (totalSupply_ == 0) revert ZeroValue();
        if (receiver == address(0)) revert ZeroAddress();

        uint256 idleAssetBefore = LiquidASSET.balanceOf(address(this));
        uint256 idleWethBefore = WETH.balanceOf(address(this));

        uint256 userIdleAsset = Math.mulDiv(idleAssetBefore, userShares, totalSupply_);
        uint256 userIdleWeth = Math.mulDiv(idleWethBefore, userShares, totalSupply_);

        uint256 totalUserAsset = userIdleAsset;
        uint256 totalUserWeth = userIdleWeth;

        uint256 assetFee = Math.mulDiv(totalUserAsset, withdrawalFeeBps, DIVISOR);
        uint256 wethFee = Math.mulDiv(totalUserWeth, withdrawalFeeBps, DIVISOR);
        totalUserAsset -= assetFee;
        totalUserWeth -= wethFee;

        uint256 wethBeforeSwap = WETH.balanceOf(address(this));
        _swap(LiquidASSET, WETH, totalUserAsset);
        totalUserWeth += WETH.balanceOf(address(this)) - wethBeforeSwap;

        if (assetFee > 0) {
            LiquidASSET.safeTransfer(owner(), assetFee);
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
            _swap(WETH, LiquidASSET, w);
        }
    }

    /// @dev Pool `slot0` only — used for NAV (`vaultValue`), not for mode or ticks.
    function _spotPrice1e18() internal view returns (uint256) {
        (uint160 sqrtP,,,,,,) = pool.slot0();
        address p0 = pool.token0();
        uint256 price = Math.mulDiv(uint256(sqrtP), uint256(sqrtP), (uint256(1) << 192) / 1e18);
        if (p0 == address(WETH)) {
            return price;
        }
        if (price == 0) return 0;
        return Math.mulDiv(1e18, 1e18, price);
    }

    function _getTokenBalances() internal view returns (uint256 assetBal, uint256 wethBal) {
        assetBal = LiquidASSET.balanceOf(address(this));
        wethBal = WETH.balanceOf(address(this));
    }

    function _totalValueInWeth() internal view returns (uint256) {
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        uint256 p = _spotPrice1e18();
        uint256 assetAsWeth = p != 0 ? Math.mulDiv(assetBal, 1e18, p) : 0;
        return wethBal + assetAsWeth;
    }

    /// @dev Skip dust swaps (strict router / quoter can revert on ~0 output).
    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amount) internal {
        if (amount == 0) return;
        uint256 bal = tokenIn.balanceOf(address(this));
        if (amount > bal) amount = bal;
        if (amount <= 1e12) return;
        swapRouter.swapExactInputFromStrategyStrictQuote(address(tokenIn), address(tokenOut), amount, address(this));
    }

    function vaultValue() public view override returns (uint256) {
        return _totalValueInWeth();
    }

    function readInRange() external view override returns (bool) {
        return _mode == Mode.NORMAL;
    }

    function setGiveAllowances() external onlyAuthorized {
        _giveAllowances();
    }

    function _giveAllowances() internal {
        if (address(LiquidASSET) != address(0)) {
            LiquidASSET.approve(address(swapRouter), type(uint256).max);
        }
        WETH.approve(address(swapRouter), type(uint256).max);
    }

    function changeAsset(address _newAssetAddr, address _newPoolV3Addr) external override onlyAuthorized {
        if (_newAssetAddr == address(0)) revert ZeroAddress();

        uint256 assetBal = LiquidASSET.balanceOf(address(this));
        if (assetBal > 0) {
            _swap(LiquidASSET, WETH, assetBal);
        }
        assetAddr = _newAssetAddr;
        LiquidASSET = IERC20(_newAssetAddr);
        assetPoolV3 = _newPoolV3Addr;
        pool = IUniswapV3PoolMinimal(_newPoolV3Addr);
        _giveAllowances();
        uint256 wethBal = WETH.balanceOf(address(this));
        if (wethBal > 0) {
            _swap(WETH, LiquidASSET, wethBal);
        }
        emit StrategyEvent(10, 0, 0, 0);
    }
}
