// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IBasketToken} from "./IBasketToken.sol";

/// @title BasketHook
/// @notice Day-1 skeleton. Callback surface and permission bits are final; fee routing
///         and basket accounting land on top of this without changing the address.
/// @dev Permission bits are encoded in the deployed address. This contract needs
///      BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA == 0xC8.
contract BasketHook is IHooks {
    /// @notice Required address flags. Mine a CREATE2 salt until the address matches.
    uint160 internal constant REQUIRED_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    /// @notice Fee on buys, hundredths of a bip. 20000 = 2.00%.
    uint256 public constant BUY_FEE = 20_000;
    /// @notice Fee on sells, hundredths of a bip. 30000 = 3.00%.
    uint256 public constant SELL_FEE = 30_000;
    uint256 private constant FEE_DENOM = 1_000_000;

    IPoolManager public immutable poolManager;

    error NotPoolManager();
    error PoolMustBeNativeEth();
    error HookNotImplemented();
    error InvalidHookAddress();

    /// @dev Callback authentication. Programmable's static admission hard-blocks a hook
    ///      whose callbacks are callable by anyone.
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        // Fail loudly at deploy rather than silently never being called.
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != REQUIRED_FLAGS) revert InvalidHookAddress();
    }

    /* ---------------------------------------------------------------- active */

    /// @dev The pool is always ETH/TOKEN, so currency0 is native and currency1 is the
    ///      BasketToken. Reading it from the key avoids a constructor cycle (the token
    ///      needs the hook address, the hook would need the token address) and avoids a
    ///      setter, which Programmable admission scrutinises.
    function _token(PoolKey calldata key) private pure returns (IBasketToken) {
        if (!key.currency0.isAddressZero()) revert PoolMustBeNativeEth();
        return IBasketToken(Currency.unwrap(key.currency1));
    }

    /// @notice Buys pay their fee out of the ETH going in.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // zeroForOne == ETH in == a buy. Exact-input only on this leg.
        if (!params.zeroForOne || params.amountSpecified >= 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 fee = (amountIn * BUY_FEE) / FEE_DENOM;
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // Pull the fee out of the swap input, then hand it to the token for distribution.
        poolManager.take(key.currency0, address(this), fee);
        _token(key).depositFee{value: fee}();

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    /// @notice Sells pay their fee out of the ETH coming out, so the pot is always ETH.
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (params.zeroForOne) return (IHooks.afterSwap.selector, int128(0)); // buys handled above

        // Selling TOKEN for ETH: amount0 is the ETH owed to the swapper.
        int128 ethOut = delta.amount0();
        if (ethOut <= 0) return (IHooks.afterSwap.selector, int128(0));

        uint256 fee = (uint256(uint128(ethOut)) * SELL_FEE) / FEE_DENOM;
        if (fee == 0) return (IHooks.afterSwap.selector, int128(0));

        poolManager.take(key.currency0, address(this), fee);
        _token(key).depositFee{value: fee}();

        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    /// @dev Receives the ETH taken from the PoolManager before forwarding it.
    receive() external payable {}

    /* -------------------------------------------------------------- inactive */
    // Never invoked: the address bits above tell the PoolManager not to call these.

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
