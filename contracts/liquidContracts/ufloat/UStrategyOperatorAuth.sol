// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IOperatorRegistry.sol";

/// @dev Drop-in auth replacement for single `tritonAddr` on UFloatStrategyV4 clones.
abstract contract UStrategyOperatorAuth {
    error Unauthorized();
    error ZeroAddress();

    IOperatorRegistry public operatorRegistry;
    address internal keeperStratAddr;

    function _setOperatorInfra(address operatorRegistry_, address keeper_) internal {
        if (operatorRegistry_ == address(0)) revert ZeroAddress();
        operatorRegistry = IOperatorRegistry(operatorRegistry_);
        keeperStratAddr = keeper_;
    }

    function _requireAuthorized() internal view {
        address s = msg.sender;
        if (
            !operatorRegistry.isOperator(s) &&
            s != keeperStratAddr &&
            s != owner()
        ) {
            revert Unauthorized();
        }
    }

    function _requireOperatorOrOwner() internal view {
        address s = msg.sender;
        if (!operatorRegistry.isOperator(s) && s != owner()) revert Unauthorized();
    }

    /// @dev Replace existing `_requireAuthorized` gate on `changeAsset`, etc.
    modifier onlyAuthorized() {
        _requireAuthorized();
        _;
    }

    /// @dev Replace `exitToStable` check (`tritonAddr || owner`).
    modifier onlyOperatorOrOwner() {
        _requireOperatorOrOwner();
        _;
    }

    function owner() public view virtual returns (address);
}
