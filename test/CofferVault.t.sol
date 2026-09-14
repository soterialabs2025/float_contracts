// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {V3Deployments4663} from "../contracts/coffer/V3Deployments4663.sol";
import {CofferStrategy} from "../contracts/coffer/CofferStrategy.sol";
import {CofferStrategyManager} from "../contracts/coffer/CofferStrategyManager.sol";
import {CofferVault} from "../contracts/coffer/CofferVault.sol";
import {CofferLiquidShares} from "../contracts/coffer/CofferLiquidShares.sol";
import {LiquidityLibraryV2} from "../contracts/coffer/libraries/LiquidityLibraryV2.sol";
import {INonfungiblePositionManager} from "../contracts/coffer/interfaces/INonfungiblePositionManager.sol";
import {TickMath} from "../contracts/coffer/libraries/TickMath.sol";

// ---- mocks ----------------------------------------------------------------------------------------------------------

contract CofferMockToken is ERC20 {
    constructor() ERC20("T", "T") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    /// @dev aeWETH stand-in: the vault wraps ETH by calling `deposit()`.
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract CofferMockToken6 is ERC20 {
    constructor() ERC20("U6", "U6") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @dev Spot and TWAP set independently, both as ticks. 1% fee tier, 200 spacing.
contract CofferMockPool {
    address public token0;
    address public token1;
    uint160 internal sqrtP;
    int24 internal tick;
    int24 internal meanTick;
    uint24 public fee;

    function init(address t0, address t1, uint24 fee_) external {
        token0 = t0;
        token1 = t1;
        fee = fee_;
    }

    function setTick(int24 t) external {
        tick = t;
        sqrtP = TickMath.getSqrtRatioAtTick(t);
    }

    function setMeanTick(int24 t) external {
        meanTick = t;
    }

    function tickSpacing() external pure returns (int24) {
        return 200;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtP, tick, 0, 1, 1, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity)
    {
        tickCumulatives = new int56[](2);
        secondsPerLiquidity = new uint160[](2);
        tickCumulatives[1] = int56(meanTick) * int56(uint56(secondsAgos[0]));
    }
}

/// @dev Pools keyed by sorted pair + fee, like the real factory.
contract CofferMockFactory {
    mapping(bytes32 => address) internal pools;

    function key(address a, address b, uint24 fee) public pure returns (bytes32) {
        (address x, address y) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encode(x, y, fee));
    }

    function setPool(address a, address b, uint24 fee, address p) external {
        pools[key(a, b, fee)] = p;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return pools[key(a, b, fee)];
    }
}

/// @dev Position manager with the pool's arithmetic and the pool's refusal, pool resolved per position.
contract CofferMockNpm {
    struct Pos {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
    }

    CofferMockFactory public factory;
    uint256 public lastId;
    mapping(uint256 => Pos) internal pos;
    uint256 public mints;

    function setFactory(CofferMockFactory f) external {
        factory = f;
    }

    function positions(uint256 id)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        Pos storage p = pos[id];
        return (0, address(0), p.token0, p.token1, p.fee, p.tickLower, p.tickUpper, p.liquidity, 0, 0, p.owed0, p.owed1);
    }

    function _pool(address t0, address t1, uint24 fee) internal view returns (CofferMockPool) {
        return CofferMockPool(factory.getPool(t0, t1, fee));
    }

    function _liqAndAmounts(CofferMockPool pool, int24 lower, int24 upper, uint256 a0, uint256 a1)
        internal
        view
        returns (uint128 liq, uint256 n0, uint256 n1)
    {
        (uint160 sqrtP,,,,,,) = pool.slot0();
        (uint160 sqrtL, uint160 sqrtU) = LiquidityLibraryV2.getSqrtRatios(lower, upper);
        liq = LiquidityLibraryV2.getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, a0, a1);
        require(liq > 0);
        (n0, n1) = LiquidityLibraryV2.getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liq);
        if (n0 < a0) n0 += 1;
        if (n1 < a1) n1 += 1;
    }

    function mint(INonfungiblePositionManager.MintParams calldata p)
        external
        returns (uint256 id, uint128 liq, uint256 n0, uint256 n1)
    {
        mints++;
        (liq, n0, n1) = _liqAndAmounts(_pool(p.token0, p.token1, p.fee), p.tickLower, p.tickUpper, p.amount0Desired, p.amount1Desired);
        require(n0 >= p.amount0Min && n1 >= p.amount1Min, "Price slippage check");
        IERC20(p.token0).transferFrom(msg.sender, address(this), n0);
        IERC20(p.token1).transferFrom(msg.sender, address(this), n1);
        id = ++lastId;
        pos[id] = Pos(p.token0, p.token1, p.fee, p.tickLower, p.tickUpper, liq, 0, 0);
    }

    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata p)
        external
        returns (uint128 liq, uint256 n0, uint256 n1)
    {
        Pos storage s = pos[p.tokenId];
        (liq, n0, n1) = _liqAndAmounts(_pool(s.token0, s.token1, s.fee), s.tickLower, s.tickUpper, p.amount0Desired, p.amount1Desired);
        require(n0 >= p.amount0Min && n1 >= p.amount1Min, "Price slippage check");
        IERC20(s.token0).transferFrom(msg.sender, address(this), n0);
        IERC20(s.token1).transferFrom(msg.sender, address(this), n1);
        s.liquidity += liq;
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata p)
        external
        returns (uint256 n0, uint256 n1)
    {
        Pos storage s = pos[p.tokenId];
        require(p.liquidity > 0 && p.liquidity <= s.liquidity);
        (uint160 sqrtP,,,,,,) = _pool(s.token0, s.token1, s.fee).slot0();
        (uint160 sqrtL, uint160 sqrtU) = LiquidityLibraryV2.getSqrtRatios(s.tickLower, s.tickUpper);
        (n0, n1) = LiquidityLibraryV2.getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, p.liquidity);
        s.liquidity -= p.liquidity;
        s.owed0 += uint128(n0);
        s.owed1 += uint128(n1);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata p) external returns (uint256 n0, uint256 n1) {
        Pos storage s = pos[p.tokenId];
        n0 = s.owed0 < p.amount0Max ? s.owed0 : p.amount0Max;
        n1 = s.owed1 < p.amount1Max ? s.owed1 : p.amount1Max;
        s.owed0 -= uint128(n0);
        s.owed1 -= uint128(n1);
        if (n0 > 0) _pay(s.token0, p.recipient, n0);
        if (n1 > 0) _pay(s.token1, p.recipient, n1);
    }

    function _pay(address token, address to, uint256 amt) internal {
        uint256 have = IERC20(token).balanceOf(address(this));
        if (have < amt) CofferMockToken(token).mint(address(this), amt - have);
        IERC20(token).transfer(to, amt);
    }
}

