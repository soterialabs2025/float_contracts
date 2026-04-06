// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IUniswapV3PoolMinimal.sol";
import "./interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./libraries/LiquidityLibrary.sol";
import "./libraries/TickMath.sol";
import "./interfaces/ILiquidStrategy.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
/// @notice Holds LiquidASSET only (no Uniswap V3 liquidity). Incoming WETH is swapped to LiquidASSET.
///         `vaultValue()` is total NAV in WETH (LiquidASSET at spot + idle WETH).
contract LiquidStrategy is ILiquidStrategy, Ownable, Pausable, ReentrancyGuard {    
    error Unauthorized();
    error ZeroValue();
    error ZeroAddress();

    using SafeERC20 for IERC20;

    IUniswapV3PoolMinimal private pool;
    ISwapRouter private swapRouter;
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
    uint24 public v3Fee = 10000;
    int24 public tickSpacing = 200;
    int8 public startM = 4;
    /// @dev Simulated range lower/upper (same geometry as `LiquidityLibrary.mintNewPosition` for `startM` × spacing).
    int24 public lowerTick;
    int24 public upperTick;
    /// @dev Last pool tick and spot snapshot on `deposit` (after WETH→ASSET).
    int24 public baselineTick;
    int24 public floorTick;
    uint16 public minFloorDeviationBps = 300;
    uint32 public floorSlopeNumerator = 1;
    uint32 public floorSlopeDenominator = 3;
    uint256 public defensiveEnteredAt;
    uint256 public consecutiveOffensiveCount;
    uint256 public lastSpotPrice1e18;
    uint256 public withdrawalFeeBps = 0;
    uint256 public constant DIVISOR = 10000;
    event StrategyEvent(uint8 indexed eventType, uint256 indexed data1, uint256 data2, uint256 data3);
    event ContractSetUp(address indexed caller);
    bool public contractSetUp;
    enum Mode { NORMAL, DEFENSIVE, OFFENSIVE }
    Mode public mode;

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
        swapRouter = ISwapRouter(swapRouterAddr);
        LiquidASSET = IERC20(assetAddr);
        _giveAllowances();
        contractSetUp = true;
        emit ContractSetUp(_msgSender());
    }

    function beforeDeposit() external override onlyAuthorized {
        // Optional: add harvest-on-deposit here; vault uses `vaultValue()` after this for share math.
    }

    /// @notice Converts all WETH on this contract to LiquidASSET. `amount` must be > 0 (vault hint); uses full WETH balance.
    ///         Then snapshots `_spotPrice1e18`, current tick as `baselineTick`, clears `floorTick`, and sets `lowerTick`/`upperTick` from `startM` and `tickSpacing`.
    function deposit(uint256 amount) external override onlyAuthorized nonReentrant {
        if (amount == 0) revert ZeroValue();
        _convertAllWethToAsset();
        _snapshotPriceAndTicks();
        emit StrategyEvent(1, vaultValue(), uint256(int256(lowerTick)), uint256(int256(upperTick)));
    }

    function _snapshotPriceAndTicks() internal {
        lastSpotPrice1e18 = _spotPrice1e18();
        (, int24 currentTick,,,,,) = pool.slot0();
        baselineTick = currentTick;
        floorTick = 0;
        (lowerTick, upperTick) = _computeMintTicks(int24(int256(startM)));
    }

    /// @notice Tick band matching `LiquidityLibrary.mintNewPosition` (without NPM mint).
    function _computeMintTicks(int24 mValue) internal view returns (int24 lower, int24 upper) {
        (, int24 currentTick,,,,,) = pool.slot0();
        int24 base = LiquidityLibrary.alignDown(currentTick, tickSpacing);
        int24 total = int24(int256(mValue) * int256(tickSpacing));
        require(total > 0, "width=0");
        if (mValue % 2 == 0) {
            lower = base - (mValue / 2) * tickSpacing;
            upper = base + (mValue / 2) * tickSpacing;
        } else {
            lower = base - ((mValue - 1) / 2) * tickSpacing;
            upper = lower + total;
        }
        int24 minTick = LiquidityLibrary.alignUp(TickMath.MIN_TICK, tickSpacing);
        int24 maxTick = LiquidityLibrary.alignDown(TickMath.MAX_TICK, tickSpacing);
        if (lower < minTick) lower = minTick;
        if (upper > maxTick) upper = maxTick;
        if (lower >= upper) {
            lower -= tickSpacing;
            upper += tickSpacing;
        }
        require(lower < upper, "bad ticks");
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
        uint256 wethFromAsset = WETH.balanceOf(address(this)) - wethBeforeSwap;
        totalUserWeth += wethFromAsset;

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

    /// @dev WETH-denominated holdings: idle WETH plus LiquidASSET valued via reference pool spot.
    function _totalValueInWeth() internal view returns (uint256) {
        (uint256 assetBal, uint256 wethBal) = _getTokenBalances();
        uint256 p = _spotPrice1e18();
        uint256 assetAsWeth = p != 0 ? Math.mulDiv(assetBal, 1e18, p) : 0;
        return wethBal + assetAsWeth;
    }

    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amount) internal {
        if (amount == 0) return;
        uint256 bal = tokenIn.balanceOf(address(this));
        if (amount > bal) amount = bal;
        if (amount == 0) return;
        swapRouter.swapExactInputFromStrategyStrictQuote(address(tokenIn), address(tokenOut), amount, address(this));
    }

    function vaultValue() public view override returns (uint256) {
        return _totalValueInWeth();
    }
    /// @notice Syncs `mode` to the deposit snapshot band: `poolTick >= upperTick` → OFFENSIVE, `poolTick < lowerTick` → DEFENSIVE,
    ///         else NORMAL. Trailing floor updates run only while OFFENSIVE (`_checkTrailingPriceFloor`).
    function keeperCheck() external nonReentrant returns (bool) {
        bool acted = _syncModeFromRange();
        if (mode == Mode.DEFENSIVE) return true;
        if (mode == Mode.OFFENSIVE) {
            acted = _checkTrailingPriceFloor() || acted;
        }
        return acted;
    }

    function _inRange() internal view returns (bool) {
        (, int24 poolTick,,,,,) = pool.slot0();
        return poolTick >= lowerTick && poolTick < upperTick;
    }

    function readInRange() external view override returns (bool) {
        return _inRange();
    }

    /// @dev Uses the same half-open band as `_inRange`: in-range is [lowerTick, upperTick).
    function _syncModeFromRange() internal returns (bool) {
        (, int24 poolTick,,,,,) = pool.slot0();
        if (lowerTick >= upperTick) return false;

        if (poolTick >= upperTick) {
            if (mode != Mode.OFFENSIVE) {
                _enterOffensive();
                return true;
            }
            return false;
        }
        if (poolTick < lowerTick) {
            if (mode != Mode.DEFENSIVE) {
                _enterDefensive();
                return true;
            }
            return false;
        }
        if (mode != Mode.NORMAL) {
            mode = Mode.NORMAL;
            floorTick = 0;
            baselineTick = poolTick;
            return true;
        }
        return false;
    }

    function _checkTrailingPriceFloor() internal returns (bool) {
        if (mode != Mode.OFFENSIVE) {
            return false;
        }
        if (minFloorDeviationBps == 0) {
            floorTick = 0;
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
        floorTick = 0;
        consecutiveOffensiveCount = 0;
        baselineTick = 0;
        defensiveEnteredAt = block.timestamp;
        mode = Mode.DEFENSIVE;
    }
    function _enterOffensive() internal {
        consecutiveOffensiveCount++;
        (, int24 t,,,,,) = pool.slot0();
        baselineTick = t;
        floorTick = 0;
        defensiveEnteredAt = 0;
        mode = Mode.OFFENSIVE;
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
