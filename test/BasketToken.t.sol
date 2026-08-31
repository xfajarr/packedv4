// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BasketToken} from "../src/BasketToken.sol";

contract BasketTokenTest is Test {
    BasketToken t;
    address hook = makeAddr("hook");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address bot = makeAddr("bot");
    address vault = makeAddr("vault");

    function setUp() public {
        t = new BasketToken(hook, vault, address(this), 1000e18);
        vm.deal(hook, 1000 ether);
    }


    function test_accruesProRataByBalanceAtFeeTime() public {
        t.transfer(alice, 250e18); // 25%
        t.transfer(bob, 750e18);   // 75%

        vm.prank(hook);
        t.depositFee{value: 100 ether}();

        assertEq(t.accruedOf(alice), 25 ether, "alice 25%");
        assertEq(t.accruedOf(bob), 75 ether, "bob 75%");
    }

    function test_shareIsFrozenAtAccrual_sellingDoesNotClawBack() public {
        t.transfer(alice, 500e18);
        t.transfer(bob, 500e18);

        vm.prank(hook);
        t.depositFee{value: 100 ether}();
        assertEq(t.accruedOf(alice), 50 ether);

        // Alice dumps everything. What she already earned stays hers.
        vm.prank(alice);
        t.transfer(bob, 500e18);
        assertEq(t.accruedOf(alice), 50 ether, "earned share must survive a full exit");

        // And she earns nothing from the next fee.
        vm.prank(hook);
        t.depositFee{value: 100 ether}();
        assertEq(t.accruedOf(alice), 50 ether, "no accrual after exit");
        assertEq(t.accruedOf(bob), 150 ether, "bob takes the second fee whole");
    }

    function test_buyingLateEarnsNothingFromEarlierFees() public {
        t.transfer(alice, 1000e18);
        vm.prank(hook);
        t.depositFee{value: 100 ether}();

        vm.prank(alice);
        t.transfer(bob, 500e18); // bob arrives after the fee
        assertEq(t.accruedOf(bob), 0, "late buyer gets nothing retroactively");
        assertEq(t.accruedOf(alice), 100 ether);
    }

    function test_claimOnBehalf_paysHolderAndTipsCaller() public {
        t.transfer(alice, 1000e18);
        vm.prank(hook);
        t.depositFee{value: 100 ether}();

        uint256 aliceBefore = alice.balance;
        uint256 botBefore = bot.balance;

        vm.prank(bot);
        t.claim(alice);

        assertEq(alice.balance - aliceBefore, 99 ether, "holder gets 99%");
        assertEq(bot.balance - botBefore, 1 ether, "caller tip 1%");
        assertEq(t.accruedOf(alice), 0, "settled");
    }

    function test_selfClaimTakesNoTip() public {
        t.transfer(alice, 1000e18);
        vm.prank(hook);
        t.depositFee{value: 100 ether}();

        uint256 before = alice.balance;
        vm.prank(alice);
        t.claim(alice);
        assertEq(alice.balance - before, 100 ether, "no tip when self-claiming");
    }

    function test_feeBeforeAnySupplyIsHeldNotBurned() public {
        BasketToken empty = new BasketToken(hook, vault, address(this), 0);
        vm.prank(hook);
        empty.depositFee{value: 10 ether}();
        assertEq(empty.undistributed(), 10 ether, "held for the next deposit");
    }

    function test_onlyHookCanDeposit() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(BasketToken.NotFeeSource.selector);
        t.depositFee{value: 1 ether}();
    }

    /// @dev The invariant that matters: never pay out more than came in.
    function testFuzz_totalAccruedNeverExceedsDeposited(uint96 a, uint96 b, uint96 fee) public {
        a = uint96(bound(a, 1e18, 400e18));
        b = uint96(bound(b, 1e18, 400e18));
        fee = uint96(bound(fee, 1, 100 ether));

        t.transfer(alice, a);
        t.transfer(bob, b);
        vm.prank(hook);
        t.depositFee{value: fee}();

        uint256 sum = t.accruedOf(alice) + t.accruedOf(bob) + t.accruedOf(address(this));
        assertLe(sum, fee, "accrued must never exceed deposited");
    }

    receive() external payable {}
}
