// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Factory} from "../src/Factory.sol";
import {IFactory} from "../src/interfaces/IFactory.sol";
import {PairLister} from "../src/PairLister.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PairListerTest is Test {
    Factory factory;
    PairLister lister;
    address usdc;
    address weth;

    function setUp() public {
        factory = new Factory(address(this));
        usdc = address(new MockERC20("USD Coin", "USDC", 6));
        weth = address(new MockERC20("Wrapped Ether", "WETH", 18));
        lister = new PairLister(IFactory(address(factory)), usdc, weth);
    }

    function _tokens(uint256 n) internal returns (address[] memory t) {
        t = new address[](n);
        for (uint256 i; i < n; ++i) {
            t[i] = address(new MockERC20("Tok", "TK", 18));
        }
    }

    function test_listTokens_createsUsdcAndWethPairs() public {
        address[] memory t = _tokens(3);
        address[] memory pairs = lister.listTokens(t);
        for (uint256 i; i < 3; ++i) {
            assertTrue(pairs[i] != address(0), "usdc pair created");
            assertEq(factory.getPair(t[i], usdc), pairs[i]);
            assertTrue(factory.getPair(t[i], weth) != address(0), "weth pair created");
        }
        // 3 tokens x 2 quotes = 6 pairs
        assertEq(factory.allPairsLength(), 6);
    }

    function test_listTokens_isIdempotent() public {
        address[] memory t = _tokens(2);
        lister.listTokens(t);
        uint256 n = factory.allPairsLength();
        lister.listTokens(t); // re-run
        assertEq(factory.allPairsLength(), n, "no duplicate pairs on re-list");
    }

    function test_listTokens_skipsQuoteAssets() public {
        address[] memory t = new address[](2);
        t[0] = usdc; // a quote asset should be skipped, not paired with itself
        t[1] = weth;
        lister.listTokens(t);
        assertEq(factory.allPairsLength(), 0, "quote assets skipped");
    }

    function test_listHub_createsWethUsdcPair() public {
        address hub = lister.listHub();
        assertEq(factory.getPair(weth, usdc), hub);
        assertEq(factory.allPairsLength(), 1);
    }

    function test_construct_zeroReverts() public {
        vm.expectRevert(PairLister.ZeroAddress.selector);
        new PairLister(IFactory(address(0)), usdc, weth);
        vm.expectRevert(PairLister.ZeroAddress.selector);
        new PairLister(IFactory(address(factory)), address(0), weth);
    }
}
