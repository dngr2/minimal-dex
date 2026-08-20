// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {Pair} from "../src/Pair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MaliciousToken} from "./mocks/MaliciousToken.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {IPair} from "../src/interfaces/IPair.sol";

contract AttacksTest is Base {
    // ----------------------------- Reentrancy ----------------------------- //

    function test_Reentrancy_Blocked() public {
        MaliciousToken evil = new MaliciousToken();
        MockERC20 good = tokenA;

        address pairAddr = factory.createPair(address(evil), address(good));
        Pair pair = Pair(pairAddr);
        evil.setPair(IPair(pairAddr));

        // Seed liquidity by direct transfer + mint (token is not yet armed).
        evil.mint(address(this), 100_000e18);
        good.mint(address(this), 100_000e18);
        evil.transfer(pairAddr, 50_000e18);
        good.transfer(pairAddr, 50_000e18);
        pair.mint(address(this));

        // Arm the token and attempt a swap that pays EVIL out, triggering re-entry.
        evil.arm();
        good.transfer(pairAddr, 1_000e18);
        bool evilIs0 = pair.token0() == address(evil);
        (uint256 a0, uint256 a1) = evilIs0 ? (uint256(500e18), uint256(0)) : (uint256(0), uint256(500e18));
        vm.expectRevert(); // ReentrancyGuardReentrantCall bubbles up
        pair.swap(a0, a1, address(this));
    }

    // -------------------------- Share inflation --------------------------- //

    function test_ShareInflation_CannotBootstrapDustSupply() public {
        address pairAddr = factory.createPair(address(tokenA), address(tokenB));
        Pair pair = Pair(pairAddr);
        // sqrt(1000*1000) == MINIMUM_LIQUIDITY, so the minted amount underflows to zero -> revert.
        tokenA.mint(pairAddr, 1000);
        tokenB.mint(pairAddr, 1000);
        vm.expectRevert(); // InsufficientLiquidityMinted (or arithmetic underflow on the lock)
        pair.mint(address(this));
    }

    function test_ShareInflation_LockedLiquidityUnrecoverable() public {
        uint256 liq = _seedLiquidity(tokenA, tokenB, 5_000e18, 5_000e18, lp);
        Pair pair = _pair(tokenA, tokenB);

        // Burn ALL of the attacker/LP position.
        vm.prank(lp);
        pair.transfer(address(pair), liq);
        vm.prank(lp);
        pair.burn(lp);

        // The MINIMUM_LIQUIDITY remains locked forever; supply can never fall below it.
        assertEq(pair.totalSupply(), pair.MINIMUM_LIQUIDITY(), "supply floor == MINIMUM_LIQUIDITY");
        assertEq(pair.balanceOf(address(0xdEaD)), pair.MINIMUM_LIQUIDITY(), "locked shares intact");
        assertEq(pair.balanceOf(lp), 0, "attacker fully exited");
    }

    function test_ShareInflation_VictimDepositNotStolen() public {
        // Attacker becomes first LP with the smallest viable position.
        address attacker = makeAddr("attacker");
        address pairAddr = factory.createPair(address(tokenA), address(tokenB));
        Pair pair = Pair(pairAddr);

        tokenA.mint(attacker, type(uint128).max);
        tokenB.mint(attacker, type(uint128).max);

        vm.startPrank(attacker);
        tokenA.transfer(pairAddr, 2_000);
        tokenB.transfer(pairAddr, 2_000);
        pair.mint(attacker); // gets 1000 LP, 1000 locked

        // Inflate: donate a large amount and sync so reserves/k balloon while supply stays ~2000.
        tokenA.transfer(pairAddr, 1_000e18);
        tokenB.transfer(pairAddr, 1_000e18);
        pair.sync();
        vm.stopPrank();

        // Victim adds a sizeable, balanced deposit directly.
        address victim = makeAddr("victim");
        uint256 vAmt = 1_000e18;
        tokenA.mint(victim, vAmt);
        tokenB.mint(victim, vAmt);
        vm.startPrank(victim);
        tokenA.transfer(pairAddr, vAmt);
        tokenB.transfer(pairAddr, vAmt);
        uint256 vLp = pair.mint(victim);
        vm.stopPrank();

        assertGt(vLp, 0, "victim must receive nonzero LP (lock defeats the round-to-zero attack)");

        // Victim withdraws and should recover the large majority of the deposit.
        vm.startPrank(victim);
        pair.transfer(pairAddr, vLp);
        (uint256 out0, uint256 out1) = pair.burn(victim);
        vm.stopPrank();

        (uint256 gotA, uint256 gotB) = pair.token0() == address(tokenA) ? (out0, out1) : (out1, out0);
        // recovered value >= 99% of what was deposited on each side
        assertGe(gotA, vAmt * 99 / 100, "victim recovered ~all tokenA");
        assertGe(gotB, vAmt * 99 / 100, "victim recovered ~all tokenB");
    }

    // ---------------- Fee-on-transfer accounting (balance deltas) --------- //

    function test_FeeOnTransfer_SwapAccountingUsesBalanceDeltas() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20("Fee", "FOT", 100); // 1% transfer burn
        MockERC20 good = tokenA;

        address pairAddr = factory.createPair(address(fot), address(good));
        Pair pair = Pair(pairAddr);

        fot.mint(address(this), 1_000_000e18);
        good.mint(address(this), 1_000_000e18);

        // Seed: transfer sends 1% less than requested; pair records what actually arrives.
        fot.transfer(pairAddr, 100_000e18);
        good.transfer(pairAddr, 100_000e18);
        pair.mint(address(this));

        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool fotIs0 = pair.token0() == address(fot);
        uint256 fotReserve = fotIs0 ? r0 : r1;
        // Reserve reflects the post-fee amount actually received (99%).
        assertEq(fotReserve, 99_000e18, "reserve should equal delivered amount, not sent");

        // A swap paying `good` out for `fot` in: amountIn is measured from the pair's
        // realized balance delta, so the k-check still passes despite the transfer fee.
        uint256 goodReserve = fotIs0 ? r1 : r0;
        uint256 sendIn = 10_000e18; // 9,900 actually lands
        fot.transfer(pairAddr, sendIn);
        // conservative output well under the curve
        uint256 outGood = goodReserve / 20;
        (uint256 a0, uint256 a1) = fotIs0 ? (uint256(0), outGood) : (outGood, uint256(0));
        pair.swap(a0, a1, address(this));

        (uint112 r0b, uint112 r1b,) = pair.getReserves();
        assertGe(uint256(r0b) * uint256(r1b), uint256(r0) * uint256(r1), "k held under fee-on-transfer swap");
    }
}
