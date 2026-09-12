// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AutoFactoryBv4} from "../contracts/auto-vault-base-v4/AutoFactoryBv4.sol";
import {AutoStrategyBv4} from "../contracts/auto-vault-base-v4/AutoStrategyBv4.sol";
import {AutoVaultBv4} from "../contracts/auto-vault-base-v4/AutoVaultBv4.sol";
import {LiquidSharesBv4} from "../contracts/auto-vault-base-v4/LiquidSharesBv4.sol";

/// @dev Clone implementations are deployed first (so factory initcode stays under EIP-3860), then passed
///      into the factory constructor. ShareStakingBv4 is still CREATE'd per package from factory runtime.
contract AutoFactoryBv4DeployTest is Test {
    uint256 internal constant EIP170_RUNTIME_LIMIT = 24_576;
    uint256 internal constant EIP3860_INITCODE_LIMIT = 49_152;

    AutoFactoryBv4 internal factory;

    function setUp() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        address strategyImpl = address(new AutoStrategyBv4(predicted));
        address vaultImpl = address(new AutoVaultBv4(predicted));
        address liquidSharesImpl = address(new LiquidSharesBv4(predicted));
        factory = new AutoFactoryBv4(
            AutoFactoryBv4.InfraConfig({
                swapRouter: address(0xA11CE),
                operatorRegistry: address(0xB0B),
                keeper: address(0xC0FFEE),
                feeManager: address(0xDECAF)
            }),
            strategyImpl,
            vaultImpl,
            liquidSharesImpl
        );
        assertEq(address(factory), predicted, "factory CREATE address");
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
            }),
            address(1),
            address(1),
            address(1)
        );
    }
}
