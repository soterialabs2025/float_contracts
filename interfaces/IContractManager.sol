
// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

/// @title Controller Interface for Contract Manager.
/// @notice This is used to get deployed contract addresses. 

interface IContractManager {
    function getAddress(string memory _name) external view returns(address); 
}
 