// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Factory} from "../../src/Factory.sol";
import {Router} from "../../src/Router.sol";
import {Pair} from "../../src/Pair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Handler} from "./Handler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract InvariantTest is Test {
    Factory internal factory;
    Router internal router;
    MockERC20 internal t0;
    MockERC20 internal t1;
    Pair internal pair;
    Handler internal handler;

    address internal feeRecipient = makeAddr("inv_feeRecipient");
    address internal constant DEAD = address(0xdEaD);

    function setUp() public {
        factory = new Factory(address(this));
        router = new Router(address(factory));
        t0 = new MockERC20("T0", "T0", 18);
        t1 = new MockERC20("T1", "T1", 18);

        // exercise the protocol-fee path during the run
        factory.setFeeTo(feeRecipient);
        factory.setProtocolFeeBps(1666);

        handler = new Handler(factory, router, t0, t1);
        pair = handler.pair();

        targetContract(address(handler));
    }

    /// @notice Total LP supply always equals the sum of every holder's balance.
    function invariant_supplyEqualsSumOfBalances() public view {
        uint256 sum = pair.balanceOf(DEAD) + pair.balanceOf(feeRecipient) + pair.balanceOf(address(router));
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; i++) {
            sum += pair.balanceOf(handler.actors(i));
        }
        // pair may transiently hold LP only mid-call; between calls it is zero
        sum += pair.balanceOf(address(pair));
        assertEq(sum, pair.totalSupply(), "sum(LP balances) != totalSupply");
    }

    /// @notice The pair's token balances are never below its recorded reserves.
    function invariant_balancesCoverReserves() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertGe(IERC20(pair.token0()).balanceOf(address(pair)), r0, "balance0 < reserve0");
        assertGe(IERC20(pair.token1()).balanceOf(address(pair)), r1, "balance1 < reserve1");
    }

    /// @notice No swap ever decreased k (fees make the product strictly non-decreasing on swaps).
    function invariant_swapsNeverDecreaseK() public view {
        assertEq(handler.ghost_swapKViolations(), 0, "a swap decreased k");
    }
}
