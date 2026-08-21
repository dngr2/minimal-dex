// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {Pair} from "../src/Pair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Deep-dive adversarial coverage: fee-sensitive k-invariant enforcement,
///         k-monotonicity under fuzzed direct-pair swaps, and burn rounding always
///         favouring the pool. These probe the raw Pair (bypassing the Router) so the
///         0.30% fee term in `_checkKInvariant` is exercised directly and non-hollowly.
contract DeepDiveTest is Base {
    /// The pair charges a real fee: requesting the FULL constant-product (no-fee)
    /// output must be rejected, otherwise a swapper could extract the fee for free.
    function test_FeeEnforced_FullNoFeeOutputReverts() public {
        _seedLiquidity(tokenA, tokenB, 100_000e18, 100_000e18, lp);
        Pair pair = _pair(tokenA, tokenB);
        (uint112 r0, uint112 r1,) = pair.getReserves();

        MockERC20 t0 = MockERC20(pair.token0());
        uint256 dx = 1_000e18;
        t0.mint(address(this), dx);
        t0.transfer(address(pair), dx);

        // Largest token1 output that keeps x*y constant with NO fee taken.
        uint256 dyNoFee = dx * uint256(r1) / (uint256(r0) + dx);
        vm.expectRevert(Pair.KInvariantViolated.selector);
        pair.swap(0, dyNoFee, address(this));
    }

    /// The fee-respecting output (Router's getAmountOut) is accepted and never lowers k.
    function test_FeeEnforced_WithFeeOutputPasses() public {
        _seedLiquidity(tokenA, tokenB, 100_000e18, 100_000e18, lp);
        Pair pair = _pair(tokenA, tokenB);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 kBefore = uint256(r0) * uint256(r1);

        MockERC20 t0 = MockERC20(pair.token0());
        uint256 dx = 1_000e18;
        t0.mint(address(this), dx);
        t0.transfer(address(pair), dx);

        uint256 dyFee = router.getAmountOut(dx, uint256(r0), uint256(r1));
        pair.swap(0, dyFee, address(this));

        (uint112 r0b, uint112 r1b,) = pair.getReserves();
        assertGe(uint256(r0b) * uint256(r1b), kBefore, "k decreased on fee-respecting swap");
    }

    /// Even 1 wei above the fee-respecting output is rejected (tight fee boundary).
    function test_FeeEnforced_OneWeiOverReverts() public {
        _seedLiquidity(tokenA, tokenB, 50_000e18, 70_000e18, lp);
        Pair pair = _pair(tokenA, tokenB);
        (uint112 r0, uint112 r1,) = pair.getReserves();

        MockERC20 t0 = MockERC20(pair.token0());
        uint256 dx = 3_333e18;
        t0.mint(address(this), dx);
        t0.transfer(address(pair), dx);

        uint256 dyFee = router.getAmountOut(dx, uint256(r0), uint256(r1));
        vm.expectRevert(Pair.KInvariantViolated.selector);
        pair.swap(0, dyFee + 1, address(this));
    }

    /// Fuzz: no fuzzed direct-pair swap (either direction) can ever decrease k.
    function testFuzz_SwapNeverDecreasesK(uint256 dx, bool zeroForOne, uint256 seedR0, uint256 seedR1) public {
        seedR0 = bound(seedR0, 1_000e18, 1_000_000e18);
        seedR1 = bound(seedR1, 1_000e18, 1_000_000e18);
        _seedLiquidity(tokenA, tokenB, seedR0, seedR1, lp);
        Pair pair = _pair(tokenA, tokenB);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 kBefore = uint256(r0) * uint256(r1);

        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        dx = bound(dx, 1e6, reserveIn); // up to 100% of the input reserve
        MockERC20 tin = MockERC20(zeroForOne ? pair.token0() : pair.token1());
        tin.mint(address(this), dx);
        tin.transfer(address(pair), dx);

        uint256 dyOut = router.getAmountOut(dx, reserveIn, reserveOut);
        (uint256 a0, uint256 a1) = zeroForOne ? (uint256(0), dyOut) : (dyOut, uint256(0));
        pair.swap(a0, a1, address(this));

        (uint112 nr0, uint112 nr1,) = pair.getReserves();
        assertGe(uint256(nr0) * uint256(nr1), kBefore, "FUZZ: swap decreased k");
    }

    /// Burn returns no MORE than the caller's proportional share (rounding favours the pool),
    /// and never leaves the pair's balances below its reserves.
    function testFuzz_BurnNeverOverReturns(uint256 a0, uint256 a1, uint256 burnFrac) public {
        a0 = bound(a0, 1_000e18, 500_000e18);
        a1 = bound(a1, 1_000e18, 500_000e18);
        uint256 liq = _seedLiquidity(tokenA, tokenB, a0, a1, lp);
        Pair pair = _pair(tokenA, tokenB);

        uint256 burnLiq = bound(burnFrac, 1, liq);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 ts = pair.totalSupply();
        uint256 share0 = burnLiq * uint256(r0) / ts;
        uint256 share1 = burnLiq * uint256(r1) / ts;
        if (share0 == 0 || share1 == 0) return; // pair reverts on zero-output burns

        vm.startPrank(lp);
        pair.transfer(address(pair), burnLiq);
        (uint256 out0, uint256 out1) = pair.burn(lp);
        vm.stopPrank();

        assertLe(out0, share0, "burn over-returned token0");
        assertLe(out1, share1, "burn over-returned token1");

        (uint112 nr0, uint112 nr1,) = pair.getReserves();
        assertGe(MockERC20(pair.token0()).balanceOf(address(pair)), nr0, "balance0 < reserve0");
        assertGe(MockERC20(pair.token1()).balanceOf(address(pair)), nr1, "balance1 < reserve1");
    }
}
