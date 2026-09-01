// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IAutoVaultRhV4 {
    function depositETH() external payable returns (uint256 shares);
    /// @param asAsset true → receive ASSET; false → receive ETH
    function withdraw(uint256 shares, bool asAsset) external returns (uint256 assets);

    function balance() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);

    /// @notice Emit NAV + cumulative Uniswap fees (off-chain). Callable only by AutoKeeper.
    function recordPoolValueSnapshot() external;
}
