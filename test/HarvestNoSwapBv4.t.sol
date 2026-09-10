// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {V4Deployments8453} from "../contracts/v4/V4Deployments8453.sol";
import {TickMath} from "../contracts/v4/libraries/TickMath.sol";
import {AutoStrategyBv4} from "../contracts/auto-vault-base-v4/AutoStrategyBv4.sol";
import {AutoStrategyManagerBv4} from "../contracts/auto-vault-base-v4/AutoStrategyManagerBv4.sol";
import {LiquidityLibraryV4} from "../contracts/auto-vault-base-v4/libraries/LiquidityLibraryV4.sol";
import {IAutoSwapRouterBv4} from "../contracts/auto-vault-base-v4/interfaces/IAutoSwapRouterBv4.sol";

contract HarvestToken is ERC20 {
    constructor() ERC20("M", "M") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract HarvestPermit2 {
    function approve(address, address, uint160, uint48) external {}
}

contract HarvestRegistry {
    mapping(address => bool) public operators;

    function setOperator(address account, bool allowed) external {
        operators[account] = allowed;
    }

    function isOperator(address account) external view returns (bool) {
        return operators[account];
    }
}

contract HarvestStaking {
    function notifyReward(address, uint256) external {}
}

contract HarvestPoolManager {
    bytes32 internal _slot0;

    /// @dev Layout per StateLibrary: lpFee | protocolFee | tick | sqrtPriceX96.
    function setSlot0(uint160 sqrtPriceX96, int24 tick) external {
        _slot0 = bytes32(uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160) | (uint256(uint24(3_000)) << 208));
    }

    function extsload(bytes32) external view returns (bytes32) {
        return _slot0;
    }
}

/// @notice Minimal stand-in for the v4 PositionManager.
/// @dev Deliberately not a pool model. It tracks position liquidity and pays programmed fees on collect, and it
///      moves no tokens of its own: how much a real pool would consume for a given mint is exactly the arithmetic
///      this file must not invent, or the assertions below would be about the mock. Nothing asserted here depends
///      on amounts consumed — only on whether the strategy routed a swap and whether it reached the increase.
contract MockPosm {
    uint8 internal constant INCREASE = 0x00;
    uint8 internal constant DECREASE = 0x01;
    uint8 internal constant MINT = 0x02;

    uint256 internal _next;
    mapping(uint256 => uint128) internal _liq;

    uint256 public fee0;
    uint256 public fee1;

    /// @notice Fees the next collect will pay out, in currency0 and currency1 terms.
    function setPendingFees(uint256 a0, uint256 a1) external {
        fee0 = a0;
        fee1 = a1;
    }

    /// @dev Counts from 1, derived rather than set in a constructor: this contract is installed with `vm.etch`,
    ///      which copies runtime code only, so any constructor-initialised storage would still read zero. Id 0
    ///      means "no position" to the strategy, so a counter starting there mints nothing.
    function nextTokenId() public view returns (uint256) {
        return _next == 0 ? 1 : _next;
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128) {
        return _liq[tokenId];
    }

    function modifyLiquidities(bytes calldata unlockData, uint256) external payable {
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        uint8 action = uint8(actions[0]);

        if (action == MINT) {
            (,,, uint128 liq,,,,) = abi.decode(
                params[0],
                (LiquidityLibraryV4.PoolKey, int24, int24, uint128, uint128, uint128, address, bytes)
            );
            uint256 id = nextTokenId();
            _liq[id] = liq;
            _next = id + 1;
        } else if (action == INCREASE) {
            (uint256 id, uint128 liq,,,) = abi.decode(params[0], (uint256, uint128, uint128, uint128, bytes));
            _liq[id] += liq;
        } else if (action == DECREASE) {
            (uint256 id, uint256 liq,,,) = abi.decode(params[0], (uint256, uint256, uint128, uint128, bytes));
            if (liq == 0) {
                // A zero-liquidity decrease is the fee collect. `collectAllFees` reads the recipient's balance
                // delta, so paying out here is what makes a harvest see any fees at all.
                (address c0, address c1, address to) = abi.decode(params[1], (address, address, address));
                if (fee0 > 0) HarvestToken(c0).mint(to, fee0);
                if (fee1 > 0) HarvestToken(c1).mint(to, fee1);
                fee0 = 0;
                fee1 = 0;
            } else {
                _liq[id] = liq >= _liq[id] ? 0 : _liq[id] - uint128(liq);
            }
        }
    }
}

