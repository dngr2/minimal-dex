// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title UQ112x112
/// @notice Binary fixed-point (Q112.112) helpers used to encode reserve ratios for the
///         cumulative-price TWAP accumulators, matching the Uniswap V2 oracle encoding.
/// @dev    A value `y` is encoded as `y * 2**112`; a UQ112x112 divided by a uint112 stays UQ112x112.
///         Encoding never overflows uint224 for a uint112 input.
library UQ112x112 {
    uint224 internal constant Q112 = 2 ** 112;

    /// @notice Encodes a uint112 as a UQ112x112 fixed-point number.
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112; // never overflows: uint112 * 2**112 fits in uint224
    }

    /// @notice Divides a UQ112x112 by a uint112, returning a UQ112x112.
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }
}
