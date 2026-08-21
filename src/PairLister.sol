// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IFactory} from "./interfaces/IFactory.sol";

/// @title PairLister — batch-create trading pairs against configured quote assets.
/// @notice Permissionless helper for standing up many markets at once on a Factory.
///         Each listed token gets a pair against `quoteUSDC` (the dollar quote) and,
///         if `quoteWETH` is set, also against WETH (the native quote) so tokens can be
///         traded in either dollar or ETH terms and routed through both hubs. Idempotent:
///         a pair that already exists is skipped, so re-running to add tokens is safe.
/// @dev Creating a pair only deploys the empty market — each pair still needs liquidity
///      providers to deposit both assets before it is tradable. This contract holds no
///      funds and has no privileged control over the Factory or any pair.
contract PairLister {
    IFactory public immutable factory;
    address public immutable quoteUSDC;
    address public immutable quoteWETH; // address(0) to disable the WETH leg

    event Listed(address indexed token, address indexed quote, address pair);

    error ZeroAddress();

    constructor(IFactory factory_, address quoteUSDC_, address quoteWETH_) {
        if (address(factory_) == address(0) || quoteUSDC_ == address(0)) revert ZeroAddress();
        factory = factory_;
        quoteUSDC = quoteUSDC_;
        quoteWETH = quoteWETH_;
    }

    /// @notice Create USDC (and optional WETH) pairs for each token. Returns USDC pair addresses.
    function listTokens(address[] calldata tokens) external returns (address[] memory usdcPairs) {
        usdcPairs = new address[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            address t = tokens[i];
            if (t == address(0) || t == quoteUSDC || t == quoteWETH) continue;
            usdcPairs[i] = _ensurePair(t, quoteUSDC);
            if (quoteWETH != address(0)) _ensurePair(t, quoteWETH);
        }
    }

    /// @notice Ensure the WETH/USDC hub pair itself exists (so token→token routing works).
    function listHub() external returns (address) {
        if (quoteWETH == address(0)) revert ZeroAddress();
        return _ensurePair(quoteWETH, quoteUSDC);
    }

    function _ensurePair(address a, address b) internal returns (address pair) {
        pair = factory.getPair(a, b);
        if (pair == address(0)) {
            pair = factory.createPair(a, b);
            emit Listed(a, b, pair);
        }
    }
}
