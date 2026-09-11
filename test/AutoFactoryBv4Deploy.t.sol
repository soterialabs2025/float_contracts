// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AutoFactoryBv4} from "../contracts/auto-vault-base-v4/AutoFactoryBv4.sol";

/// @dev The factory builds strategy/vault/liquid implementations in its constructor (cloned per package) and
///      CREATE's ShareStakingBv4 per package, so factory runtime carries ShareStaking create bytecode.
///      These also cover the library linking: the strategy initcode embedded in the factory holds placeholders for
///      LiquidityLibraryV4 and SwapGateLib, so an unlinked build fails here rather than at broadcast time.
contract AutoFactoryBv4DeployTest is Test {
    uint256 internal constant EIP170_RUNTIME_LIMIT = 24_576;
    uint256 internal constant EIP3860_INITCODE_LIMIT = 49_152;

    AutoFactoryBv4 internal factory;

    function setUp() public {
        factory = new AutoFactoryBv4(
            AutoFactoryBv4.InfraConfig({
                swapRouter: address(0xA11CE),
                operatorRegistry: address(0xB0B),
                keeper: address(0xC0FFEE),
                feeManager: address(0xDECAF)
            })
        );
    }

    function test_ConstructorDeploysCloneImplementations() public view {
        assertGt(factory.strategyImplementation().code.length, 0, "strategy");
        assertGt(factory.vaultImplementation().code.length, 0, "vault");
        assertGt(factory.liquidSharesImplementation().code.length, 0, "liquidShares");
    }

    function test_ImplementationsFitRuntimeLimit() public view {
        assertLt(factory.strategyImplementation().code.length, EIP170_RUNTIME_LIMIT, "strategy");
        assertLt(factory.vaultImplementation().code.length, EIP170_RUNTIME_LIMIT, "vault");
        assertLt(factory.liquidSharesImplementation().code.length, EIP170_RUNTIME_LIMIT, "liquidShares");
        assertLt(address(factory).code.length, EIP170_RUNTIME_LIMIT, "factory");
    }

    function test_FactoryFitsInitcodeLimit() public pure {
        assertLt(type(AutoFactoryBv4).creationCode.length, EIP3860_INITCODE_LIMIT);
    }

    function test_RejectsZeroInfraAddress() public {
        vm.expectRevert(AutoFactoryBv4.ZeroAddress.selector);
        new AutoFactoryBv4(
            AutoFactoryBv4.InfraConfig({
                swapRouter: address(0),
                operatorRegistry: address(0xB0B),
                keeper: address(0xC0FFEE),
                feeManager: address(0xDECAF)
            })
        );
    }
}
