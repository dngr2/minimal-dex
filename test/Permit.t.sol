// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {Pair} from "../src/Pair.sol";
import {Router} from "../src/Router.sol";

contract PermitTest is Base {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function _permitDigest(Pair pair, address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", pair.DOMAIN_SEPARATOR(), structHash));
    }

    /// @dev Varying arguments for a removeLiquidityWithPermit call, packed into memory so the
    ///      11-argument external call fits within the legacy-codegen stack.
    struct RemoveArgs {
        address to;
        uint256 liquidity;
        bool approveMax;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @dev Signs a permit for `removeLiq` and calls removeLiquidityWithPermit as `owner`.
    ///      Extracted to keep the signing locals out of the caller's stack frame (legacy codegen).
    function _removeWithPermit(Pair pair, address owner, uint256 pk, uint256 removeLiq, bool approveMax)
        internal
        returns (uint256 amountA, uint256 amountB)
    {
        RemoveArgs memory a;
        a.to = owner;
        a.liquidity = removeLiq;
        a.approveMax = approveMax;
        {
            uint256 value = approveMax ? type(uint256).max : removeLiq;
            bytes32 digest = _permitDigest(pair, owner, address(router), value, pair.nonces(owner), DEADLINE);
            (a.v, a.r, a.s) = vm.sign(pk, digest);
        }

        (amountA, amountB) = _callRemoveWithPermit(a);
    }

    /// @dev Minimal wrapper whose only local is the memory-packed args, leaving the legacy stack
    ///      enough room for the 11-argument external call.
    function _callRemoveWithPermit(RemoveArgs memory a) internal returns (uint256 amountA, uint256 amountB) {
        vm.prank(a.to);
        (amountA, amountB) = router.removeLiquidityWithPermit(
            address(tokenA), address(tokenB), a.liquidity, 0, 0, a.to, DEADLINE, a.approveMax, a.v, a.r, a.s
        );
    }

    function test_Permit_SetsAllowanceAndConsumesNonce() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitOwner");
        _seedLiquidity(tokenA, tokenB, 10_000e18, 10_000e18, owner);
        Pair pair = _pair(tokenA, tokenB);

        uint256 value = 123e18;
        bytes32 digest = _permitDigest(pair, owner, address(router), value, pair.nonces(owner), DEADLINE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        pair.permit(owner, address(router), value, DEADLINE, v, r, s);

        assertEq(pair.allowance(owner, address(router)), value, "permit did not set allowance");
        assertEq(pair.nonces(owner), 1, "nonce not consumed");
    }

    function test_RemoveLiquidityWithPermit_NoSeparateApprove() public {
        (address owner, uint256 pk) = makeAddrAndKey("lpOwner");
        uint256 liq = _seedLiquidity(tokenA, tokenB, 5_000e18, 20_000e18, owner);
        Pair pair = _pair(tokenA, tokenB);

        // Owner has NOT approved the router for the LP token; permit authorizes the pull.
        assertEq(pair.allowance(owner, address(router)), 0, "precondition: no allowance");

        uint256 removeLiq = liq / 2;
        uint256 amountA;
        uint256 amountB;
        {
            uint256 total = pair.totalSupply();
            (uint112 res0, uint112 res1,) = pair.getReserves();

            (amountA, amountB) = _removeWithPermit(pair, owner, pk, removeLiq, false);

            bool aIs0 = pair.token0() == address(tokenA);
            uint256 exp0 = removeLiq * res0 / total;
            uint256 exp1 = removeLiq * res1 / total;
            (uint256 expA, uint256 expB) = aIs0 ? (exp0, exp1) : (exp1, exp0);
            assertEq(amountA, expA, "amountA mismatch");
            assertEq(amountB, expB, "amountB mismatch");
        }
        assertEq(tokenA.balanceOf(owner), amountA, "owner did not receive tokenA");
        assertEq(tokenB.balanceOf(owner), amountB, "owner did not receive tokenB");
        assertEq(pair.balanceOf(owner), liq - removeLiq, "LP not reduced by removed amount");
    }

    function test_RemoveLiquidityWithPermit_ApproveMaxLeavesResidualAllowance() public {
        (address owner, uint256 pk) = makeAddrAndKey("lpOwnerMax");
        uint256 liq = _seedLiquidity(tokenA, tokenB, 5_000e18, 5_000e18, owner);
        Pair pair = _pair(tokenA, tokenB);

        uint256 removeLiq = liq / 4;
        _removeWithPermit(pair, owner, pk, removeLiq, true);

        // approveMax leaves an infinite residual allowance for subsequent removals.
        assertEq(pair.allowance(owner, address(router)), type(uint256).max, "max allowance not retained");
    }

    function test_RemoveLiquidityWithPermit_BadSignatureReverts() public {
        (address owner,) = makeAddrAndKey("lpOwnerBad");
        (, uint256 wrongPk) = makeAddrAndKey("attacker");
        uint256 liq = _seedLiquidity(tokenA, tokenB, 1_000e18, 1_000e18, owner);
        Pair pair = _pair(tokenA, tokenB);

        bytes32 digest = _permitDigest(pair, owner, address(router), liq, pair.nonces(owner), DEADLINE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest); // signed by the wrong key

        vm.prank(owner);
        vm.expectRevert(); // ERC2612InvalidSigner
        router.removeLiquidityWithPermit(address(tokenA), address(tokenB), liq, 0, 0, owner, DEADLINE, false, v, r, s);
    }
}
