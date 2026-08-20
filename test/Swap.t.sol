// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {Pair} from "../src/Pair.sol";
import {Router} from "../src/Router.sol";

contract SwapTest is Base {
    function _addr(address a, address b) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = a;
        path[1] = b;
    }

    function test_SwapExact_MatchesGetAmountOut_AndKNonDecreasing() public {
        _seedLiquidity(tokenA, tokenB, 10_000e18, 10_000e18, lp);
        Pair pair = _pair(tokenA, tokenB);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 kBefore = uint256(r0) * uint256(r1);

        uint256 amountIn = 1_000e18;
        (uint256 reserveIn, uint256 reserveOut) = router.getReserves(address(factory), address(tokenA), address(tokenB));
        uint256 expectedOut = router.getAmountOut(amountIn, reserveIn, reserveOut);

        _mintAndApprove(tokenA, trader, amountIn);
        vm.prank(trader);
        uint256[] memory amounts =
            router.swapExactTokensForTokens(amountIn, 0, _addr(address(tokenA), address(tokenB)), trader, DEADLINE);

        assertEq(amounts[1], expectedOut, "output != getAmountOut");
        assertEq(tokenB.balanceOf(trader), expectedOut, "trader did not receive output");

        (uint112 r0b, uint112 r1b,) = pair.getReserves();
        uint256 kAfter = uint256(r0b) * uint256(r1b);
        assertGe(kAfter, kBefore, "k decreased across swap");
    }

    function test_SwapExact_MovesPriceAlongCurve() public {
        _seedLiquidity(tokenA, tokenB, 10_000e18, 10_000e18, lp);
        Pair pair = _pair(tokenA, tokenB);
        bool aIs0 = pair.token0() == address(tokenA);

        _mintAndApprove(tokenA, trader, 1_000e18);
        vm.prank(trader);
        router.swapExactTokensForTokens(1_000e18, 0, _addr(address(tokenA), address(tokenB)), trader, DEADLINE);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rA, uint256 rB) = aIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        assertGt(rA, 10_000e18, "tokenA reserve should rise");
        assertLt(rB, 10_000e18, "tokenB reserve should fall");
    }

    function test_SwapExact_RevertsOnSlippage() public {
        _seedLiquidity(tokenA, tokenB, 10_000e18, 10_000e18, lp);
        _mintAndApprove(tokenA, trader, 1_000e18);
        vm.prank(trader);
        vm.expectRevert(Router.InsufficientOutputAmount.selector);
        router.swapExactTokensForTokens(1_000e18, 999e18, _addr(address(tokenA), address(tokenB)), trader, DEADLINE);
    }

    function test_SwapExact_RevertsPastDeadline() public {
        _seedLiquidity(tokenA, tokenB, 10_000e18, 10_000e18, lp);
        vm.warp(5_000);
        _mintAndApprove(tokenA, trader, 1_000e18);
        vm.prank(trader);
        vm.expectRevert(Router.Expired.selector);
        router.swapExactTokensForTokens(1_000e18, 0, _addr(address(tokenA), address(tokenB)), trader, 4_999);
    }

    function test_SwapForExact_ComputesCorrectInput() public {
        _seedLiquidity(tokenA, tokenB, 10_000e18, 10_000e18, lp);
        uint256 amountOut = 500e18;
        (uint256 reserveIn, uint256 reserveOut) = router.getReserves(address(factory), address(tokenA), address(tokenB));
        uint256 expectedIn = router.getAmountIn(amountOut, reserveIn, reserveOut);

        _mintAndApprove(tokenA, trader, expectedIn);
        uint256 balBefore = tokenA.balanceOf(trader);
        vm.prank(trader);
        uint256[] memory amounts = router.swapTokensForExactTokens(
            amountOut, type(uint256).max, _addr(address(tokenA), address(tokenB)), trader, DEADLINE
        );

        assertEq(amounts[0], expectedIn, "input != getAmountIn");
        assertEq(balBefore - tokenA.balanceOf(trader), expectedIn, "spent != expected");
        assertEq(tokenB.balanceOf(trader), amountOut, "did not receive exact out");
    }

    function test_SwapForExact_RevertsOnMaxIn() public {
        _seedLiquidity(tokenA, tokenB, 10_000e18, 10_000e18, lp);
        _mintAndApprove(tokenA, trader, 10_000e18);
        vm.prank(trader);
        vm.expectRevert(Router.ExcessiveInputAmount.selector);
        router.swapTokensForExactTokens(500e18, 1e18, _addr(address(tokenA), address(tokenB)), trader, DEADLINE);
    }

    function test_TwoHopPath_AtoBtoC() public {
        // A/B and B/C pools
        _seedLiquidity(tokenA, tokenB, 10_000e18, 10_000e18, lp);
        _seedLiquidity(tokenB, tokenC, 10_000e18, 10_000e18, lp);

        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint256 amountIn = 1_000e18;
        uint256[] memory expected = router.getAmountsOut(address(factory), amountIn, path);

        _mintAndApprove(tokenA, trader, amountIn);
        vm.prank(trader);
        uint256[] memory amounts = router.swapExactTokensForTokens(amountIn, 0, path, trader, DEADLINE);

        assertEq(amounts[2], expected[2], "final output mismatch");
        assertEq(tokenC.balanceOf(trader), expected[2], "trader did not receive C");
        assertGt(expected[2], 0, "no output");
    }
}
