// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Factory} from "../../src/Factory.sol";
import {Router} from "../../src/Router.sol";
import {Pair} from "../../src/Pair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Drives add/remove/swap against a single pool for the invariant suite.
contract Handler is Test {
    Factory public factory;
    Router public router;
    MockERC20 public t0;
    MockERC20 public t1;
    Pair public pair;

    address[] public actors;
    uint256 public constant DEADLINE = type(uint256).max;

    /// @notice Counts swaps that decreased k; the invariant asserts this stays zero.
    uint256 public ghost_swapKViolations;

    constructor(Factory _factory, Router _router, MockERC20 _t0, MockERC20 _t1) {
        factory = _factory;
        router = _router;
        t0 = _t0;
        t1 = _t1;

        actors.push(makeAddr("inv_actor_0"));
        actors.push(makeAddr("inv_actor_1"));
        actors.push(makeAddr("inv_actor_2"));

        // Bootstrap the pool so a pair exists for the whole run.
        address a0 = actors[0];
        _fund(t0, a0, 1_000e18);
        _fund(t1, a0, 1_000e18);
        vm.prank(a0);
        router.addLiquidity(address(t0), address(t1), 1_000e18, 1_000e18, 0, 0, a0, DEADLINE);
        pair = Pair(factory.getPair(address(t0), address(t1)));
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function _fund(MockERC20 token, address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(router), type(uint256).max);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function addLiquidity(uint256 actorSeed, uint256 amt) public {
        address actor = _actor(actorSeed);
        amt = bound(amt, 1e15, 1e24);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        // keep reserves comfortably inside uint112
        if (uint256(r0) + amt > type(uint112).max / 2 || uint256(r1) + amt > type(uint112).max / 2) return;
        _fund(t0, actor, amt);
        _fund(t1, actor, amt);
        vm.prank(actor);
        router.addLiquidity(address(t0), address(t1), amt, amt, 0, 0, actor, DEADLINE);
    }

    function removeLiquidity(uint256 actorSeed, uint256 amtSeed) public {
        address actor = _actor(actorSeed);
        uint256 bal = pair.balanceOf(actor);
        if (bal == 0) return;
        uint256 liq = bound(amtSeed, 1, bal);
        vm.startPrank(actor);
        pair.approve(address(router), type(uint256).max);
        // guard against dust burns that would revert on zero output
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 ts = pair.totalSupply();
        if (liq * r0 / ts == 0 || liq * r1 / ts == 0) {
            vm.stopPrank();
            return;
        }
        router.removeLiquidity(address(t0), address(t1), liq, 0, 0, actor, DEADLINE);
        vm.stopPrank();
    }

    function swap(uint256 actorSeed, uint256 amtSeed, bool zeroForOne) public {
        address actor = _actor(actorSeed);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) return;
        (MockERC20 tin, uint256 reserveIn) =
            zeroForOne ? (MockERC20(pair.token0()), uint256(r0)) : (MockERC20(pair.token1()), uint256(r1));
        uint256 amountIn = bound(amtSeed, 1e12, reserveIn / 3 + 1);

        address[] memory path = new address[](2);
        path[0] = address(tin);
        path[1] = tin == t0 ? address(t1) : address(t0);

        _fund(tin, actor, amountIn);

        uint256 kBefore = uint256(r0) * uint256(r1);
        vm.prank(actor);
        try router.swapExactTokensForTokens(amountIn, 0, path, actor, DEADLINE) {
            (uint112 nr0, uint112 nr1,) = pair.getReserves();
            if (uint256(nr0) * uint256(nr1) < kBefore) ghost_swapKViolations++;
        } catch {}
    }
}
