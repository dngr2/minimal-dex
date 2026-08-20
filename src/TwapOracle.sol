// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPair} from "./interfaces/IPair.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";

/// @title TwapOracle
/// @notice Manipulation-resistant time-weighted average price (TWAP) oracle for a single Pair,
///         built on the pair's Uniswap-V2-style cumulative-price accumulators.
/// @dev    On each `update()` the oracle samples the pair's cumulative prices (extrapolated to the
///         current block via any time elapsed since the pair's last `_update`), and divides the change
///         since the previous checkpoint by the elapsed time to obtain the average price over the
///         window as a UQ112x112 fixed-point number. `consult` turns that average into an output-amount
///         quote. Because the average integrates price over the whole window, a single-block spot-price
///         manipulation moves the reported TWAP by only ~(1 block / window), not by the full spike.
contract TwapOracle {
    using UQ112x112 for uint224;

    /// @notice The pair this oracle tracks.
    address public immutable pair;
    address public immutable token0;
    address public immutable token1;

    /// @notice Minimum window (in seconds) that must elapse between checkpoints for `update` to take.
    uint256 public immutable period;

    /// @notice Last-sampled cumulative prices and the block timestamp of that sample.
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint32 public blockTimestampLast;

    /// @notice TWAP over the most recent window, as UQ112x112 fixed-point.
    ///         price0Average = average of reserve1/reserve0 (price of token0 in token1).
    ///         price1Average = average of reserve0/reserve1 (price of token1 in token0).
    uint224 public price0Average;
    uint224 public price1Average;

    error NoReserves();
    error InvalidToken();
    error PeriodNotElapsed();

    /// @param _pair   The pair to observe.
    /// @param _period Minimum seconds between accepted checkpoints (the TWAP window floor).
    constructor(address _pair, uint256 _period) {
        pair = _pair;
        period = _period;
        IPair p = IPair(_pair);
        token0 = p.token0();
        token1 = p.token1();
        price0CumulativeLast = p.price0CumulativeLast();
        price1CumulativeLast = p.price1CumulativeLast();
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestamp) = p.getReserves();
        if (reserve0 == 0 || reserve1 == 0) revert NoReserves();
        blockTimestampLast = blockTimestamp;
    }

    /// @notice Reads the pair's cumulative prices as of the current block, extrapolating past the
    ///         pair's last on-chain `_update` using the current reserves (Uniswap-V2 oracle library).
    function currentCumulativePrices()
        public
        view
        returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp)
    {
        blockTimestamp = uint32(block.timestamp);
        IPair p = IPair(pair);
        price0Cumulative = p.price0CumulativeLast();
        price1Cumulative = p.price1CumulativeLast();
        (uint112 reserve0, uint112 reserve1, uint32 pairTimestampLast) = p.getReserves();
        if (pairTimestampLast != blockTimestamp && reserve0 != 0 && reserve1 != 0) {
            unchecked {
                uint32 timeElapsed = blockTimestamp - pairTimestampLast;
                price0Cumulative += uint256(UQ112x112.encode(reserve1).uqdiv(reserve0)) * timeElapsed;
                price1Cumulative += uint256(UQ112x112.encode(reserve0).uqdiv(reserve1)) * timeElapsed;
            }
        }
    }

    /// @notice Checkpoints a new TWAP window. Reverts until at least `period` seconds have elapsed
    ///         since the previous checkpoint. Callable by anyone; call it periodically to advance the
    ///         window that `consult` reports.
    function update() external {
        (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) = currentCumulativePrices();
        uint32 timeElapsed;
        unchecked {
            timeElapsed = blockTimestamp - blockTimestampLast;
        }
        if (timeElapsed < period) revert PeriodNotElapsed();

        unchecked {
            // Overflow/wrap of the cumulative difference is intentional; the quotient is the average.
            price0Average = uint224((price0Cumulative - price0CumulativeLast) / timeElapsed);
            price1Average = uint224((price1Cumulative - price1CumulativeLast) / timeElapsed);
        }

        price0CumulativeLast = price0Cumulative;
        price1CumulativeLast = price1Cumulative;
        blockTimestampLast = blockTimestamp;
    }

    /// @notice Returns the TWAP-based output amount for `amountIn` of `token`, using the average price
    ///         from the most recently checkpointed window. Returns 0 until the first `update()`.
    /// @param token    Either token0 or token1 of the pair (the input token).
    /// @param amountIn Amount of `token` supplied.
    /// @return amountOut TWAP-quoted amount of the other token.
    function consult(address token, uint256 amountIn) external view returns (uint256 amountOut) {
        if (token == token0) {
            amountOut = (uint256(price0Average) * amountIn) >> 112;
        } else if (token == token1) {
            amountOut = (uint256(price1Average) * amountIn) >> 112;
        } else {
            revert InvalidToken();
        }
    }
}
