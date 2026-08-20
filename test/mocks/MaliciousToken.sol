// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPair} from "../../src/interfaces/IPair.sol";

/// @notice ERC20 that, once armed, re-enters the pair during a transfer to probe the
///         ReentrancyGuard. The reentrant call must revert and bubble up.
contract MaliciousToken is ERC20 {
    IPair public pair;
    bool public armed;

    constructor() ERC20("Malicious", "EVIL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPair(IPair pair_) external {
        pair = pair_;
    }

    function arm() external {
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        // When the pair pays this token out during a swap, attempt to re-enter swap().
        if (armed && from == address(pair)) {
            // Re-entrant call; guarded function must revert, propagating the failure.
            pair.swap(0, 1, address(this));
        }
        super._update(from, to, value);
    }
}
