// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AutoFactoryRhV4} from "../contracts/auto-vault-rh-v4/AutoFactoryRhV4.sol";
import {AutoStrategyRhV4} from "../contracts/auto-vault-rh-v4/AutoStrategyRhV4.sol";
import {AutoVaultRhV4} from "../contracts/auto-vault-rh-v4/AutoVaultRhV4.sol";
import {LiquidSharesRhV4} from "../contracts/auto-vault-rh-v4/LiquidSharesRhV4.sol";

/// @dev Clone implementations are deployed first (so factory initcode stays under EIP-3860), then passed
///      into the factory constructor. ShareStakingRhV4 is still CREATE'd per package from factory runtime.
contract AutoFactoryRhV4DeployTest is Test {
    uint256 internal constant EIP170_RUNTIME_LIMIT = 24_576;
    uint256 internal constant EIP3860_INITCODE_LIMIT = 49_152;

    AutoFactoryRhV4 internal factory;

    function setUp() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        address strategyImpl = address(new AutoStrategyRhV4(predicted));
        address vaultImpl = address(new AutoVaultRhV4(predicted));
        address liquidSharesImpl = address(new LiquidSharesRhV4(predicted));
        factory = new AutoFactoryRhV4(
            AutoFactoryRhV4.InfraConfig({
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
            }),
            address(1),
            address(1),
            address(1)
        );
    }
}
