// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AutoStrategyManagerBv4} from "../contracts/auto-vault-base-v4/AutoStrategyManagerBv4.sol";
import {AutoStrategyManagerRhV4} from "../contracts/auto-vault-rh-v4/AutoStrategyManagerRhV4.sol";
import {AutoStrategyManagerBv3} from "../contracts/auto-vaults-base-v3/AutoStrategyManagerBv3.sol";
import {AutoStrategyManagerRhV3} from "../contracts/auto-vaults-rh-v3/AutoStrategyManagerRhV3.sol";
import {AutoStrategyManagerSv3} from "../contracts/auto-vaults-rh-sushi-v3/AutoStrategyManagerSv3.sol";

// Each stack ships its own copy of these libraries, but the error names are identical, and a custom error
// selector is derived from its name and arguments. One import therefore gives the right selector for all five.
import {AutoBandLib} from "../contracts/auto-vault-base-v4/libraries/AutoBandLib.sol";
import {TrailingFloorLib} from "../contracts/v4/libraries/TrailingFloorLib.sol";

interface IBandParams {
    function setBandParams(uint256, uint256, uint256, uint256) external;
    function setProtocolFeeOn(bool) external;
    function protocolFeeOn() external view returns (bool);
    function protocolFeeBps() external view returns (uint256);
    function tickSpacing() external view returns (int24);
    function rangeBelowTicks() external view returns (uint256);
    function rangeAboveTicks() external view returns (uint256);
    function innerBelowTicks() external view returns (uint256);
    function innerAboveTicks() external view returns (uint256);
}

contract OpenBandBv4 is AutoStrategyManagerBv4 {
    function _isOperator() internal view override returns (bool) {
        return true;
    }
}

contract OpenBandRhV4 is AutoStrategyManagerRhV4 {
    function _isOperator() internal view override returns (bool) {
        return true;
    }
}

contract OpenBandBv3 is AutoStrategyManagerBv3 {
    function _isOperator() internal view override returns (bool) {
        return true;
    }
}

contract OpenBandRhV3 is AutoStrategyManagerRhV3 {
    function _isOperator() internal view override returns (bool) {
        return true;
    }
}

contract OpenBandSv3 is AutoStrategyManagerSv3 {
    function _isOperator() internal view override returns (bool) {
        return true;
    }
}

