// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {Pair} from "../src/Pair.sol";
import {Router} from "../src/Router.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract LiquidityTest is Base {
    function test_FirstMint_LocksMinimumLiquidity() public {
        uint256 a = 4_000e18;
        uint256 b = 9_000e18;
        uint256 liquidity = _seedLiquidity(tokenA, tokenB, a, b, lp);

        Pair pair = _pair(tokenA, tokenB);
        uint256 expected = Math.sqrt(a * b) - pair.MINIMUM_LIQUIDITY();
        assertEq(liquidity, expected, "lp minted mismatch");
        assertEq(pair.balanceOf(lp), expected, "lp balance mismatch");
        // MINIMUM_LIQUIDITY permanently locked at the burn address.
        assertEq(pair.balanceOf(address(0xdEaD)), pair.MINIMUM_LIQUIDITY(), "min liq not locked");
        assertEq(pair.totalSupply(), Math.sqrt(a * b), "total supply mismatch");
    }

    function test_AddLiquidity_ProportionalSecondDeposit() public {
        _seedLiquidity(tokenA, tokenB, 1_000e18, 1_000e18, lp);
        Pair pair = _pair(tokenA, tokenB);
        uint256 supplyBefore = pair.totalSupply();

        // Add at a skewed ratio; router should pull only the balanced portion.
        _mintAndApprove(tokenA, trader, 500e18);
        _mintAndApprove(tokenB, trader, 999e18);
        vm.prank(trader);
        (uint256 amountA, uint256 amountB, uint256 liq) =
            router.addLiquidity(address(tokenA), address(tokenB), 500e18, 999e18, 0, 0, trader, DEADLINE);

        assertEq(amountA, 500e18, "amountA");
        assertEq(amountB, 500e18, "amountB balanced to ratio");
        assertEq(liq, supplyBefore * 500e18 / 1_000e18, "liq proportional");
    }

    function test_AddLiquidity_RevertsOnSlippage() public {
        _seedLiquidity(tokenA, tokenB, 1_000e18, 1_000e18, lp);
        _mintAndApprove(tokenA, trader, 500e18);
        _mintAndApprove(tokenB, trader, 999e18);
        vm.prank(trader);
        vm.expectRevert(); // amountBMin unreachable -> InsufficientBAmount
        router.addLiquidity(address(tokenA), address(tokenB), 500e18, 999e18, 0, 600e18, trader, DEADLINE);
    }

    function test_AddLiquidity_RevertsPastDeadline() public {
        vm.warp(1_000);
        _mintAndApprove(tokenA, trader, 1e18);
        _mintAndApprove(tokenB, trader, 1e18);
        vm.prank(trader);
        vm.expectRevert(Router.Expired.selector);
        router.addLiquidity(address(tokenA), address(tokenB), 1e18, 1e18, 0, 0, trader, 999);
    }

    function test_RemoveLiquidity_ReturnsProportionalReserves() public {
        uint256 liq = _seedLiquidity(tokenA, tokenB, 2_000e18, 8_000e18, lp);
        Pair pair = _pair(tokenA, tokenB);

        vm.prank(lp);
        pair.approve(address(router), type(uint256).max);

        uint256 total = pair.totalSupply();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        // remove half of lp's liquidity
        uint256 removeLiq = liq / 2;

        vm.prank(lp);
        (uint256 amountA, uint256 amountB) =
            router.removeLiquidity(address(tokenA), address(tokenB), removeLiq, 0, 0, lp, DEADLINE);

        // token ordering inside pair
        bool aIs0 = pair.token0() == address(tokenA);
        uint256 expected0 = removeLiq * r0 / total;
        uint256 expected1 = removeLiq * r1 / total;
        (uint256 expA, uint256 expB) = aIs0 ? (expected0, expected1) : (expected1, expected0);
        assertEq(amountA, expA, "amountA proportional");
        assertEq(amountB, expB, "amountB proportional");
        assertEq(tokenA.balanceOf(lp), amountA, "lp got tokenA");
        assertEq(tokenB.balanceOf(lp), amountB, "lp got tokenB");
    }

    function test_RemoveLiquidity_RevertsOnMinOut() public {
        uint256 liq = _seedLiquidity(tokenA, tokenB, 1_000e18, 1_000e18, lp);
        Pair pair = _pair(tokenA, tokenB);
        vm.prank(lp);
        pair.approve(address(router), type(uint256).max);
        vm.prank(lp);
        vm.expectRevert();
        router.removeLiquidity(address(tokenA), address(tokenB), liq, type(uint256).max, 0, lp, DEADLINE);
    }
}
