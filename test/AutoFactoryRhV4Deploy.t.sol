// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AutoFactoryRhV4} from "../contracts/auto-vault-rh-v4/AutoFactoryRhV4.sol";

/// @dev The factory builds all four implementations in its own constructor, so its creation code carries theirs.
///      These also cover the library linking: the strategy initcode embedded in the factory holds placeholders for
///      LiquidityLibraryV4 and SwapGateLib, so an unlinked build fails here rather than at broadcast time.
contract AutoFactoryRhV4DeployTest is Test {
    uint256 internal constant EIP170_RUNTIME_LIMIT = 24_576;
    uint256 internal constant EIP3860_INITCODE_LIMIT = 49_152;

    AutoFactoryRhV4 internal factory;

    function setUp() public {
        factory = new AutoFactoryRhV4(
            AutoFactoryRhV4.InfraConfig({
                swapRouter: address(0xA11CE),
                operatorRegistry: address(0xB0B),
                keeper: address(0xC0FFEE),
                feeManager: address(0xDECAF)
            })
        );
    }

    function test_ConstructorDeploysAllFourImplementations() public view {
        assertGt(factory.strategyImplementation().code.length, 0, "strategy");
        assertGt(factory.vaultImplementation().code.length, 0, "vault");
        assertGt(factory.liquidSharesImplementation().code.length, 0, "liquidShares");
        assertGt(factory.shareStakingImplementation().code.length, 0, "shareStaking");
    }

    function test_ImplementationsFitRuntimeLimit() public view {
        assertLt(factory.strategyImplementation().code.length, EIP170_RUNTIME_LIMIT, "strategy");
        assertLt(factory.vaultImplementation().code.length, EIP170_RUNTIME_LIMIT, "vault");
        assertLt(factory.liquidSharesImplementation().code.length, EIP170_RUNTIME_LIMIT, "liquidShares");
        assertLt(factory.shareStakingImplementation().code.length, EIP170_RUNTIME_LIMIT, "shareStaking");
    }

    function test_FactoryFitsInitcodeLimit() public pure {
        assertLt(type(AutoFactoryRhV4).creationCode.length, EIP3860_INITCODE_LIMIT);
    }

    function test_RejectsZeroInfraAddress() public {
        vm.expectRevert(AutoFactoryRhV4.ZeroAddress.selector);
        new AutoFactoryRhV4(
            AutoFactoryRhV4.InfraConfig({
                swapRouter: address(0),
                operatorRegistry: address(0xB0B),
                keeper: address(0xC0FFEE),
                feeManager: address(0xDECAF)
            })
        );
    }
}
