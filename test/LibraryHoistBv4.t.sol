// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LiquidityLibraryV4} from "../contracts/auto-vault-base-v4/libraries/LiquidityLibraryV4.sol";

/// @dev `rebalanceLegs` and `reservePeel` replaced arithmetic that used to live inline in `AutoStrategyBv4`, moved
///      out only because the strategy ran out of runtime bytes. These pin the library to the formulas it replaced,
///      written out here exactly as the strategy had them, so the move is a move and not a change.
contract LibraryHoistBv4Test is Test {
    uint256 internal constant DIVISOR = 10_000;

    // ---- the old inline bodies, verbatim in shape ------------------------------------------------------------

    function _oldBalance(uint256 assetBal, uint256 wethBal, uint256 p, uint256 share)
        internal pure returns (uint256 sellAsset, uint256 sellWeth)
    {
        if (assetBal == 0 && wethBal == 0) return (0, 0);
        if (p == 0) return (0, 0);
        uint256 totalValue = assetBal + Math.mulDiv(wethBal, p, 1e18);
        if (totalValue == 0) return (0, 0);
        uint256 target = Math.mulDiv(totalValue, share, 1e18);
        if (assetBal > target) {
            sellAsset = assetBal - target;
        } else if (assetBal < target) {
            sellWeth = Math.mulDiv(target - assetBal, 1e18, p);
            if (sellWeth > wethBal) sellWeth = wethBal;
        }
    }

    function _oldDeficit(uint256 assetBal, uint256 wethBal, uint256 p, uint256 share)
        internal pure returns (uint256 pullAsset, uint256 pullWeth)
    {
        if (p == 0) return (0, 0);
        uint256 totalValue = assetBal + Math.mulDiv(wethBal, p, 1e18);
        if (totalValue == 0) return (0, 0);
        uint256 targetAsset = Math.mulDiv(totalValue, share, 1e18);
        if (assetBal > targetAsset) {
            pullWeth = Math.mulDiv(assetBal - targetAsset, 1e18, p);
        } else if (assetBal < targetAsset) {
            pullAsset = targetAsset - assetBal;
        }
    }

    function _oldPeel(uint256 assetBal, uint256 wethBal, uint256 p, uint256 newCapital, uint256 reserveBps)
        internal pure returns (uint256 ra, uint256 rw)
    {
        if (p == 0) {
            ra = Math.mulDiv(assetBal, reserveBps, DIVISOR);
            rw = Math.mulDiv(wethBal, reserveBps, DIVISOR);
        } else {
            uint256 deployable = wethBal + Math.mulDiv(assetBal, 1e18, p);
            if (deployable == 0) return (0, 0);
            uint256 want = Math.mulDiv(newCapital, reserveBps, DIVISOR);
            if (want > deployable) want = deployable;
            ra = Math.mulDiv(assetBal, want, deployable);
            rw = Math.mulDiv(wethBal, want, deployable);
        }
        if (ra > assetBal) ra = assetBal;
        if (rw > wethBal) rw = wethBal;
    }

    // ---- equivalence ----------------------------------------------------------------------------------------

    function testFuzz_RebalanceLegsMatchesBothOldBodies(uint128 a, uint128 w, uint128 p, uint64 share) public pure {
        share = uint64(bound(share, 0, 1e18));
        (uint256 sA, uint256 sW, uint256 pA, uint256 pW) = LiquidityLibraryV4.rebalanceLegs(a, w, p, share);
        (uint256 oSA, uint256 oSW) = _oldBalance(a, w, p, share);
        (uint256 oPA, uint256 oPW) = _oldDeficit(a, w, p, share);
        assertEq(sA, oSA, "sellAsset");
        assertEq(sW, oSW, "sellWeth");
        assertEq(pA, oPA, "pullAsset");
        assertEq(pW, oPW, "pullWeth");
        // Exactly one side is ever active.
        assertTrue((sA == 0 && pW == 0) || (sW == 0 && pA == 0), "one side only");
    }

    function testFuzz_ReservePeelMatchesOldBody(uint128 a, uint128 w, uint128 p, uint128 cap, uint16 bps) public pure {
        bps = uint16(bound(bps, 0, DIVISOR));
        (uint256 ra, uint256 rw) = LiquidityLibraryV4.reservePeel(a, w, p, cap, bps, DIVISOR);
        (uint256 oRa, uint256 oRw) = _oldPeel(a, w, p, cap, bps);
        assertEq(ra, oRa, "ra");
        assertEq(rw, oRw, "rw");
        assertLe(ra, a);
        assertLe(rw, w);
    }

    function test_SymmetricShareAtParityLeavesBalancedInventoryAlone() public pure {
        (uint256 sA, uint256 sW, uint256 pA, uint256 pW) = LiquidityLibraryV4.rebalanceLegs(1e18, 1e18, 1e18, 5e17);
        assertEq(sA + sW + pA + pW, 0);
    }

    function test_ThirtySeventyAtParityIsWhatStrandedTheEth() public pure {
        // 1 ASSET + 1 WETH at parity, asked for 30% asset: sell 0.4 ASSET, or pull 0.4 WETH from reserve instead.
        (uint256 sA, uint256 sW, uint256 pA, uint256 pW) = LiquidityLibraryV4.rebalanceLegs(1e18, 1e18, 1e18, 3e17);
        assertEq(sA, 4e17);
        assertEq(pW, 4e17);
        assertEq(sW + pA, 0);
    }
}
