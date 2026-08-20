// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPair} from "../../src/interfaces/IPair.sol";
import {IFlashSwapCallee} from "../../src/interfaces/IFlashSwapCallee.sol";

/// @notice Example flash-swap borrower. It borrows one side of the pair and, inside the callback,
///         repays the borrowed amount plus the 0.30% fee in the SAME token (the simplest valid
///         flash-swap: borrow token X, return token X + fee). Behaviour is configurable so tests can
///         drive the happy path, the under-repayment (KInvariant) path, and a reentrancy attempt.
contract ExampleFlashSwapper is IFlashSwapCallee {
    IPair public immutable pair;
    address public immutable token0;
    address public immutable token1;

    enum Mode {
        Repay, // repay borrowed + fee -> passes
        Underpay, // repay principal only, skipping the fee -> KInvariant reverts
        Reenter // attempt to re-enter pair.swap during the callback -> guard reverts
    }

    Mode public mode;

    constructor(IPair _pair) {
        pair = _pair;
        token0 = _pair.token0();
        token1 = _pair.token1();
    }

    function setMode(Mode _mode) external {
        mode = _mode;
    }

    /// @notice Kicks off a flash swap borrowing `amount0`/`amount1` from the pair.
    function flashSwap(uint256 amount0Out, uint256 amount1Out) external {
        pair.swap(amount0Out, amount1Out, address(this), abi.encode(uint256(1)));
    }

    /// @inheritdoc IFlashSwapCallee
    function flashSwapCall(address sender, uint256 amount0, uint256 amount1, bytes calldata) external override {
        sender; // unused
        require(msg.sender == address(pair), "not pair");

        if (mode == Mode.Underpay) {
            // Repay only the principal, skipping the 0.30% fee; the pair's k-check must revert.
            if (amount0 > 0) IERC20(token0).transfer(address(pair), amount0);
            if (amount1 > 0) IERC20(token1).transfer(address(pair), amount1);
            return;
        }

        if (mode == Mode.Reenter) {
            // Attempt to re-enter the guarded swap; ReentrancyGuard must revert.
            pair.swap(amount0 == 0 ? uint256(1) : uint256(0), amount1 == 0 ? uint256(1) : uint256(0), address(this));
            return;
        }

        // Mode.Repay: return borrowed amount + 0.30% fee in the same token.
        if (amount0 > 0) {
            uint256 repay = amount0 + _feeFor(amount0);
            IERC20(token0).transfer(address(pair), repay);
        }
        if (amount1 > 0) {
            uint256 repay = amount1 + _feeFor(amount1);
            IERC20(token1).transfer(address(pair), repay);
        }
    }

    /// @dev Fee needed so that (balance*1000 - in*3) product >= reserve product when repaying same-token.
    ///      Return ceil(amount * 3 / 997) which is the minimum same-token top-up that satisfies the k-check.
    function _feeFor(uint256 amount) internal pure returns (uint256) {
        return (amount * 3) / 997 + 1;
    }
}
