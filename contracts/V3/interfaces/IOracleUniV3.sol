// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


interface IOracleUniV3 {
    function getPrice(bytes calldata _data) external returns (uint256 price, bool success);
    function validateData(bytes calldata _data) external view;
}