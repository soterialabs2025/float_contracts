// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOperatorRegistry {
    function isOperator(address account) external view returns (bool);
}
