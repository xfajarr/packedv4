// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal swap surface the vault needs. Kept behind an interface so the vault
///         is testable without a live pool, and so the concrete router is a constructor
///         argument whose byte offset `pack` can locate.
interface IBasketRouter {
    /// @notice Swap exactly `msg.value` of native ETH into `tokenOut`, sending it to `to`.
    /// @return amountOut units of `tokenOut` delivered
    function swapExactEthFor(address tokenOut, address to, uint256 minOut)
        external
        payable
        returns (uint256 amountOut);
}
