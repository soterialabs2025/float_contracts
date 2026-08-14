// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./V3Deployments4663.sol";
import "./AutoStrategyV3Rh.sol";
import "./AutoVaultV3Rh.sol";
import "./AutoLiquidToken.sol";
import "./interfaces/IAutoSwapRouterV3.sol";
import "./interfaces/IAutoKeeper.sol";
import "./interfaces/IAutoOperatorRegistry.sol";
import "./interfaces/IUniswapV3Factory.sol";

contract AutoFactoryV3Rh is Ownable {
    using Clones for address;

    struct InfraConfig {
        address swapRouter;
        address operatorRegistry;
        address keeper;
        address feeManager;
    }

    struct VaultRegistry {
        address strategy;
        address vault;
        address liquidToken;
        uint24 poolFee;
        bool active;
    }

    InfraConfig public infra;
    address public immutable strategyImplementation;
    address public immutable vaultImplementation;
    address public immutable liquidTokenImplementation;
    mapping(address => VaultRegistry) public registry;
    address[] public assets;

    error ZeroAddress();
    error InvalidPool();
    error AlreadyDeployed();
    error Unauthorized();

    event VaultRegistryDeployed(
        address indexed strategy,
        address indexed vault,
        address indexed liquidToken,
        address asset,
        uint24 poolFee,
        address owner,
        uint256 keeperId
    );
    event VaultRegistryUpdated(address indexed asset, address strategy, address vault, bool active);

    constructor(InfraConfig memory config) Ownable(msg.sender) {
        _validateInfra(config);
        infra = config;
        strategyImplementation = address(new AutoStrategyV3Rh(address(this)));
        vaultImplementation = address(new AutoVaultV3Rh());
        liquidTokenImplementation = address(new AutoLiquidToken());
    }

    modifier onlyOperator() {
        if (!IAutoOperatorRegistry(infra.operatorRegistry).isOperator(msg.sender) && msg.sender != owner()) {
            revert Unauthorized();
        }
        _;
    }

    function updateInfra(InfraConfig calldata config) external onlyOwner {
        _validateInfra(config);
        infra = config;
    }

    function assetsLength() external view returns (uint256) {
        return assets.length;
    }

    function setPackage(address asset, address strategy, address vault, address liquidToken, uint24 fee, bool active)
        external
        onlyOwner
    {
        if (asset == address(0)) revert ZeroAddress();
        if (registry[asset].strategy == address(0) && strategy != address(0)) assets.push(asset);
        registry[asset] = VaultRegistry(strategy, vault, liquidToken, fee, active);
        emit VaultRegistryUpdated(asset, strategy, vault, active);
    }

    function deployVaultPackage(address asset, uint24 poolFee)
        external
        onlyOperator
        returns (address strategy, address vault, address liquidToken, uint256 keeperId)
    {
        if (asset == address(0)) revert ZeroAddress();
        if (registry[asset].strategy != address(0)) revert AlreadyDeployed();
        if (IUniswapV3Factory(V3Deployments4663.FACTORY).getPool(asset, V3Deployments4663.WETH, poolFee) == address(0))
        {
            revert InvalidPool();
        }

        strategy = strategyImplementation.clone();
        vault = vaultImplementation.clone();
        liquidToken = liquidTokenImplementation.clone();
        AutoLiquidToken(liquidToken).bootstrap(vault);
        AutoVaultV3Rh(payable(vault)).bootstrap(msg.sender, strategy, liquidToken, asset);
        AutoStrategyV3Rh(payable(strategy))
            .bootstrap(
                msg.sender,
                vault,
                infra.swapRouter,
                infra.operatorRegistry,
                infra.keeper,
                infra.feeManager,
                asset,
                poolFee
            );
        IAutoSwapRouterV3(infra.swapRouter).addAuthorizedStrategy(strategy);
        keeperId = IAutoKeeper(infra.keeper).addStrategy(strategy);

        registry[asset] = VaultRegistry(strategy, vault, liquidToken, poolFee, true);
        assets.push(asset);
        emit VaultRegistryDeployed(strategy, vault, liquidToken, asset, poolFee, msg.sender, keeperId);
        emit VaultRegistryUpdated(asset, strategy, vault, true);
    }

    function _validateInfra(InfraConfig memory config) private pure {
        if (
            config.swapRouter == address(0) || config.operatorRegistry == address(0) || config.keeper == address(0)
                || config.feeManager == address(0)
        ) revert ZeroAddress();
    }
}
