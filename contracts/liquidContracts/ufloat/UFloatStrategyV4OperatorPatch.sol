// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Apply these edits to your existing UFloatStrategyV4 + UStrategyManager + Factory.
///
/// 1) UStrategyOperatorAuth — inherit instead of storing `tritonAddr`.
/// 2) bootstrapStrategy — replace `address triton` with `address operatorRegistry_`.
/// 3) exitToStable — `onlyOperatorOrOwner` instead of `tritonAddr || owner`.
///
/// Example bootstrap (was: triton, keeper):
/*
function bootstrapStrategy(
    address owner_,
    address swapRouter,
    address operatorRegistry_,
    address keeper,
    StratMethod stratMethod_,
    address[] calldata tokens
) external {
    if (_initialized) revert AlreadyInitialized();
    if (msg.sender != factory) revert Unauthorized();
    if (owner_ == address(0) || swapRouter == address(0)) revert ZeroAddress();
    if (tokens.length == 0) revert TokenNotAllowed();
    _initialized = true;

    _setOperatorInfra(operatorRegistry_, keeper);
    swapRouterV4 = IUFloatV4StrategySwapRouter(swapRouter);
    _initStrategyDefaults();
    stratMethod = stratMethod_;

    uint256 len = tokens.length;
    for (uint256 i = 0; i < len; i++) {
        _addAllowedToken(tokens[i]);
    }
    _configureAsset(tokens[0]);
    stratMode = Mode.NORMAL;
    defensiveEnteredAt = 0;
    _transferOwnership(owner_);
}
*/
///
/// Example exitToStable:
/*
function exitToStable() external onlyOperatorOrOwner {
    _changeAsset(address(WETH));
}
*/
///
/// Remove: `address private tritonAddr;` and all `tritonAddr = triton` assignments.
///
/// Factory InfraConfig (was triton → operatorRegistry):
/*
struct InfraConfig {
    address swapRouter;
    address operatorRegistry;
    address keeper;
}
...
strategy.bootstrapStrategy(
    owner_,
    infra.swapRouter,
    infra.operatorRegistry,
    infra.keeper,
    stratMethod_,
    tokens
);
*/

library UFloatStrategyV4OperatorPatch {}
