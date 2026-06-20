// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IOperatorRegistry.sol";


abstract contract UStrategyOperatorAuth {
    error Unauthorized();

    IOperatorRegistry public operatorRegistry;
    address internal keeperStratAddr;

    function _strategyOwner() internal view virtual returns (address);

    function _setOperatorInfra(address operatorRegistry_, address keeper_) internal {
        if (operatorRegistry_ == address(0)) revert Unauthorized();
        operatorRegistry = IOperatorRegistry(operatorRegistry_);
        keeperStratAddr = keeper_;
    }

    function _authCaller() internal view virtual returns (address) {
        return msg.sender;
    }

    function _requireAuthorized() internal view {
        address s = _authCaller();
        if (!operatorRegistry.isOperator(s) && s != keeperStratAddr && s != _strategyOwner()) {
            revert Unauthorized();
        }
    }

    function _requireOperatorOrOwner() internal view {
        address s = _authCaller();
        if (!operatorRegistry.isOperator(s) && s != _strategyOwner()) revert Unauthorized();
    }

    modifier onlyAuthorized() {
        _requireAuthorized();
        _;
    }

    modifier onlyOperatorOrOwner() {
        _requireOperatorOrOwner();
        _;
    }
}
