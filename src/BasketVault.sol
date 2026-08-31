// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBasketToken} from "./IBasketToken.sol";
import {IBasketRouter} from "./IBasketRouter.sol";

interface IERC20Min {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @title BasketVault
/// @notice Converts holders' accrued ETH into a fixed basket of tokenized equities.
///
/// @dev The point of this contract is `settle(address[])`. The reference design makes
///      every holder pay for their own basket purchase — five swaps each — so a small
///      holder's share is worth less than the gas to collect it and simply never gets
///      claimed. Batching buys the basket ONCE for many holders and splits the proceeds,
///      so the per-holder cost collapses to a few transfers and small shares become
///      worth settling.
///
///      Constituents and weights are constructor arguments with no setter: fixed at
///      deploy, forever.
contract BasketVault {
    uint256 private constant BIPS = 10_000;

    IBasketRouter public immutable router;

    address[] private _constituents;
    uint256[] private _weightsBips;

    event Settled(uint256 holders, uint256 totalEth);
    event Delivered(address indexed holder, address indexed asset, uint256 amount);

    error LengthMismatch();
    error WeightsMustSumToBips();
    error EmptyBasket();
    error NothingToSettle();
    error HoldersMustAscend();
    error TransferFailed();

    constructor(IBasketRouter _router, address[] memory constituents_, uint256[] memory weightsBips_) {
        if (constituents_.length == 0) revert EmptyBasket();
        if (constituents_.length != weightsBips_.length) revert LengthMismatch();
        uint256 sum;
        for (uint256 i; i < weightsBips_.length; ++i) {
            sum += weightsBips_[i];
        }
        if (sum != BIPS) revert WeightsMustSumToBips();

        router = _router;
        _constituents = constituents_;
        _weightsBips = weightsBips_;
    }

    function constituents() external view returns (address[] memory) {
        return _constituents;
    }

    function weightsBips() external view returns (uint256[] memory) {
        return _weightsBips;
    }

    function basketSize() external view returns (uint256) {
        return _constituents.length;
    }

    /// @notice Settle many holders at once. Permissionless: anyone may run it, and every
    ///         asset bought lands in the holders' own wallets, never the caller's.
    /// @param holders strictly ascending addresses
    /// @dev One swap per constituent regardless of how many holders are settled.
    function settle(IBasketToken token, address[] calldata holders) external {
        uint256 n = holders.length;
        if (n == 0) revert NothingToSettle();

        (uint256[] memory shares, uint256 total) = _pull(token, holders);
        if (total == 0) revert NothingToSettle();

        uint256 len = _constituents.length;
        uint256 spent;
        for (uint256 c; c < len; ++c) {
            // Integer division leaves a remainder across the legs; the final leg absorbs
            // it so no wei is ever stranded in this contract.
            uint256 leg = c == len - 1 ? total - spent : (total * _weightsBips[c]) / BIPS;
            spent += leg;
            if (leg != 0) _buyAndSplit(_constituents[c], leg, holders, shares, total);
        }

        emit Settled(n, total);
    }

    /// @dev Pull every holder's accrued ETH, recording who contributed what.
    function _pull(IBasketToken token, address[] calldata holders)
        private
        returns (uint256[] memory shares, uint256 total)
    {
        uint256 n = holders.length;
        shares = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            // Strictly ascending addresses. This rules out duplicates — which would
            // dilute everyone else's pro-rata — in O(n) rather than O(n^2). Sorting is
            // free for the caller; a quadratic scan would eat the batching saving.
            if (i != 0 && holders[i] <= holders[i - 1]) revert HoldersMustAscend();
            uint256 got = token.claimToVault(holders[i]);
            shares[i] = got;
            total += got;
        }
    }

    /// @dev Buy one constituent for the whole batch, then split it pro-rata.
    function _buyAndSplit(
        address asset,
        uint256 leg,
        address[] calldata holders,
        uint256[] memory shares,
        uint256 total
    ) private {
        uint256 before = IERC20Min(asset).balanceOf(address(this));
        router.swapExactEthFor{value: leg}(asset, address(this), 0);
        uint256 bought = IERC20Min(asset).balanceOf(address(this)) - before;

        uint256 n = holders.length;
        uint256 handedOut;
        for (uint256 i; i < n; ++i) {
            // Last holder absorbs the rounding remainder, so nothing is left behind.
            uint256 cut = i == n - 1 ? bought - handedOut : (bought * shares[i]) / total;
            handedOut += cut;
            if (cut != 0) {
                if (!IERC20Min(asset).transfer(holders[i], cut)) revert TransferFailed();
                emit Delivered(holders[i], asset, cut);
            }
        }
    }

    /// @dev Receives ETH pulled from the token before it is spent on the basket.
    receive() external payable {}
}