/// @dev Fills 1:1 from its own inventory (every mock pool sits at tick 0), or rejects everything.
contract CofferMockRouter {
    bool public rejecting;
    uint256 public fills;

    function setRejecting(bool r) external {
        rejecting = r;
    }

    function swapExactInputSingleStrict(address tokenIn, address tokenOut, uint24, uint128 amountIn, uint256, uint256)
        external
        returns (uint256)
    {
        require(!rejecting, "Too little received");
        fills++;
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(msg.sender, amountIn);
        return amountIn;
    }
}

contract CofferMockRegistry {
    mapping(address => bool) public isOperator;

    function set(address a, bool b) external {
        isOperator[a] = b;
    }
}

// ---- the tests ------------------------------------------------------------------------------------------------------

/// @dev The allocator over three single-pair strategies: one volatile/WETH, two stock/USDG. Every mock pool sits at
///      tick 0 so all prices are 1:1 and the arithmetic in these assertions is about routing, fractions and
///      accounting, not about price. Prices are moved deliberately in the tests that are about price.
contract CofferVaultTest is Test {
    address internal constant WETH = V3Deployments4663.WETH;
    address internal constant NPM = V3Deployments4663.NPM;
    address internal constant FACTORY = V3Deployments4663.FACTORY;
    address internal constant KEEPER = address(0x1104);
    address internal constant FEES = address(0x1105);
    address internal constant OPERATOR = address(0x0FE4);
    address internal constant USER = address(0xBEEF);
    uint24 internal constant FEE = 10_000;

    CofferMockToken internal weth;
    CofferMockToken internal usdg;
    CofferMockToken internal alt;
    CofferMockToken internal alt2;
    CofferMockToken internal stockA;
    CofferMockToken internal stockB;
    CofferMockPool internal poolAlt;
    CofferMockPool internal poolAlt2;
    CofferMockPool internal poolA;
    CofferMockPool internal poolB;
    CofferMockPool internal poolQuote;
    CofferMockFactory internal factory;
    CofferMockNpm internal npm;
    CofferMockRouter internal router;
    CofferMockRegistry internal registry;

    CofferVault internal vault;
    CofferLiquidShares internal shares;
    CofferStrategy internal sVol;
    CofferStrategy internal sA;
    CofferStrategy internal sB;

    function _token(uint160 at) internal returns (CofferMockToken t) {
        t = CofferMockToken(address(at));
        vm.etch(address(t), type(CofferMockToken).runtimeCode);
    }

    function _pool(address a, address b) internal returns (CofferMockPool p) {
        p = new CofferMockPool();
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        p.init(t0, t1, FEE);
        p.setTick(0);
        p.setMeanTick(0);
        factory.setPool(a, b, FEE, address(p));
    }

    function setUp() public {
        vm.etch(FACTORY, type(CofferMockFactory).runtimeCode);
        vm.etch(WETH, type(CofferMockToken).runtimeCode);
        vm.etch(NPM, type(CofferMockNpm).runtimeCode);
        factory = CofferMockFactory(FACTORY);
        weth = CofferMockToken(WETH);
        npm = CofferMockNpm(NPM);
        npm.setFactory(factory);

        usdg = _token(uint160(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168));
        alt = _token(uint160(0x00A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1));
        alt2 = _token(uint160(0x00A2A2A2A2A2A2A2A2A2A2A2A2A2A2A2A2A2A2A2A2));
        stockA = _token(uint160(0x00B1B1B1B1B1B1B1B1B1B1B1B1B1B1B1B1B1B1B1B1));
        stockB = _token(uint160(0x00B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2));

        poolAlt = _pool(address(alt), WETH);
        poolAlt2 = _pool(address(alt2), WETH);
        poolA = _pool(address(stockA), address(usdg));
        poolB = _pool(address(stockB), address(usdg));
        poolQuote = _pool(WETH, address(usdg));

        router = new CofferMockRouter();
        CofferMockToken[6] memory all = [weth, usdg, alt, alt2, stockA, stockB];
        for (uint256 i; i < all.length; ++i) {
            all[i].mint(address(router), 1_000_000 ether);
        }
        registry = new CofferMockRegistry();
        registry.set(OPERATOR, true);

        vault = new CofferVault(address(this));
        shares = new CofferLiquidShares(address(this));
        shares.bootstrap(address(vault));
        vault.bootstrap(address(this), address(shares), address(registry), KEEPER);

        sVol = new CofferStrategy(address(this), WETH, address(0));
        sA = new CofferStrategy(address(this), address(usdg), address(poolQuote));
        sB = new CofferStrategy(address(this), address(usdg), address(poolQuote));
        _boot(sVol, address(alt), CofferStrategyManager.ReserveMode.QUOTE_ONLY);
        _boot(sA, address(stockA), CofferStrategyManager.ReserveMode.PAIRED);
        _boot(sB, address(stockB), CofferStrategyManager.ReserveMode.PAIRED);
        vault.addStrategy(address(sVol), 3334);
        vault.addStrategy(address(sA), 3333);
        vault.addStrategy(address(sB), 3333);

        vm.deal(address(this), 1000 ether);
        vm.deal(USER, 1000 ether);
        vm.warp(1_000_000);
    }

    function _boot(CofferStrategy s, address asset, CofferStrategyManager.ReserveMode mode) internal {
        s.bootstrap(address(this), address(vault), address(router), address(registry), KEEPER, FEES, asset, FEE, mode);
    }

    function _nav(CofferStrategy s) internal view returns (uint256) {
        return s.poolValue();
    }

    // ---- allocation --------------------------------------------------------------------------------------------

    function test_FirstDepositSplitsByWeightAndMintsOneToOne() public {
        uint256 got = vault.depositETH{value: 3 ether}();
        // 1:1 on what was credited; the mint rounds a few wei of the deposit away in the pool's favour.
        assertApproxEqAbs(got, 3 ether, 1000, "owner seed mints 1:1");
        assertApproxEqRel(_nav(sVol), 1 ether, 0.02e18, "volatile got a third");
        assertApproxEqRel(_nav(sA), 1 ether, 0.02e18, "stock A got a third");
        assertApproxEqRel(_nav(sB), 1 ether, 0.02e18, "stock B got a third");
        assertApproxEqRel(vault.balance(), 3 ether, 0.02e18, "NAV is the sum");
        assertEq(weth.balanceOf(address(vault)), 0, "the vault keeps nothing");
    }

    function test_DepositSkewsTowardUnderWeightStrategies() public {
        vault.depositETH{value: 3 ether}();
        // Double the volatile weight (6668 against 3333 + 3333). With 3 ETH in, its target is 2 of the 4 ETH the
        // vault is about to hold and the other two are exactly at theirs, so the whole deposit is its.
        vm.prank(OPERATOR);
        vault.setTargetWeight(0, 6668);
        uint256 volBefore = _nav(sVol);
        uint256 aBefore = _nav(sA);
        vm.prank(USER);
        vault.depositETH{value: 1 ether}();
        assertApproxEqRel(_nav(sVol) - volBefore, 1 ether, 0.02e18, "under-weight strategy took the deposit");
        assertApproxEqAbs(_nav(sA), aBefore, 1e12, "the others were left alone");
    }

    function test_DepositWithNothingUnderWeightSplitsByTargets() public {
        vault.depositETH{value: 3 ether}();
        uint256 volBefore = _nav(sVol);
        uint256 aBefore = _nav(sA);
        uint256 bBefore = _nav(sB);
        vm.prank(USER);
        vault.depositETH{value: 3 ether}();
        assertApproxEqRel(_nav(sVol) - volBefore, 1 ether, 0.03e18);
        assertApproxEqRel(_nav(sA) - aBefore, 1 ether, 0.03e18);
        assertApproxEqRel(_nav(sB) - bBefore, 1 ether, 0.03e18);
    }

    function test_RetiredStrategyTakesNoDepositsButStillPays() public {
        vault.depositETH{value: 3 ether}();
        vm.prank(OPERATOR);
        vault.setRetired(1, true);
        uint256 aBefore = _nav(sA);
        vm.prank(USER);
        vault.depositETH{value: 2 ether}();
        assertApproxEqAbs(_nav(sA), aBefore, 1e12, "retired: no new capital");
        assertApproxEqRel(_nav(sVol) + _nav(sB), 4 ether, 0.03e18, "the live two took all of it");

        // It still pays its share on the way out.
        uint256 mine = vault.balanceOf(address(this));
        uint256 before = weth.balanceOf(address(this));
        vault.withdraw(mine);
        assertGt(weth.balanceOf(address(this)) - before, 0);
        assertLt(_nav(sA), aBefore, "retired strategy paid the withdrawer");
    }

    // ---- withdrawals ---------------------------------------------------------------------------------------------

    function test_WithdrawTakesTheSameFractionFromEveryStrategy() public {
        vault.depositETH{value: 3 ether}();
        uint256 v0 = _nav(sVol);
        uint256 a0 = _nav(sA);
        uint256 b0 = _nav(sB);
        uint256 minted = vault.balanceOf(address(this));
        uint256 half = minted / 2;
        uint256 before = weth.balanceOf(address(this));
        uint256 got = vault.withdraw(half);
        assertApproxEqAbs(got, weth.balanceOf(address(this)) - before, 100, "reported payout matches the transfer");
        // 1% withdrawal fee on each strategy's payout; everything else comes back as aeWETH at 1:1.
        assertApproxEqRel(got, 1.5 ether * 99 / 100, 0.02e18, "half the vault, less the fee");
        assertApproxEqRel(_nav(sVol), v0 / 2, 0.02e18, "volatile halved");
        assertApproxEqRel(_nav(sA), a0 / 2, 0.02e18, "stock A halved");
        assertApproxEqRel(_nav(sB), b0 / 2, 0.02e18, "stock B halved");
        assertEq(vault.balanceOf(address(this)), minted - half);
    }

    function test_FullWithdrawEmptiesEveryStrategy() public {
        vault.depositETH{value: 3 ether}();
        vault.withdraw(vault.balanceOf(address(this)));
        assertEq(vault.totalSupply(), 0);
        assertLt(vault.balance(), 1e12, "nothing left but rounding");
    }

    // ---- gates and pricing ---------------------------------------------------------------------------------------

    function test_ClosedTwapGateOnOneActiveStrategyBlocksMinting() public {
        vault.depositETH{value: 3 ether}();
        // Spot 10% off TWAP on stock A's pool: its gate closes.
        poolA.setTick(1000);
        vm.prank(USER);
        vm.expectRevert(CofferVault.TwapUnavailable.selector);
        vault.depositETH{value: 1 ether}();
        // Retire it and the vault mints again, pricing the retired leg at the smaller of spot and TWAP.
        vm.prank(OPERATOR);
        vault.setRetired(1, true);
        vm.prank(USER);
        uint256 got = vault.depositETH{value: 1 ether}();
        assertGt(got, 0);
    }

    function test_StockLegIsValuedThroughTheQuotePool() public {
        vault.depositETH{value: 3 ether}();
        uint256 volBefore = _nav(sVol);
        uint256 aBefore = _nav(sA);
        // USDG doubles against WETH: tick 6931 is price 2.0. Whether the stock leg's WETH value halves or doubles
        // depends on which side USDG sits in the mock pool; either way it moves and the volatile leg does not.
        poolQuote.setTick(6931);
        poolQuote.setMeanTick(6931);
        assertEq(_nav(sVol), volBefore, "volatile leg does not price through the quote pool");
        uint256 aAfter = _nav(sA);
        assertTrue(aAfter > aBefore * 19 / 10 || aAfter < aBefore * 6 / 10, "stock leg repriced by ~2x");
        assertGt(sA.poolValueTwap(), 0, "TWAP moved with spot, gate still open");
    }

    function test_UnpriceableQuoteReferenceReadsZeroNotRevert() public {
        vault.depositETH{value: 3 ether}();
        // Spot far from TWAP on the quote pool closes the stock legs' conversion gate.
        poolQuote.setTick(1000);
        assertEq(sA.poolValueTwap(), 0, "gated NAV is zero, not a revert");
        assertGt(sA.poolValue(), 0, "spot NAV still reads");
        vm.prank(USER);
        vm.expectRevert(CofferVault.TwapUnavailable.selector);
        vault.depositETH{value: 1 ether}();
    }

    // ---- reserve modes --------------------------------------------------------------------------------------------

    function test_QuoteOnlyReserveNeverHoldsTheAsset() public {
        vault.depositETH{value: 3 ether}();
        assertEq(sVol.reservedAsset(), 0, "volatile reserve holds no asset");
        assertApproxEqRel(sVol.reservedQuote(), 0.3 ether, 0.02e18, "30% of its capital as WETH");
        assertEq(alt.balanceOf(address(sVol)) - sVol.reservedAsset(), alt.balanceOf(address(sVol)));
    }

    function test_PairedReserveHoldsBothLegs() public {
        vault.depositETH{value: 3 ether}();
        assertGt(sA.reservedAsset(), 0, "stock reserve holds stock");
        assertGt(sA.reservedQuote(), 0, "and USDG");
        // 30% of 1 ETH-worth, split across both legs at 1:1.
        assertApproxEqRel(sA.reservedAsset() + sA.reservedQuote(), 0.3 ether, 0.05e18);
    }

    // ---- rotation ------------------------------------------------------------------------------------------------

    function test_ChangeAssetRotatesTheVolatileLeg() public {
        vault.depositETH{value: 3 ether}();
        uint256 navBefore = _nav(sVol);
        uint256 mintsBefore = npm.mints();
        sVol.setAllowedToken(address(alt2), true);
        vm.prank(OPERATOR);
        sVol.changeAsset(address(alt2), FEE);
        assertEq(sVol.ASSET(), address(alt2));
        assertEq(sVol.pool(), address(poolAlt2));
        assertEq(alt.balanceOf(address(sVol)), 0, "old asset fully sold");
        assertEq(npm.mints(), mintsBefore + 1, "new position minted");
        assertApproxEqRel(_nav(sVol), navBefore, 0.02e18, "value carried across at 1:1 fills");
        assertEq(sVol.reservedAsset(), 0, "quote-only reserve rebuilt as WETH");
        assertGt(sVol.reservedQuote(), 0);
    }

    function test_ChangeAssetRefusesTokensOffTheAllowlist() public {
        vault.depositETH{value: 3 ether}();
        vm.prank(OPERATOR);
        vm.expectRevert(CofferStrategy.E.selector);
        sVol.changeAsset(address(alt2), FEE);
    }

    function test_ChangeAssetIsOperatorOrOwnerOnly() public {
        vault.depositETH{value: 3 ether}();
        sVol.setAllowedToken(address(alt2), true);
        vm.prank(USER);
        vm.expectRevert(CofferStrategy.E.selector);
        sVol.changeAsset(address(alt2), FEE);
    }

    function test_ExitToQuoteIdlesTheKeeperAndKeepsValue() public {
        vault.depositETH{value: 3 ether}();
        uint256 navBefore = _nav(sVol);
        vm.prank(OPERATOR);
        sVol.exitToQuote();
        assertEq(uint256(sVol.mode()), uint256(CofferStrategy.Mode.IDLE));
        assertApproxEqRel(_nav(sVol), navBefore, 0.02e18, "value held as WETH");
        vm.prank(KEEPER);
        assertFalse(sVol.keeperCheck(), "keeper stands down in IDLE");
        // Deposits still route here and wait as quote.
        vm.prank(USER);
        vault.depositETH{value: 3 ether}();
        assertGt(_nav(sVol), navBefore, "new capital counted while idle");
        assertEq(npm.mints(), 3, "but nothing was minted");
        // Re-enter with the same asset.
        vm.prank(OPERATOR);
        sVol.changeAsset(address(alt), FEE);
        assertEq(uint256(sVol.mode()), uint256(CofferStrategy.Mode.ACTIVE));
        assertEq(npm.mints(), 4, "re-entered the band");
    }

    function test_ChangeAssetRevertsIfTheOldAssetCannotBeSold() public {
        vault.depositETH{value: 3 ether}();
        sVol.setAllowedToken(address(alt2), true);
        router.setRejecting(true);
        vm.prank(OPERATOR);
        vm.expectRevert(CofferStrategy.E.selector);
        sVol.changeAsset(address(alt2), FEE);
        assertEq(sVol.ASSET(), address(alt), "nothing changed");
    }

    function test_ExitToQuoteHoldsUnsoldAssetAndSellsInTranches() public {
        vault.depositETH{value: 3 ether}();
        uint256 navBefore = _nav(sVol);
        router.setRejecting(true);
        vm.prank(OPERATOR);
        sVol.exitToQuote();
        assertGt(alt.balanceOf(address(sVol)), 0, "asset stayed when the floor refused");
        assertApproxEqRel(_nav(sVol), navBefore, 0.02e18, "and stayed counted");
        router.setRejecting(false);
        uint256 half = alt.balanceOf(address(sVol)) / 2;
        vm.prank(OPERATOR);
        sVol.sellAsset(half);
        assertApproxEqAbs(alt.balanceOf(address(sVol)), half, 1, "one tranche sold");
    }

    // ---- keeper behaviour across the set --------------------------------------------------------------------------

    function test_KeeperHasNothingToDoAfterACleanDeposit() public {
        vault.depositETH{value: 3 ether}();
        vm.startPrank(KEEPER);
        assertFalse(sVol.keeperCheck());
        assertFalse(sA.keeperCheck());
        assertFalse(sB.keeperCheck());
        vm.stopPrank();
    }

    function test_DustOfScalesSixDecimalTokens() public {
        assertEq(LiquidityLibraryV2.dustOf(WETH, 1e12), 1e12, "18-dec unchanged");
        CofferMockToken6 d6 = new CofferMockToken6();
        assertEq(LiquidityLibraryV2.dustOf(address(d6), 1e12), 1, "6-dec USDG-class is 1 raw unit");
    }
}
