// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 that burns a fixed basis-points fee on every transfer, used to test the
///         pair's balance-delta (fee-on-transfer-safe) accounting.
contract FeeOnTransferERC20 is ERC20 {
    uint256 public feeBps;

    constructor(string memory name_, string memory symbol_, uint256 feeBps_) ERC20(name_, symbol_) {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeBps(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = value * feeBps / 10_000;
        super._update(from, address(0xdEaD), fee); // burn the fee to a sink
        super._update(from, to, value - fee);
    }
}
