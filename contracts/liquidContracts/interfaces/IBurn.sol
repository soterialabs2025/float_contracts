// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

/// @title IBurn.
/// @notice Calls $TERM contract function burn to burn $TERMS

interface IBurn {
  function burn(uint256 value) external;
}