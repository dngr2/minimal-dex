// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {Pair} from "../src/Pair.sol";
import {IPair} from "../src/interfaces/IPair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ExampleFlashSwapper} from "./mocks/ExampleFlashSwapper.sol";

contract FlashSwapTest is Base {
    Pair internal pair;
    MockERC20 internal t0;
    MockERC20 internal t1;
    ExampleFlashSwapper internal swapper;

    function setUp() public override {
        super.setUp();
        _seedLiquidity(tokenA, tokenB, 100_000e18, 100_000e18, lp);
        pair = _pair(tokenA, tokenB);
        t0 = MockERC20(pair.token0());
        t1 = MockERC20(pair.token1());
        swapper = new ExampleFlashSwapper(IPair(address(pair)));
    }

    function test_FlashSwap_ValidRepaymentPasses() public {
        uint256 borrow = 10_000e18;
        // Fund the borrower with a buffer to cover the 0.30% fee (repaid in the same token).
        t0.mint(address(swapper), 1_000e18);

        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);

        swapper.setMode(ExampleFlashSwapper.Mode.Repay);
        swapper.flashSwap(borrow, 0); // borrow token0, repay token0 + fee

        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        uint256 kAfter = uint256(r0After) * uint256(r1After);

        assertGe(kAfter, kBefore, "k must not decrease after a repaid flash swap");
        // The pool ends up richer in token0 by the collected fee; token1 unchanged.
        assertGt(r0After, r0Before, "pool gained the flash-swap fee in token0");
        assertEq(r1After, r1Before, "token1 reserve unchanged");
    }

    function test_FlashSwap_InsufficientRepaymentReverts() public {
        uint256 borrow = 10_000e18;
        t0.mint(address(swapper), 1_000e18);

        swapper.setMode(ExampleFlashSwapper.Mode.Underpay);
        vm.expectRevert(Pair.KInvariantViolated.selector);
        swapper.flashSwap(borrow, 0);
    }

    function test_FlashSwap_ReentrancyBlocked() public {
        uint256 borrow = 10_000e18;
        t0.mint(address(swapper), 1_000e18);

        swapper.setMode(ExampleFlashSwapper.Mode.Reenter);
        // Re-entering the guarded swap from within the callback must revert the whole flash swap.
        vm.expectRevert();
        swapper.flashSwap(borrow, 0);
    }

    function test_FlashSwap_BorrowToken1SideAlsoWorks() public {
        uint256 borrow = 5_000e18;
        t1.mint(address(swapper), 1_000e18);

        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);

        swapper.setMode(ExampleFlashSwapper.Mode.Repay);
        swapper.flashSwap(0, borrow);

        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        assertGe(uint256(r0After) * uint256(r1After), kBefore, "k held on token1 flash swap");
        assertGt(r1After, r1Before, "pool gained the fee in token1");
    }

    function test_PlainSwapNoDataStillWorks() public {
        // The backward-compatible no-data path must behave exactly as before: a bare swap with
        // no input transferred in reverts with InsufficientInputAmount (no optimistic callback).
        vm.expectRevert(Pair.InsufficientInputAmount.selector);
        pair.swap(1e18, 0, address(this));
    }
}
