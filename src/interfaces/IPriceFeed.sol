// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice The historical price surface the vault uses to bind a callback to
///         a real published tick.
interface IPriceFeed {
    function priceOf(uint256 tickId) external view returns (uint256);
    function publishedAt(uint256 tickId) external view returns (uint256);
    function tickId() external view returns (uint256);
}
