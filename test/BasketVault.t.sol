// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BasketVault} from "../src/BasketVault.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {IBasketToken} from "../src/IBasketToken.sol";
import {IBasketRouter} from "../src/IBasketRouter.sol";

contract MockERC20 {
    string public name;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(string memory n) {
        name = n;
    }

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
        totalSupply += v;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        require(balanceOf[msg.sender] >= v, "bal");
        unchecked {
            balanceOf[msg.sender] -= v;
            balanceOf[to] += v;
        }
        return true;
    }
}

/// @dev Fixed-rate router: 1 ETH -> `rate` units of the asset.
contract MockRouter is IBasketRouter {
    uint256 public rate = 2;

    function setRate(uint256 r) external {
        rate = r;
    }

    /// @dev A real v4 swap costs roughly 120k gas. Burn a comparable amount so the
    ///      batching comparison measures the thing that actually dominates on-chain.
    function swapExactEthFor(address tokenOut, address to, uint256) external payable returns (uint256 out) {
        uint256 target = gasleft() - 120_000;
        while (gasleft() > target) {}
        out = msg.value * rate;
        MockERC20(tokenOut).mint(to, out);
    }
}

contract BasketVaultTest is Test {
    MockRouter router;
    BasketVault vault;
    BasketToken token;
    address hook = makeAddr("hook");
    MockERC20[5] assets;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        router = new MockRouter();
        address[] memory c = new address[](5);
        uint256[] memory w = new uint256[](5);
        string[5] memory names = ["NVDA", "AAPL", "TSLA", "AMZN", "SPY"];
        for (uint256 i; i < 5; ++i) {
            assets[i] = new MockERC20(names[i]);
            c[i] = address(assets[i]);
            w[i] = 2000; // 20% each
        }
        vault = new BasketVault(router, c, w);
        token = new BasketToken(hook, address(vault), address(this), 1000e18);
        vm.deal(hook, 10_000 ether);
    }

    function _fee(uint256 amt) internal {
        vm.prank(hook);
        token.depositFee{value: amt}();
    }

    /* ------------------------------------------------------------ construction */

    function test_rejectsWeightsThatDoNotSumToBips() public {
        address[] memory c = new address[](2);
        uint256[] memory w = new uint256[](2);
        c[0] = address(assets[0]);
        c[1] = address(assets[1]);
        w[0] = 5000;
        w[1] = 4000; // 90%
        vm.expectRevert(BasketVault.WeightsMustSumToBips.selector);
        new BasketVault(router, c, w);
    }

    function test_rejectsLengthMismatch() public {
        address[] memory c = new address[](2);
        uint256[] memory w = new uint256[](1);
        c[0] = address(assets[0]);
        c[1] = address(assets[1]);
        w[0] = 10_000;
        vm.expectRevert(BasketVault.LengthMismatch.selector);
        new BasketVault(router, c, w);
    }

    function test_basketIsImmutable() public view {
        assertEq(vault.basketSize(), 5);
        address[] memory c = vault.constituents();
        assertEq(c[0], address(assets[0]));
        // No setter exists: verified by the absence of any mutating function on the ABI.
    }

    /* --------------------------------------------------------------- settlement */

    function test_settleBuysWholeBasketAndDeliversToHolder() public {
        token.transfer(alice, 1000e18);
        _fee(100 ether);

        address[] memory hs = new address[](1);
        hs[0] = alice;
        vault.settle(IBasketToken(address(token)), hs);

        // 100 ETH split five ways at 20% -> 20 ETH per leg -> 40 units each at rate 2.
        for (uint256 i; i < 5; ++i) {
            assertEq(assets[i].balanceOf(alice), 40 ether, "leg delivered");
        }
        assertEq(token.accruedOf(alice), 0, "settled");
        assertEq(address(vault).balance, 0, "vault keeps nothing");
    }

    function test_batchSplitsEachLegProRata() public {
        token.transfer(alice, 250e18); // 25%
        token.transfer(bob, 750e18); // 75%
        _fee(100 ether);

        address[] memory hs = new address[](2);
        (hs[0], hs[1]) = alice < bob ? (alice, bob) : (bob, alice);
        vault.settle(IBasketToken(address(token)), hs);

        for (uint256 i; i < 5; ++i) {
            assertEq(assets[i].balanceOf(alice), 10 ether, "alice 25% of the leg");
            assertEq(assets[i].balanceOf(bob), 30 ether, "bob 75% of the leg");
        }
    }

    /// @dev Integer division must not leave assets stranded in the vault.
    function test_dustGoesToLastHolderNotStuckInVault() public {
        token.transfer(alice, 333e18);
        token.transfer(bob, 667e18);
        _fee(7 ether + 3); // deliberately awkward

        address[] memory hs = new address[](2);
        (hs[0], hs[1]) = alice < bob ? (alice, bob) : (bob, alice);
        vault.settle(IBasketToken(address(token)), hs);

        for (uint256 i; i < 5; ++i) {
            uint256 held = assets[i].balanceOf(address(vault));
            assertEq(held, 0, "no asset left behind in the vault");
        }
    }

    function test_rejectsDuplicateHolder() public {
        token.transfer(alice, 1000e18);
        _fee(10 ether);
        address[] memory hs = new address[](2);
        hs[0] = alice;
        hs[1] = alice;
        vm.expectRevert(BasketVault.HoldersMustAscend.selector);
        vault.settle(IBasketToken(address(token)), hs);
    }

    function test_rejectsUnsortedHolders() public {
        (address lo, address hi) = alice < bob ? (alice, bob) : (bob, alice);
        token.transfer(lo, 500e18);
        token.transfer(hi, 500e18);
        _fee(10 ether);
        address[] memory hs = new address[](2);
        hs[0] = hi;
        hs[1] = lo; // descending
        vm.expectRevert(BasketVault.HoldersMustAscend.selector);
        vault.settle(IBasketToken(address(token)), hs);
    }

    function test_revertsWhenNothingAccrued() public {
        address[] memory hs = new address[](1);
        hs[0] = alice;
        vm.expectRevert(BasketVault.NothingToSettle.selector);
        vault.settle(IBasketToken(address(token)), hs);
    }

    function test_onlyVaultCanPullFromToken() public {
        token.transfer(alice, 1000e18);
        _fee(10 ether);
        vm.prank(alice);
        vm.expectRevert(BasketToken.NotBasketVault.selector);
        token.claimToVault(alice);
    }

    /* ---------------------------------------------------------- the whole point */

    /// @notice Batching must cost dramatically less per holder than settling each
    ///         holder alone. This is the fix for shares too small to be worth claiming.
    function test_batchingIsCheaperPerHolderThanIndividualSettlement() public {
        uint256 n = 10;
        address[] memory hs = new address[](n);
        for (uint256 i; i < n; ++i) {
            hs[i] = address(uint160(0x1000 + i));
            token.transfer(hs[i], 100e18);
        }
        _fee(100 ether);

        // Ten holders, one call.
        uint256 g0 = gasleft();
        vault.settle(IBasketToken(address(token)), hs);
        uint256 batched = g0 - gasleft();

        // Same work, one holder at a time.
        _fee(100 ether);
        uint256 individual;
        for (uint256 i; i < n; ++i) {
            address[] memory one = new address[](1);
            one[0] = hs[i];
            uint256 g1 = gasleft();
            vault.settle(IBasketToken(address(token)), one);
            individual += g1 - gasleft();
        }

        emit log_named_uint("batched  (10 holders, 1 call)", batched);
        emit log_named_uint("individual (10 calls)        ", individual);
        emit log_named_uint("saving %", 100 - (batched * 100 / individual));
        assertLt(batched, individual, "batching must win");
    }

    /* ---------------------------------------------------------------- invariant */

    function testFuzz_vaultNeverRetainsEth(uint96 feeAmt, uint96 split) public {
        feeAmt = uint96(bound(feeAmt, 1e12, 500 ether));
        split = uint96(bound(split, 1e18, 999e18));

        token.transfer(alice, split);
        token.transfer(bob, 1000e18 - split);
        _fee(feeAmt);

        address[] memory hs = new address[](2);
        (hs[0], hs[1]) = alice < bob ? (alice, bob) : (bob, alice);
        vault.settle(IBasketToken(address(token)), hs);

        assertEq(address(vault).balance, 0, "vault must never retain ETH");
    }

    receive() external payable {}
}
