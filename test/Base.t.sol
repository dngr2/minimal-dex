// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Factory} from "../src/Factory.sol";
import {Router} from "../src/Router.sol";
import {Pair} from "../src/Pair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Shared deployment fixture for the DEX tests.
abstract contract Base is Test {
    Factory internal factory;
    Router internal router;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;

    address internal feeSetter = makeAddr("feeSetter");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    uint256 internal constant DEADLINE = type(uint256).max;

    function setUp() public virtual {
        factory = new Factory(feeSetter);
        router = new Router(address(factory));
        tokenA = new MockERC20("Token A", "AAA", 18);
        tokenB = new MockERC20("Token B", "BBB", 18);
        tokenC = new MockERC20("Token C", "CCC", 18);
    }

    function _mintAndApprove(MockERC20 token, address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(router), type(uint256).max);
    }

    function _seedLiquidity(MockERC20 t0, MockERC20 t1, uint256 a0, uint256 a1, address to)
        internal
        returns (uint256 liquidity)
    {
        _mintAndApprove(t0, to, a0);
        _mintAndApprove(t1, to, a1);
        vm.prank(to);
        (,, liquidity) = router.addLiquidity(address(t0), address(t1), a0, a1, 0, 0, to, DEADLINE);
    }

    function _pair(MockERC20 t0, MockERC20 t1) internal view returns (Pair) {
        return Pair(factory.getPair(address(t0), address(t1)));
    }
}
