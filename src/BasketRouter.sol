// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IBasketRouter} from "./IBasketRouter.sol";

interface IERC20Min {
    function transfer(address to, uint256 value) external returns (bool);
}

/// @title BasketRouter
/// @notice Swaps native ETH into a constituent through its Uniswap v4 pool.
/// @dev v4 has no external swap entrypoint: you call `unlock` and do the work inside the
///      callback, settling every delta before it returns. Each constituent's PoolKey is
///      fixed at deploy — the wrong key would route into an empty pool, and on this chain
///      there are decoy contracts that make that a live risk.
contract BasketRouter is IBasketRouter, IUnlockCallback {
    IPoolManager public immutable poolManager;

    struct Route {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        int24 tickSpacing;
        IHooks hooks;
        bool set;
    }

    mapping(address asset => Route) private _routes;

    error NotPoolManager();
    error NoRouteForAsset();
    error InsufficientOutput();
    error EthTransferFailed();

    constructor(IPoolManager _poolManager, address[] memory assets, PoolKey[] memory keys) {
        poolManager = _poolManager;
        uint256 n = assets.length;
        require(n == keys.length, "len");
        for (uint256 i; i < n; ++i) {
            PoolKey memory k = keys[i];
            _routes[assets[i]] = Route(k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks, true);
        }
    }

    function routeOf(address asset) external view returns (PoolKey memory k, bool set) {
        Route storage r = _routes[asset];
        return (PoolKey(r.currency0, r.currency1, r.fee, r.tickSpacing, r.hooks), r.set);
    }

    /// @inheritdoc IBasketRouter
    function swapExactEthFor(address tokenOut, address to, uint256 minOut)
        external
        payable
        returns (uint256 amountOut)
    {
        Route storage r = _routes[tokenOut];
        if (!r.set) revert NoRouteForAsset();

        bytes memory res = poolManager.unlock(
            abi.encode(PoolKey(r.currency0, r.currency1, r.fee, r.tickSpacing, r.hooks), tokenOut, msg.value)
        );
        amountOut = abi.decode(res, (uint256));
        if (amountOut < minOut) revert InsufficientOutput();

        if (!IERC20Min(tokenOut).transfer(to, amountOut)) revert EthTransferFailed();
    }

    /// @dev Every delta opened here must be closed before this returns, or v4 reverts.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, address tokenOut, uint256 amountIn) =
            abi.decode(data, (PoolKey, address, uint256));

        // currency0 is native ETH, so ETH in means zeroForOne.
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: 4295128740 // MIN_SQRT_PRICE + 1
            }),
            ""
        );

        // Pay what we owe in ETH, collect what we are owed in the asset.
        poolManager.settle{value: amountIn}();
        uint256 out = uint256(uint128(delta.amount1()));
        poolManager.take(Currency.wrap(tokenOut), address(this), out);

        return abi.encode(out);
    }

    receive() external payable {}
}
