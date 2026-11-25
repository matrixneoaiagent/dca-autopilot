// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Shared limits and fixed-point constants for the DCA Autopilot.
/// @dev Inherited by both the vault and the reactive contract so a plan that
///      the vault accepts can always be mirrored by the reactive contract.
abstract contract DcaConstants {
    /// @notice Basis points denominator (100% = 10_000).
    uint256 internal constant BPS = 10_000;

    /// @notice The price feed reports USD per base token with 8 decimals.
    uint256 internal constant PRICE_SCALE = 1e8;

    /// @notice Demo-scale cap. Every reactive tick scans every mirrored plan,
    ///         so the list is deliberately bounded. Production deployments
    ///         would shard plans across multiple reactive contracts.
    uint256 internal constant MAX_PLANS = 32;

    /// @notice Maximum base-token amount per buy (1e24 = 1,000,000 tokens at
    ///         18 decimals). Keeps the quote maths far away from overflow.
    uint256 internal constant MAX_BASE_PER_BUY = 1e24;

    /// @notice A plan may require at most a 50% drop before buying.
    uint256 internal constant MAX_DRAWDOWN_BPS = 5_000;

    /// @notice Cooldowns longer than 30 days are almost certainly a mistake.
    uint256 internal constant MAX_COOLDOWN = 30 days;

    /// @notice A plan can execute at most 1,000 buys.
    uint256 internal constant MAX_BUYS = 1_000;
}
