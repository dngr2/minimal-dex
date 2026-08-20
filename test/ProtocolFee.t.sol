// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {Pair} from "../src/Pair.sol";
import {Factory} from "../src/Factory.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract ProtocolFeeTest is Base {
    uint256 constant BPS = 10_000;

    function _addr(address a, address b) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = a;
        path[1] = b;
    }

    /// @dev Replicates Pair._mintFee exactly for a given pre-event state.
    function _expectedProtocolMint(uint256 reserve0, uint256 reserve1, uint256 kLast, uint256 supply, uint256 feeBps)
        internal
        pure
        returns (uint256)
    {
        uint256 rootK = Math.sqrt(reserve0 * reserve1);
        uint256 rootKLast = Math.sqrt(kLast);
        if (rootK <= rootKLast) return 0;
        uint256 numerator = supply * (rootK - rootKLast) * feeBps;
        uint256 denominator = rootK * (BPS - feeBps) + rootKLast * feeBps;
        return numerator / denominator;
    }

    function _accrueThenTrigger(uint256 feeBps) internal returns (Pair pair, uint256 expected) {
        if (feeBps > 0) {
            vm.startPrank(feeSetter);
            factory.setFeeTo(feeRecipient);
            factory.setProtocolFeeBps(feeBps);
            vm.stopPrank();
        }

        _seedLiquidity(tokenA, tokenB, 100_000e18, 100_000e18, lp);
        pair = _pair(tokenA, tokenB);

        // grow k via a swap
        _mintAndApprove(tokenA, trader, 10_000e18);
        vm.prank(trader);
        router.swapExactTokensForTokens(10_000e18, 0, _addr(address(tokenA), address(tokenB)), trader, DEADLINE);

        // capture pre-event state, then trigger _mintFee with a liquidity event
        (uint112 r0, uint112 r1,) = pair.getReserves();
        expected = _expectedProtocolMint(r0, r1, pair.kLast(), pair.totalSupply(), feeBps);

        _seedLiquidity(tokenA, tokenB, 1_000e18, 1_000e18, lp);
    }

    function test_ProtocolFee_On_MintsBoundedCutToFeeTo() public {
        (Pair pair, uint256 expected) = _accrueThenTrigger(1666); // ~1/6 of the swap fee, V2-style
        assertGt(expected, 0, "sanity: some protocol fee should accrue");
        assertEq(pair.balanceOf(feeRecipient), expected, "feeTo balance != formula");
    }

    function test_ProtocolFee_Off_FeeToGetsNothing_LPsGetAll() public {
        (Pair pair,) = _accrueThenTrigger(0); // feeTo unset
        assertEq(pair.balanceOf(feeRecipient), 0, "feeTo must accrue nothing when unset");
        assertEq(pair.kLast(), 0, "kLast must stay zero when fee is off");
        // all LP supply belongs to lp + the locked minimum; no protocol dilution
        assertEq(
            pair.totalSupply(),
            pair.balanceOf(lp) + pair.balanceOf(address(0xdEaD)),
            "supply fully owned by LPs (no protocol share)"
        );
    }

    function test_ProtocolFee_ShareIsBounded_LPsKeepBulk() public {
        (Pair pair, uint256 protocolLp) = _accrueThenTrigger(1666);
        uint256 total = pair.totalSupply();
        // protocol cut is a small fraction of total supply; LPs keep the overwhelming bulk
        assertLt(protocolLp * 100, total, "protocol share should be well under 1% of supply here");
    }

    function test_SetProtocolFeeBps_RevertsAboveCap() public {
        uint256 tooHigh = factory.MAX_PROTOCOL_FEE_BPS() + 1;
        vm.prank(feeSetter);
        vm.expectRevert(Factory.FeeBpsTooHigh.selector);
        factory.setProtocolFeeBps(tooHigh);
    }

    function test_OnlyFeeToSetter_CanConfigure() public {
        vm.expectRevert(Factory.Forbidden.selector);
        factory.setFeeTo(address(this));
        vm.expectRevert(Factory.Forbidden.selector);
        factory.setProtocolFeeBps(100);
    }
}
