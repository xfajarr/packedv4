// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BasketHook} from "../src/BasketHook.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @dev Minimal PoolManager stand-in: `take` actually moves ETH, which is the only
///      behaviour the hook depends on.
contract MockPoolManager {
    function take(Currency, address to, uint256 amount) external {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "take failed");
    }

    function callBeforeSwap(BasketHook hook, PoolKey memory key, IPoolManager.SwapParams memory p) external {
        hook.beforeSwap(address(this), key, p, "");
    }

    function callAfterSwap(BasketHook hook, PoolKey memory key, IPoolManager.SwapParams memory p, BalanceDelta d)
        external
    {
        hook.afterSwap(address(this), key, p, d, "");
    }

    receive() external payable {}
}

contract BasketHookTest is Test {
    uint160 constant WANT = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    MockPoolManager pm;
    BasketHook hook;
    BasketToken token;
    address alice = makeAddr("alice");

    function setUp() public {
        pm = new MockPoolManager();
        vm.deal(address(pm), 1000 ether);

        bytes memory initCode =
            abi.encodePacked(type(BasketHook).creationCode, abi.encode(IPoolManager(address(pm))));
        bytes32 initHash = keccak256(initCode);
        bytes32 salt;
        address predicted;
        for (uint256 i; i < 500_000; ++i) {
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), CREATE2_FACTORY, salt, initHash))))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == WANT) break;
        }
        vm.prank(CREATE2_FACTORY);
        hook = new BasketHook{salt: salt}(IPoolManager(address(pm)));
        assertEq(address(hook), predicted, "CREATE2 mismatch");

        // The token's only fee source is the hook.
        token = new BasketToken(address(hook), makeAddr("vault"), alice, 1000e18);
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function test_addressCarriesExactPermissions() public view {
        uint160 a = uint160(address(hook));
        assertEq(a & Hooks.ALL_HOOK_MASK, WANT, "wrong permission bits");
        assertTrue(a & Hooks.BEFORE_SWAP_FLAG != 0);
        assertTrue(a & Hooks.AFTER_SWAP_FLAG != 0);
        assertTrue(a & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0);
        assertTrue(a & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0);
        // Anything else on would make the PoolManager call a reverting callback.
        assertEq(a & Hooks.BEFORE_INITIALIZE_FLAG, 0);
        assertEq(a & Hooks.BEFORE_ADD_LIQUIDITY_FLAG, 0);
    }

    function test_callbacksRejectNonPoolManager() public {
        IPoolManager.SwapParams memory p =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        vm.expectRevert(BasketHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), _key(), p, "");
        vm.expectRevert(BasketHook.NotPoolManager.selector);
        hook.afterSwap(address(this), _key(), p, toBalanceDelta(0, 0), "");
    }

    /// @notice A buy pays 2% of its ETH input into the pot.
    function test_buyRoutes2PercentToHolders() public {
        IPoolManager.SwapParams memory p =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0});
        pm.callBeforeSwap(hook, _key(), p);

        assertEq(address(token).balance, 2 ether, "2% of 100 ETH");
        assertEq(token.accruedOf(alice), 2 ether, "sole holder takes it all");
    }

    /// @notice A sell pays 3% of its ETH output into the pot.
    function test_sellRoutes3PercentToHolders() public {
        IPoolManager.SwapParams memory p =
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -50e18, sqrtPriceLimitX96: 0});
        // amount0 > 0 == ETH owed out to the swapper
        pm.callAfterSwap(hook, _key(), p, toBalanceDelta(int128(100 ether), int128(-50e18)));

        assertEq(address(token).balance, 3 ether, "3% of 100 ETH out");
        assertEq(token.accruedOf(alice), 3 ether);
    }

    /// @dev A buy must not also be charged in afterSwap, or it pays twice.
    function test_buyIsNotChargedTwice() public {
        IPoolManager.SwapParams memory p =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0});
        pm.callBeforeSwap(hook, _key(), p);
        pm.callAfterSwap(hook, _key(), p, toBalanceDelta(int128(-100 ether), int128(50e18)));
        assertEq(address(token).balance, 2 ether, "only the buy fee");
    }

    function test_rejectsPoolWithoutNativeEth() public {
        PoolKey memory bad = _key();
        bad.currency0 = Currency.wrap(address(token));
        IPoolManager.SwapParams memory p =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        vm.expectRevert(BasketHook.PoolMustBeNativeEth.selector);
        pm.callBeforeSwap(hook, bad, p);
    }
}