/// @dev Counts swaps and settles them at the caller's own floor. The count is the assertion; the settlement only
///      has to be plausible enough that the strategy can continue.
contract CountingSwapRouter {
    uint256 public swapCount;

    function swapExactInputSingleStrict(
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        uint256,
        IAutoSwapRouterBv4.AutoPoolKey calldata key,
        bytes calldata
    ) external returns (uint256) {
        swapCount++;
        address tokenIn = zeroForOne ? key.currency0 : key.currency1;
        address tokenOut = zeroForOne ? key.currency1 : key.currency0;
        HarvestToken(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        HarvestToken(tokenOut).mint(msg.sender, minAmountOut);
        return minAmountOut;
    }
}

/// @notice Cover for dropping `_balanceTokens` from `harvestBoolean`.
/// @dev The removed call swapped the whole idle pool to `targetAssetBps` on every harvest without consulting the
///      reserve. On the live Cash Cat vault that accounted for roughly 40% of swap volume and the large majority
///      of the swap-related loss: harvest bought the asset back at whatever the price had climbed to, right after
///      the position had sold it lower. Harvest must now deploy at the band's own ratio and leave any imbalance
///      for `_remintAtTarget`, which can close it from reserve instead of paying the pool.
contract HarvestNoSwapBv4Test is Test {
    address internal constant PM_ADDR = V4Deployments8453.POOL_MANAGER;
    address internal constant POSM_ADDR = V4Deployments8453.POSITION_MANAGER;
    address internal constant PERMIT2_ADDR = V4Deployments8453.PERMIT2;
    address internal constant WETH_ADDR = V4Deployments8453.WETH;

    address internal constant KEEPER = address(0xC0FFEE);
    address internal constant OPERATOR = address(0x0B07);
    address internal constant STRANGER = address(0xBADD);
    address internal constant REGISTRY = address(0xDECAF);
    address internal constant STAKING = address(0xA6);
    address internal constant FEE_MANAGER = address(0xA5);

    uint256 internal constant ONE = 1e18;
    /// @dev `liqPos` is private and the interface exposes no position getter, so liquidity is observed through
    ///      the mock. Ids come off `nextTokenId` in order, making the first mint 1 and the first re-mint 2.
    uint256 internal constant FIRST_POSITION = 1;
    uint256 internal constant SECOND_POSITION = 2;

    HarvestPoolManager internal pm;
    MockPosm internal posm;
    CountingSwapRouter internal router;
    HarvestToken internal asset;
    AutoStrategyBv4 internal s;

    uint256 internal clock;
    uint256 internal blockNo;

    function setUp() public {
        vm.etch(PM_ADDR, type(HarvestPoolManager).runtimeCode);
        vm.etch(POSM_ADDR, type(MockPosm).runtimeCode);
        vm.etch(PERMIT2_ADDR, type(HarvestPermit2).runtimeCode);
        vm.etch(WETH_ADDR, type(HarvestToken).runtimeCode);
        vm.etch(REGISTRY, type(HarvestRegistry).runtimeCode);
        vm.etch(STAKING, type(HarvestStaking).runtimeCode);
        pm = HarvestPoolManager(PM_ADDR);
        posm = MockPosm(POSM_ADDR);
        router = new CountingSwapRouter();

        asset = new HarvestToken();
        // Keep ASSET above WETH so currency0 is WETH.
        while (address(asset) < WETH_ADDR) {
            asset = new HarvestToken();
        }

        clock = 100_000_000;
        blockNo = 100;
        vm.warp(clock);
        vm.roll(blockNo);

        _setTick(0);
        s = _strategy();
    }

    function _strategy() internal returns (AutoStrategyBv4 st) {
        st = new AutoStrategyBv4(address(this));
        LiquidityLibraryV4.PoolKey memory key = LiquidityLibraryV4.PoolKey({
            currency0: WETH_ADDR,
            currency1: address(asset),
            fee: 3_000,
            // The default 800/600 tick bands have to divide by the key's spacing, and bootstrap adopts it.
            tickSpacing: 200,
            hooks: address(0)
        });
        st.bootstrap(
            address(this), address(0xA1), address(router), REGISTRY, KEEPER, FEE_MANAGER, STAKING,
            address(asset), key, ""
        );
    }

    function _setTick(int24 tick) internal {
        pm.setSlot0(TickMath.getSqrtRatioAtTick(tick), tick);
    }

    /// @dev Moves time and blocks together. Both are tracked here rather than read back from `block.timestamp`
    ///      or `block.number`: under `via_ir` the optimizer treats those opcodes as constant within a call frame
    ///      and reuses a stale read, so a second relative warp in one test lands on the same instant as the first.
    function _advance(uint256 secs) internal {
        clock += secs;
        blockNo += secs / 2; // Base blocks are ~2s.
        vm.warp(clock);
        vm.roll(blockNo);
    }

    function _fund(uint256 weth, uint256 assetAmt) internal {
        if (weth > 0) HarvestToken(WETH_ADDR).mint(address(s), weth);
        if (assetAmt > 0) asset.mint(address(s), assetAmt);
    }

    /// @dev At tick 0 the two legs price 1:1, so equal amounts already sit at the 5,000 bps target and the mint
    ///      itself has nothing to swap. That keeps the swap count attributable to the call under test.
    function _mintBalancedPosition() internal {
        _fund(ONE, ONE);
        vm.prank(KEEPER);
        s.keeperCheck();
        assertGt(posm.getPositionLiquidity(FIRST_POSITION), 0, "position expected");

        // Leave the block the mint seeded the price reference in. The swap gate returns a zero floor while
        // `refBlock == block.number`, and `_swap` treats a zero floor as "skip", so a harvest measured inside
        // this block would report no swap no matter what the code under test did.
        _advance(1 hours);
    }

    function _harvest() internal returns (uint256) {
        vm.prank(KEEPER);
        return s.harvestBoolean(false);
    }

    // --- the control: the harness can see a swap, and re-centring still makes one ---

    /// @dev Without this the zero-swap assertions below would pass on a strategy that never reaches the router at
    ///      all. Funding lopsided makes `_remintAtTarget` close the gap the only way it can before a mint.
    function test_RecentringStillSwapsToCloseAnImbalance() public {
        _fund(2 * ONE, 0);
        vm.prank(KEEPER);
        s.keeperCheck();

        assertGt(router.swapCount(), 0, "re-centring is the path that pays the pool");
    }

    function test_BalancedMintNeedsNoSwap() public {
        _mintBalancedPosition();
        assertEq(router.swapCount(), 0, "baseline for the harvest assertions");
    }

    // --- the change ---

    /// @dev The regression proper. Fees arrive entirely in one leg, which is the case the removed `_balanceTokens`
    ///      would have "corrected" by selling into the pool at whatever the price had just become.
    function test_HarvestRoutesNoSwapOnLopsidedFees() public {
        _mintBalancedPosition();
        posm.setPendingFees(0, ONE / 2);

        _harvest();

        assertEq(router.swapCount(), 0, "harvest must never take from the pool");
    }

    /// @dev And it holds when the price has run since the mint, which is when the old behaviour was most costly:
    ///      harvest bought the asset back higher immediately after the band had sold it lower.
    function test_HarvestRoutesNoSwapAfterThePriceMoves() public {
        _mintBalancedPosition();
        posm.setPendingFees(0, ONE / 2);
        _setTick(600);

        _harvest();

        assertEq(router.swapCount(), 0);
    }

    /// @dev Anti-vacuity for the two above: harvest has to actually reach `_increaseLiquidityInternal`, not bail
    ///      out early and score zero swaps for the wrong reason.
    function test_HarvestReachesTheIncreaseAndAddsLiquidity() public {
        _mintBalancedPosition();
        uint128 before = posm.getPositionLiquidity(FIRST_POSITION);
        posm.setPendingFees(0, ONE / 2);

        _harvest();

        assertGt(posm.getPositionLiquidity(FIRST_POSITION), before, "fees were deployed, not just collected");
        assertEq(router.swapCount(), 0);
    }

    /// @dev Harvest leaves the imbalance in place rather than trading it away. The reserve is credited from the
    ///      collected fees, which is where `_remintAtTarget` later draws from instead of paying the pool.
    function test_HarvestCreditsReserveAndLeavesTheImbalance() public {
        _mintBalancedPosition();
        posm.setPendingFees(0, ONE / 2);

        _harvest();

        assertGt(s.reservedAsset(), 0, "reserveBps of the asset leg is held back");
        assertEq(s.reservedWeth(), 0, "no WETH fees arrived, so nothing to reserve on that side");
        assertEq(router.swapCount(), 0);
    }

    /// @dev A harvest with nothing to collect is a no-op on both counts.
    function test_HarvestWithoutFeesDoesNothing() public {
        _mintBalancedPosition();
        uint128 before = posm.getPositionLiquidity(FIRST_POSITION);

        _harvest();

        assertEq(posm.getPositionLiquidity(FIRST_POSITION), before);
        assertEq(router.swapCount(), 0);
    }

    /// @dev The imbalance harvest leaves behind is closed at the next re-centre, which is the design the reserve
    ///      exists for. This is the second half of the change: not "never rebalance", but "rebalance there".
    function test_ImbalanceIsCarriedToTheNextRecentre() public {
        _mintBalancedPosition();
        posm.setPendingFees(0, ONE / 2);
        _harvest();
        assertEq(router.swapCount(), 0, "not at harvest");

        // Push the tick outside the inner comfort band so the next keeper pass re-mints.
        _setTick(2_000);
        _advance(1 hours);
        vm.prank(KEEPER);
        s.keeperCheck();

        assertGt(posm.getPositionLiquidity(SECOND_POSITION), 0, "re-minted");
    }

    /// @dev Mock mint does not consume tokens, so deployable idle stays the whole book. That is material, but
    ///      the idle remint path still respects `minHarvestDelay` so a just-minted in-range position is not
    ///      burned on the next keeper tick.
    function test_KeeperDoesNotRemintInRangeDuringCooldown() public {
        _mintBalancedPosition();

        vm.prank(KEEPER);
        bool acted = s.keeperCheck();

        assertTrue(acted, "increase still runs");
        assertGt(posm.getPositionLiquidity(FIRST_POSITION), 0, "kept the live NFT");
        assertEq(posm.getPositionLiquidity(SECOND_POSITION), 0, "no remint");
    }

    /// @dev Once the cooldown has elapsed, in-range leftover that the current band cannot absorb remints.
    function test_KeeperRemintsInRangeWhenIdleIsMaterial() public {
        _mintBalancedPosition();
        _advance(2 hours);

        vm.prank(KEEPER);
        bool acted = s.keeperCheck();

        assertTrue(acted);
        assertGt(posm.getPositionLiquidity(SECOND_POSITION), 0, "reminted leftover idle");
    }

    function test_OperatorCanSetBandParams() public {
        HarvestRegistry(REGISTRY).setOperator(OPERATOR, true);
        vm.prank(OPERATOR);
        s.setBandParams(1_200, 1_200, 800, 800);
        assertEq(s.rangeBelowTicks(), 1_200);
        assertEq(s.rangeAboveTicks(), 1_200);
        assertEq(s.innerBelowTicks(), 800);
        assertEq(s.innerAboveTicks(), 800);
    }

    function test_OwnerCannotSetBandParamsUnlessOperator() public {
        vm.expectRevert(AutoStrategyManagerBv4.NotOperator.selector);
        s.setBandParams(1_200, 1_200, 800, 800);
        assertEq(s.rangeBelowTicks(), 1_000);
    }

    function test_StrangerCannotSetBandParams() public {
        vm.prank(STRANGER);
        vm.expectRevert(AutoStrategyManagerBv4.NotOperator.selector);
        s.setBandParams(1_200, 1_200, 800, 800);
        assertEq(s.rangeBelowTicks(), 1_000);
    }
}
