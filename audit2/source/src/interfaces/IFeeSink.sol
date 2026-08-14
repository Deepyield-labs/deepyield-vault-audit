// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IFeeSink
/// @notice Interface for any contract that wants to receive protocol-fee
///         transfers from `BeefyCLMAdapter` AND lock the recipient
///         entitlement at the time the fee is realized (NOT at the time it is
///         later distributed).
/// @dev    The intended implementer is `FeeSplitter`. A non-sink (plain EOA
///         or generic Safe) treasury is also supported via the strategy's
///         `treasuryIsFeeSink` flag, in which case `recordFee` is NOT called.
interface IFeeSink {
    /// @notice Pulls `amount` of the fee asset from `msg.sender` (the strategy)
    ///         and locks its split per the sink's current configuration.
    ///         Caller MUST have set ERC-20 allowance for this contract to at
    ///         least `amount` before calling.
    /// @dev    Implementations MUST do the actual `transferFrom` so the
    ///         strategy can verify the pull happened via a balance delta.
    function recordFee(uint256 amount) external;
}
