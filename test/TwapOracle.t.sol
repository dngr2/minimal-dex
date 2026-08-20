// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {Pair} from "../src/Pair.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract TwapOracleTest is Base {
    Pair internal pair;
    TwapOracle internal oracle;
    uint256 internal constant PERIOD = 1 hours;

    /// @dev Explicit monotonic clock so successive advances always accumulate.
    uint256 internal ts;

    function _advance(uint256 secs) internal {
        ts += secs;
        vm.warp(ts);
    }

    function _addr(address a, address b) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = a;
        path[1] = b;
    }

    function setUp() public override {
        super.setUp();
        // Start at a realistic timestamp so uint32 truncation is exercised sanely.
        ts = 1_000_000;
        vm.warp(ts);
        _seedLiquidity(tokenA, tokenB, 100_000e18, 100_000e18, lp);
        pair = _pair(tokenA, tokenB);
        oracle = new TwapOracle(address(pair), PERIOD);
    }

    /// @dev Current spot price of tokenA denominated in tokenB, scaled by 1e18.
    function _spotAinB() internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rA, uint256 rB) =
            pair.token0() == address(tokenA) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        return rB * 1e18 / rA;
    }

    function _swapAforB(uint256 amountIn) internal {
        _mintAndApprove(tokenA, trader, amountIn);
        vm.prank(trader);
        router.swapExactTokensForTokens(amountIn, 0, _addr(address(tokenA), address(tokenB)), trader, DEADLINE);
    }

    function _swapBforA(uint256 amountIn) internal {
        _mintAndApprove(tokenB, trader, amountIn);
        vm.prank(trader);
        router.swapExactTokensForTokens(amountIn, 0, _addr(address(tokenB), address(tokenA)), trader, DEADLINE);
    }

    function test_Twap_TracksAverageOfConstantPriceWindow() public {
        // Move price with a swap, then let it sit constant for a full window.
        _swapAforB(50_000e18);
        uint256 spot = _spotAinB();

        _advance(PERIOD);
        oracle.update();

        // Over a window where the price was constant, the TWAP equals that price.
        uint256 twap = oracle.consult(address(tokenA), 1e18);
        assertApproxEqRel(twap, spot, 1e15, "TWAP over a constant window should equal the spot price"); // 0.1%
    }

    function test_Twap_TracksMovingAverageAcrossBlocks() public {
        // First window: price ~1:1.
        _advance(PERIOD);
        oracle.update();
        uint256 twap1 = oracle.consult(address(tokenA), 1e18);
        assertApproxEqRel(twap1, 1e18, 2e15, "baseline TWAP ~ 1.0");

        // Push the price of A down (A becomes cheaper in B) and hold it for a window.
        _swapAforB(50_000e18);
        uint256 spotLow = _spotAinB();
        assertLt(spotLow, 1e18, "spot A/B fell after selling A");

        _advance(PERIOD);
        oracle.update();
        uint256 twap2 = oracle.consult(address(tokenA), 1e18);

        // The new window's TWAP tracks the new (lower) price, strictly below the baseline.
        assertLt(twap2, twap1, "TWAP followed the price down");
        assertApproxEqRel(twap2, spotLow, 2e15, "second-window TWAP ~ post-swap spot");
    }

    function test_Twap_ResistsSingleBlockManipulation() public {
        // Establish a baseline TWAP at ~1:1 over a full window.
        _advance(PERIOD);
        oracle.update();
        uint256 twapBaseline = oracle.consult(address(tokenA), 1e18);

        // Let the price sit at 1:1 for almost the entire next window (no trades).
        uint256 spotBefore = _spotAinB();
        _advance(PERIOD - 12);

        // ---- Single-block manipulation in the final block of the window: a huge swap crashes the
        //      spot price, but it is time-weighted by only 12 / PERIOD of the window.
        _swapAforB(90_000e18); // massive sell -> spot A/B crashes
        uint256 spotManipulated = _spotAinB();
        assertLt(spotManipulated * 2, spotBefore, "sanity: spot moved by well over 50%");

        _advance(12); // manipulated price persists for a single block
        oracle.update();
        uint256 twapAfter = oracle.consult(address(tokenA), 1e18);

        // The manipulated spot deviated by >50%, but the TWAP barely moved from its baseline.
        assertApproxEqRel(twapAfter, twapBaseline, 2e16, "single-block spike must barely move the TWAP"); // <2%
    }

    function test_Twap_UpdateRevertsBeforePeriod() public {
        _advance(PERIOD);
        oracle.update();
        // Immediately trying again (no time elapsed) must revert.
        vm.expectRevert(TwapOracle.PeriodNotElapsed.selector);
        oracle.update();
    }

    function test_Twap_ConstructorRevertsWithoutReserves() public {
        address emptyPair = factory.createPair(address(tokenA), address(tokenC));
        vm.expectRevert(TwapOracle.NoReserves.selector);
        new TwapOracle(emptyPair, PERIOD);
    }
}
