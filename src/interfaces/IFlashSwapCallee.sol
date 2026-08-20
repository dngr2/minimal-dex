// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IFlashSwapCallee
/// @notice Callback interface a flash-swap borrower must implement. The Pair optimistically
///         sends the requested outputs, then invokes this callback; on return the Pair enforces
///         the constant-product invariant on the post-callback balances (borrower must have
///         repaid the borrowed tokens plus the 0.30% fee, or supplied the other side).
interface IFlashSwapCallee {
    function flashSwapCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}
