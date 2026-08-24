// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAutoVaultBv4 {
    function depositETH() external payable returns (uint256 shares);
    /// @param asAsset true → receive ASSET; false → receive WETH
    function withdraw(uint256 shares, bool asAsset) external returns (uint256 assets);

    /// @notice Strategy NAV in WETH-notional (forwards to strategy).
    function balance() external view returns (uint256);
    /// @notice Share balance (forwards to liquid shares).
    function balanceOf(address account) external view returns (uint256);
    /// @notice Share supply (forwards to liquid shares).
    function totalSupply() external view returns (uint256);

    /// @notice Emit NAV + cumulative Uniswap fees (off-chain). Callable only by AutoKeeper.
    function recordPoolValueSnapshot() external;
}