/// @notice Cover for `setBandParams`, the single setter that replaced `setRangeParams` + `setInnerBandParams`.
/// @dev Run against all five managers rather than one, because the band setter is the piece a keeper drives on a
///      schedule and the five copies are maintained by hand. A test that only pinned Bv4 would let the other four
///      drift, which is how RhV4 came to be the only one validating tick alignment in the first place.
contract BandParamsTest is Test {
    address internal constant STRANGER = address(0xBADD);

    IBandParams[5] internal managers;
    string[5] internal names;

    function setUp() public {
        managers[0] = IBandParams(address(new OpenBandBv4()));
        managers[1] = IBandParams(address(new OpenBandRhV4()));
        managers[2] = IBandParams(address(new OpenBandBv3()));
        managers[3] = IBandParams(address(new OpenBandRhV3()));
        managers[4] = IBandParams(address(new OpenBandSv3()));
        names = ["Bv4", "RhV4", "Bv3", "RhV3", "Sv3"];
    }

    /// @dev Band widths are expressed in multiples of each manager's own spacing so the same case runs against
    ///      RhV4's 160 and everyone else's 200 without hardcoding either.
    function _sp(uint256 i) internal view returns (uint256) {
        return uint256(uint24(managers[i].tickSpacing()));
    }

    /// @dev Puts a manager in a known-good state: outer four spacings each way, inner three.
    function _seed(uint256 i) internal {
        uint256 sp = _sp(i);
        managers[i].setBandParams(4 * sp, 4 * sp, 3 * sp, 3 * sp);
    }

    function _assertBands(uint256 i, uint256 rb, uint256 ra, uint256 ib, uint256 ia) internal view {
        assertEq(managers[i].rangeBelowTicks(), rb, names[i]);
        assertEq(managers[i].rangeAboveTicks(), ra, names[i]);
        assertEq(managers[i].innerBelowTicks(), ib, names[i]);
        assertEq(managers[i].innerAboveTicks(), ia, names[i]);
    }

    /// @dev The constraint the two old setters each enforced against whatever half was already in storage.
    ///      Replicated here so the ordering test can state what each legacy call would have seen, rather than
    ///      asserting the new setter works and leaving the reason implicit.
    function _innerWithinOuter(uint256 rb, uint256 ra, uint256 ib, uint256 ia) internal pure returns (bool) {
        return ib <= rb && ia <= ra && ib != 0 && ia != 0;
    }

    function test_SetsOuterAndInnerInOneCall() public {
        for (uint256 i = 0; i < managers.length; i++) {
            uint256 sp = _sp(i);
            _seed(i);
            managers[i].setBandParams(6 * sp, 5 * sp, 2 * sp, 4 * sp);
            _assertBands(i, 6 * sp, 5 * sp, 2 * sp, 4 * sp);
        }
    }

    /// @notice The reason the two setters were merged: some band moves were unreachable in either order.
    /// @dev Skewing the band asymmetrically tightens one side while widening the other. Applying the outer first
    ///      leaves the old inner poking out of the newly tightened side; applying the inner first pokes the new
    ///      inner out of the not-yet-widened side. Both legacy calls revert, so the move needed a third
    ///      intermediate write to get through. Validating all four at once makes it a single transaction.
    function test_AllowsSkewNeitherLegacyOrderCouldReach() public {
        for (uint256 i = 0; i < managers.length; i++) {
            uint256 sp = _sp(i);
            _seed(i);

            (uint256 rb, uint256 ra, uint256 ib, uint256 ia) = (2 * sp, 6 * sp, 1 * sp, 5 * sp);

            // Outer first: new outer vs. the inner still in storage.
            assertFalse(_innerWithinOuter(rb, ra, 3 * sp, 3 * sp), names[i]);
            // Inner first: new inner vs. the outer still in storage.
            assertFalse(_innerWithinOuter(4 * sp, 4 * sp, ib, ia), names[i]);
            // The destination itself was always valid; only the paths to it were blocked.
            assertTrue(_innerWithinOuter(rb, ra, ib, ia), names[i]);

            managers[i].setBandParams(rb, ra, ib, ia);
            _assertBands(i, rb, ra, ib, ia);
        }
    }

    function test_RevertsWhenInnerWiderThanOuter() public {
        for (uint256 i = 0; i < managers.length; i++) {
            uint256 sp = _sp(i);
            _seed(i);

            vm.expectRevert(AutoBandLib.InnerWiderThanOuter.selector);
            managers[i].setBandParams(4 * sp, 4 * sp, 5 * sp, 3 * sp);

            vm.expectRevert(AutoBandLib.InnerWiderThanOuter.selector);
            managers[i].setBandParams(4 * sp, 4 * sp, 3 * sp, 5 * sp);

            _assertBands(i, 4 * sp, 4 * sp, 3 * sp, 3 * sp);
        }
    }

    /// @dev Unaligned widths used to be accepted here and rejected later by `asymmetricSpacedTicks` on the mint
    ///      path, which turned a bad setter call into a strategy that could no longer remint.
    function test_RevertsOnTicksNotAlignedToSpacing() public {
        for (uint256 i = 0; i < managers.length; i++) {
            uint256 sp = _sp(i);
            _seed(i);

            vm.expectRevert(TrailingFloorLib.RangeNotAlignedToSpacing.selector);
            managers[i].setBandParams(4 * sp + 1, 4 * sp, 3 * sp, 3 * sp);

            vm.expectRevert(TrailingFloorLib.RangeNotAlignedToSpacing.selector);
            managers[i].setBandParams(4 * sp, 4 * sp + 1, 3 * sp, 3 * sp);

            vm.expectRevert(TrailingFloorLib.RangeNotAlignedToSpacing.selector);
            managers[i].setBandParams(4 * sp, 4 * sp, 3 * sp + 1, 3 * sp);

            vm.expectRevert(TrailingFloorLib.RangeNotAlignedToSpacing.selector);
            managers[i].setBandParams(4 * sp, 4 * sp, 3 * sp, 3 * sp + 1);

            _assertBands(i, 4 * sp, 4 * sp, 3 * sp, 3 * sp);
        }
    }

    /// @dev A zero width is caught by the alignment check before it reaches `InnerNotInsideOuter`; either way it
    ///      must not be storable, since a zero-width inner band would report the pool as permanently out of band.
    function test_RevertsOnZeroWidth() public {
        for (uint256 i = 0; i < managers.length; i++) {
            uint256 sp = _sp(i);
            _seed(i);

            vm.expectRevert(TrailingFloorLib.RangeNotAlignedToSpacing.selector);
            managers[i].setBandParams(4 * sp, 4 * sp, 0, 3 * sp);

            vm.expectRevert(TrailingFloorLib.RangeNotAlignedToSpacing.selector);
            managers[i].setBandParams(0, 4 * sp, 3 * sp, 3 * sp);

            _assertBands(i, 4 * sp, 4 * sp, 3 * sp, 3 * sp);
        }
    }

    function test_RevertsWhenNotOperator() public {
        IBandParams[5] memory raw;
        raw[0] = IBandParams(address(new AutoStrategyManagerBv4()));
        raw[1] = IBandParams(address(new AutoStrategyManagerRhV4()));
        raw[2] = IBandParams(address(new AutoStrategyManagerBv3()));
        raw[3] = IBandParams(address(new AutoStrategyManagerRhV3()));
        raw[4] = IBandParams(address(new AutoStrategyManagerSv3()));

        for (uint256 i = 0; i < raw.length; i++) {
            uint256 sp = uint256(uint24(raw[i].tickSpacing()));
            vm.expectRevert(AutoStrategyManagerBv4.NotOperator.selector);
            raw[i].setBandParams(4 * sp, 4 * sp, 3 * sp, 3 * sp);
        }
    }

    /// @dev The old selectors must be gone, not merely unused: a keeper still calling them should fail loudly at
    ///      simulation rather than silently no-op through the fallback of a contract that has none.
    function test_ProtocolFeeDefaultsOnAndKeepsBps() public {
        for (uint256 i = 0; i < managers.length; i++) {
            assertTrue(managers[i].protocolFeeOn(), names[i]);
            assertEq(managers[i].protocolFeeBps(), 600, names[i]);

            managers[i].setProtocolFeeOn(false);
            assertFalse(managers[i].protocolFeeOn(), names[i]);
            assertEq(managers[i].protocolFeeBps(), 600, names[i]);

            managers[i].setProtocolFeeOn(true);
            assertTrue(managers[i].protocolFeeOn(), names[i]);
        }
    }

    function test_ProtocolFeeSwitchRevertsForNonOwner() public {
        for (uint256 i = 0; i < managers.length; i++) {
            vm.prank(STRANGER);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
            managers[i].setProtocolFeeOn(false);
            assertTrue(managers[i].protocolFeeOn(), names[i]);
        }
    }

    function test_LegacySettersAreRemoved() public {
        for (uint256 i = 0; i < managers.length; i++) {
            address m = address(managers[i]);

            (bool okRange,) = m.call(abi.encodeWithSignature("setRangeParams(uint256,uint256)", uint256(800), uint256(800)));
            assertFalse(okRange, names[i]);

            (bool okInner,) = m.call(abi.encodeWithSignature("setInnerBandParams(uint256,uint256)", uint256(600), uint256(600)));
            assertFalse(okInner, names[i]);
        }
    }
}
