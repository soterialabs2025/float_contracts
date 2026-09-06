// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {V4Deployments8453} from "../contracts/v4/V4Deployments8453.sol";
import {AutoStrategyBv4} from "../contracts/auto-vault-base-v4/AutoStrategyBv4.sol";
import {LiquidityLibraryV4} from "../contracts/auto-vault-base-v4/libraries/LiquidityLibraryV4.sol";

contract FeeMockToken is ERC20 {
    constructor() ERC20("M", "M") {}
}

/// @dev `_giveAllowances` calls into Permit2 during bootstrap; nothing here needs to model it.
contract MockPermit2 {
    function approve(address, address, uint160, uint48) external {}
}

/// @dev Stands in for the v4 PoolManager. `extsload` ignores the slot key and returns a packed slot0, so
///      `StateLibrary.getSlot0` resolves all four fields without modelling real pool storage.
contract FeeMockPoolManager {
    bytes32 internal _slot0;

    /// @dev Layout per StateLibrary: lpFee | protocolFee | tick | sqrtPriceX96.
    function setSlot0(uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) external {
        _slot0 = bytes32(
            uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160) | (uint256(protocolFee) << 184)
                | (uint256(lpFee) << 208)
        );
    }

    function extsload(bytes32) external view returns (bytes32) {
        return _slot0;
    }
}

/// @dev End-to-end cover for the swap floor the strategy hands the router. The pool takes its fee off the input
///      before the output is measured against that floor, so a floor derived from a raw quote can never be met.
///      These drive `minOutForSwap` through a PoolManager that reports a real fee in slot0.
contract SwapFeeFloorBv4Test is Test {
    address internal constant PM_ADDR = V4Deployments8453.POOL_MANAGER;
    address internal constant PERMIT2_ADDR = V4Deployments8453.PERMIT2;
    address internal constant WETH_ADDR = V4Deployments8453.WETH;

    /// @dev sqrt(1) in Q64.96, so one unit in quotes one unit out before fees.
    uint160 internal constant SQRT_ONE = 79228162514264337593543950336;
    uint256 internal constant ONE = 1e18;
    /// @dev `LPFeeLibrary.DYNAMIC_FEE_FLAG`. Not a rate: the real fee lives in slot0 for such pools.
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    uint24 internal constant FEE_ONE_PCT = 10_000;
    uint24 internal constant FEE_THIRTY_BIP = 3_000;

    FeeMockPoolManager internal pm;
    FeeMockToken internal asset;

    function setUp() public {
        vm.etch(PM_ADDR, type(FeeMockPoolManager).runtimeCode);
        vm.etch(PERMIT2_ADDR, type(MockPermit2).runtimeCode);
        vm.etch(WETH_ADDR, type(FeeMockToken).runtimeCode);
        pm = FeeMockPoolManager(PM_ADDR);

        asset = new FeeMockToken();
        // Keep ASSET above WETH so currency0 is WETH in every case below.
        while (address(asset) < WETH_ADDR) {
            asset = new FeeMockToken();
        }
    }

    /// @dev `bootstrap` is `onlyFactory`, so this contract is the factory.
    function _strategy(uint24 keyFee) internal returns (AutoStrategyBv4 s) {
        s = new AutoStrategyBv4(address(this));
        LiquidityLibraryV4.PoolKey memory key = LiquidityLibraryV4.PoolKey({
            currency0: WETH_ADDR,
            currency1: address(asset),
            fee: keyFee,
            tickSpacing: 60,
            hooks: address(0)
        });
        // Package wiring is irrelevant to pricing; these only have to be distinct and non-zero.
        s.bootstrap(
            address(this),
            address(0xA1),
            address(0xA2),
            address(0xA3),
            address(0xA4),
            address(0xA5),
            address(0xA6),
            address(asset),
            key,
            ""
        );
    }

    /// @dev What the pool actually pays for `ONE` in at parity, after taking `feePips` off the input.
    function _payable(uint24 feePips) internal pure returns (uint256) {
        return (ONE * (1_000_000 - uint256(feePips))) / 1_000_000;
    }

    // --- the regression ---

    /// @dev On a 1% pool the fee alone equals the whole 100 bps default tolerance. Before this fix the floor
    ///      landed exactly on the post-fee output, so any price impact at all made the swap revert.
    function test_FloorSitsBelowPostFeeOutputOnOnePercentPool() public {
        AutoStrategyBv4 s = _strategy(FEE_ONE_PCT);
        pm.setSlot0(SQRT_ONE, 0, 0, FEE_ONE_PCT);

        uint256 floor_ = s.minOutForSwap(WETH_ADDR, ONE);
        assertLt(floor_, _payable(FEE_ONE_PCT), "floor must leave room below the post-fee output");
        assertEq(floor_, 0.9801e18, "quote, less 1% fee, less 1% tolerance");
    }

    function test_FloorSitsBelowPostFeeOutputOnThirtyBipPool() public {
        AutoStrategyBv4 s = _strategy(FEE_THIRTY_BIP);
        pm.setSlot0(SQRT_ONE, 0, 0, FEE_THIRTY_BIP);

        uint256 floor_ = s.minOutForSwap(WETH_ADDR, ONE);
        assertLt(floor_, _payable(FEE_THIRTY_BIP));
        assertEq(floor_, 0.98703e18);
    }

    // --- fee comes from slot0, not the pool key ---

    /// @dev The reason the fee is read from slot0. For a dynamic-fee pool `key.fee` is only the sentinel, which
    ///      as a rate would be 838% and would take the floor to zero, refusing every swap on the pool.
    function test_DynamicFeePoolPricesOffSlot0NotTheKeySentinel() public {
        AutoStrategyBv4 s = _strategy(DYNAMIC_FEE_FLAG);
        pm.setSlot0(SQRT_ONE, 0, 0, FEE_THIRTY_BIP);

        uint256 floor_ = s.minOutForSwap(WETH_ADDR, ONE);
        assertGt(floor_, 0, "sentinel must not brick the pool");
        assertEq(floor_, 0.98703e18, "priced off the live 0.3% fee in slot0");
    }

    /// @dev A hook moving a dynamic pool's fee is picked up on the next quote with no strategy change.
    function test_DynamicFeeChangeIsPickedUpImmediately() public {
        AutoStrategyBv4 s = _strategy(DYNAMIC_FEE_FLAG);

        pm.setSlot0(SQRT_ONE, 0, 0, FEE_THIRTY_BIP);
        uint256 cheap = s.minOutForSwap(WETH_ADDR, ONE);

        pm.setSlot0(SQRT_ONE, 0, 0, FEE_ONE_PCT);
        uint256 dear = s.minOutForSwap(WETH_ADDR, ONE);

        assertGt(cheap, dear, "a higher live fee must lower the floor");
    }

    // --- protocol fee ---

    /// @dev The protocol fee is taken off the input ahead of the LP fee, so both have to be accounted for or the
    ///      floor drifts back above what the pool will pay the moment governance turns it on.
    function test_ProtocolFeeIsDeductedOnTopOfLpFee() public {
        AutoStrategyBv4 s = _strategy(FEE_ONE_PCT);

        pm.setSlot0(SQRT_ONE, 0, 0, FEE_ONE_PCT);
        uint256 withoutProtocol = s.minOutForSwap(WETH_ADDR, ONE);

        // 1000 pips (the 0.1% maximum) in the zeroForOne slot; WETH is currency0 here.
        pm.setSlot0(SQRT_ONE, 0, 1_000, FEE_ONE_PCT);
        uint256 withProtocol = s.minOutForSwap(WETH_ADDR, ONE);

        assertLt(withProtocol, withoutProtocol);
        assertLe(withProtocol, _payable(10_990), "combined fee is 1000 + 10000 - 1000*10000/1e6");
    }

    /// @dev Protocol fees are packed per direction. Charging only the opposite side must not move this quote.
    function test_OppositeDirectionProtocolFeeIsIgnored() public {
        AutoStrategyBv4 s = _strategy(FEE_ONE_PCT);

        pm.setSlot0(SQRT_ONE, 0, 0, FEE_ONE_PCT);
        uint256 clean = s.minOutForSwap(WETH_ADDR, ONE);

        // Upper 12 bits are the oneForZero fee; swapping WETH (currency0) in is zeroForOne.
        pm.setSlot0(SQRT_ONE, 0, uint24(1_000 << 12), FEE_ONE_PCT);
        assertEq(s.minOutForSwap(WETH_ADDR, ONE), clean);

        // Swapping ASSET in is oneForZero, so that side does pay it.
        assertLt(s.minOutForSwap(address(asset), ONE), clean);
    }

    // --- tolerance is separately tunable ---

    function test_WiderSwapToleranceLowersFloorWithoutTouchingMints() public {
        AutoStrategyBv4 s = _strategy(FEE_ONE_PCT);
        pm.setSlot0(SQRT_ONE, 0, 0, FEE_ONE_PCT);

        uint256 tight = s.minOutForSwap(WETH_ADDR, ONE);
        uint16 mintBefore = s.slippageBps();

        s.setSwapSlippageBps(500);
        assertLt(s.minOutForSwap(WETH_ADDR, ONE), tight);
        assertEq(s.slippageBps(), mintBefore, "mint tolerance must be untouched");
    }

    function test_UninitialisedPoolQuotesNothing() public {
        AutoStrategyBv4 s = _strategy(FEE_ONE_PCT);
        pm.setSlot0(0, 0, 0, FEE_ONE_PCT);
        assertEq(s.minOutForSwap(WETH_ADDR, ONE), 0);
    }
}
